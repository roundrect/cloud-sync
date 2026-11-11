import { describe, expect, it } from "vitest";
import { bootstrap, call, envelope, jsonOf, pairDevice, putDoc, sha256 } from "./helpers";

describe("documents", () => {
  it("an empty account is {rev: 0}", async () => {
    const a = await bootstrap();
    const response = await call("GET", "/v1/ns/app/doc", { token: a.token });
    expect(response.status).toBe(200);
    expect(response.headers.get("etag")).toBe('"0"');
    expect(await jsonOf(response)).toEqual({ rev: 0 });
  });

  it("PUT then GET round-trips the envelope with the wire fields, and rev increments", async () => {
    const a = await bootstrap("Mac A");
    const first = await putDoc(a, 0, "version: 1\n", "first");
    expect(first.status).toBe(200);
    expect(await jsonOf(first)).toEqual({ rev: 1 });
    expect(first.headers.get("etag")).toBe('"1"');
    const second = await putDoc(a, 1, "version: 1\nx: 1\n", "second");
    expect(await jsonOf(second)).toEqual({ rev: 2 });

    const got = await call("GET", "/v1/ns/app/doc", { token: a.token });
    expect(got.headers.get("etag")).toBe('"2"');
    const doc = await jsonOf(got);
    expect(Object.keys(doc).sort()).toEqual(["body", "deviceId", "deviceName", "format", "rev", "schema", "sha256", "summary", "updatedAt"]);
    expect(doc).toMatchObject({ rev: 2, format: "app-text", schema: 1, body: "version: 1\nx: 1\n", summary: "second", deviceId: a.deviceId, deviceName: "Mac A" });
    expect(doc.sha256).toBe(await sha256("version: 1\nx: 1\n"));
    expect(new Date(doc.updatedAt).toISOString()).toBe(doc.updatedAt); // ISO-8601 with milliseconds
  });

  it("If-Match is accepted as 0, \"0\" and W/\"0\"; 400 when it is not a number", async () => {
    const a = await bootstrap();
    expect((await putDoc(a, '"0"', "v: 1\n")).status).toBe(200);
    expect((await putDoc(a, 'W/"1"', "v: 2\n")).status).toBe(200);
    expect((await putDoc(a, "abc", "v: 3\n")).status).toBe(400);
  });

  it("a stale If-Match is 409 carrying the current document", async () => {
    const a = await bootstrap("Mac A");
    const b = await pairDevice(a, "Mac B");
    await putDoc(a, 0, "v: 1\n", "from A");
    const stale = await putDoc(b, 0, "v: 2\n", "from B");
    expect(stale.status).toBe(409);
    expect(stale.headers.get("etag")).toBe('"1"');
    const current = await jsonOf(stale);
    expect(current).toMatchObject({ rev: 1, body: "v: 1\n", summary: "from A", deviceName: "Mac A", error: "conflict" });
    // Nothing was written, and the retry with the new revision succeeds.
    expect((await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }))).rev).toBe(1);
    expect((await putDoc(b, current.rev, "v: 2\n", "from B")).status).toBe(200);
    // A future revision is just as stale, and a stale write to an empty account reports {rev: 0}.
    expect((await putDoc(a, 99, "v: 9\n")).status).toBe(409);
    const fresh = await bootstrap();
    const emptyConflict = await putDoc(fresh, 5, "v: 9\n");
    expect(emptyConflict.status).toBe(409);
    expect(await jsonOf(emptyConflict)).toMatchObject({ rev: 0 });
  });

  it("428 without If-Match", async () => {
    const a = await bootstrap();
    const response = await call("PUT", "/v1/ns/app/doc", { token: a.token, body: await envelope("v: 1\n") });
    expect(response.status).toBe(428);
    expect(await jsonOf(response)).toMatchObject({ error: "precondition_required" });
  });

  it("413 over 512 KB (measured in UTF-8 bytes), and exactly 512 KB is accepted", async () => {
    const a = await bootstrap();
    expect((await putDoc(a, 0, "x".repeat(512 * 1024 + 1))).status).toBe(413);
    expect((await putDoc(a, 0, "é".repeat(256 * 1024 + 1))).status).toBe(413);
    expect((await putDoc(a, 0, "x".repeat(512 * 1024))).status).toBe(200);
  });

  it("422 for a malformed format or a sha256 that does not match the body", async () => {
    const a = await bootstrap();
    const headers = { "if-match": "0" };
    const malformed = await call("PUT", "/v1/ns/app/doc", { token: a.token, headers, body: await envelope("v: 1\n", "s", "App Text!") });
    expect(malformed.status).toBe(422);
    expect(await jsonOf(malformed)).toMatchObject({ error: "unsupported_format" });
    const wrong = await call("PUT", "/v1/ns/app/doc", { token: a.token, headers, body: { ...(await envelope("v: 1\n")), sha256: "0".repeat(64) } });
    expect(wrong.status).toBe(422);
    expect(await jsonOf(wrong)).toMatchObject({ error: "checksum_mismatch" });
    expect((await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }))).rev).toBe(0);
  });

  it("accepts any well-formed format, whichever app wrote it", async () => {
    const a = await bootstrap();
    let rev = 0;
    for (const format of ["app-text", "other-app", "x", "a1.b2+c3-d4", "0day", "z".repeat(64)]) {
      const response = await call("PUT", "/v1/ns/app/doc", { token: a.token, headers: { "if-match": String(rev) }, body: await envelope(`v: ${rev}\n`, "s", format) });
      expect(response.status).toBe(200);
      expect((await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }))).format).toBe(format);
      rev++;
    }
  });

  it("422 for every malformed format, and nothing is written", async () => {
    const a = await bootstrap();
    for (const format of ["", "App-Text", "app text", "-app", ".app", "+enc", "app/text", "app_text", "é", "z".repeat(65)]) {
      const response = await call("PUT", "/v1/ns/app/doc", { token: a.token, headers: { "if-match": "0" }, body: await envelope("v: 1\n", "s", format) });
      expect(response.status, JSON.stringify(format)).toBe(422);
      expect(await jsonOf(response)).toMatchObject({ error: "unsupported_format" });
    }
    expect((await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }))).rev).toBe(0);
  });

  it("accepts an encrypted form (<format>+enc1) with an opaque body, and an upper-case sha256", async () => {
    const a = await bootstrap();
    const ciphertext = "AAECAwQFBgc=";
    const enc = await call("PUT", "/v1/ns/app/doc", { token: a.token, headers: { "if-match": "0" }, body: await envelope(ciphertext, "", "app-text+enc1") });
    expect(enc.status).toBe(200);
    const body = await envelope("v: 1\n");
    const upper = await call("PUT", "/v1/ns/app/doc", { token: a.token, headers: { "if-match": "1" }, body: { ...body, sha256: body.sha256.toUpperCase() } });
    expect(upper.status).toBe(200);
    expect((await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }))).sha256).toBe(body.sha256);
  });

  it("400 for a malformed envelope", async () => {
    const a = await bootstrap();
    for (const body of [{}, { format: "app-text", schema: "1", body: "x", sha256: "y" }, { format: "app-text", schema: 0, body: "x", sha256: "y" }, "[]"]) {
      const response = await call("PUT", "/v1/ns/app/doc", { token: a.token, headers: { "if-match": "0" }, body });
      expect(response.status).toBe(400);
    }
  });

  it("isolates documents between accounts", async () => {
    const a = await bootstrap();
    const b = await bootstrap();
    await putDoc(a, 0, "v: a\n");
    expect((await jsonOf(await call("GET", "/v1/ns/app/doc", { token: b.token }))).rev).toBe(0);
    expect((await call("GET", "/v1/ns/app/history/1", { token: b.token })).status).toBe(404);
  });
});
