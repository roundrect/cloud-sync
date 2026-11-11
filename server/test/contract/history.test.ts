import { describe, expect, it } from "vitest";
import { bootstrap, call, jsonOf, pairDevice, putDoc, sha256 } from "./helpers";

async function seed(count: number) {
  const a = await bootstrap("Mac A");
  for (let i = 0; i < count; i++) {
    const response = await putDoc(a, i, `n: ${i + 1}\n`, `edit ${i + 1}`);
    expect(response.status).toBe(200);
  }
  return a;
}

describe("history", () => {
  it("lists newest first without bodies, with the wire fields; rev 1 is a bootstrap", async () => {
    const a = await seed(3);
    const history = await jsonOf(await call("GET", "/v1/ns/app/history", { token: a.token }));
    expect(history.revisions.map((r: { rev: number }) => r.rev)).toEqual([3, 2, 1]);
    expect(history.nextBefore).toBeNull();
    expect(history.revisions[0]).toEqual({
      rev: 3, createdAt: expect.any(String), deviceId: a.deviceId, deviceName: "Mac A", kind: "put", summary: "edit 3",
    });
    expect(history.revisions[2].kind).toBe("bootstrap");
    expect(JSON.stringify(history)).not.toContain("body");
  });

  it("paginates with before and limit", async () => {
    const a = await seed(5);
    const page1 = await jsonOf(await call("GET", "/v1/ns/app/history?limit=2", { token: a.token }));
    expect(page1.revisions.map((r: { rev: number }) => r.rev)).toEqual([5, 4]);
    expect(page1.nextBefore).toBe(4);
    const page2 = await jsonOf(await call("GET", `/v1/ns/app/history?limit=2&before=${page1.nextBefore}`, { token: a.token }));
    expect(page2.revisions.map((r: { rev: number }) => r.rev)).toEqual([3, 2]);
    const page3 = await jsonOf(await call("GET", `/v1/ns/app/history?limit=2&before=${page2.nextBefore}`, { token: a.token }));
    expect(page3.revisions.map((r: { rev: number }) => r.rev)).toEqual([1]);
    expect(page3.nextBefore).toBeNull();
    expect((await call("GET", "/v1/ns/app/history?limit=0", { token: a.token })).status).toBe(400);
    expect((await call("GET", "/v1/ns/app/history?before=x", { token: a.token })).status).toBe(400);
  });

  it("an empty account has an empty history", async () => {
    const a = await bootstrap();
    expect(await jsonOf(await call("GET", "/v1/ns/app/history", { token: a.token }))).toEqual({ revisions: [], nextBefore: null });
  });

  it("GET /v1/history/{rev} returns one revision with its body, 404 for a missing one", async () => {
    const a = await seed(2);
    const one = await jsonOf(await call("GET", "/v1/ns/app/history/1", { token: a.token }));
    expect(one).toMatchObject({ rev: 1, body: "n: 1\n", format: "app-text", schema: 1, kind: "bootstrap", deviceName: "Mac A" });
    expect((await call("GET", "/v1/ns/app/history/3", { token: a.token })).status).toBe(404);
    expect((await call("GET", "/v1/ns/app/history/abc", { token: a.token })).status).toBe(400);
  });

  it("records which device wrote each revision", async () => {
    const a = await bootstrap("Mac A");
    const b = await pairDevice(a, "Mac B");
    await putDoc(a, 0, "n: 1\n");
    await putDoc(b, 1, "n: 2\n");
    const history = await jsonOf(await call("GET", "/v1/ns/app/history", { token: a.token }));
    expect(history.revisions.map((r: { deviceName: string }) => r.deviceName)).toEqual(["Mac B", "Mac A"]);
  });

  it("prunes the oldest revisions at HISTORY_LIMIT, in the write that exceeds it", async () => {
    const a = await bootstrap();
    const vars = { historyLimit: "3" };
    for (let i = 0; i < 5; i++) {
      const response = await call("PUT", "/v1/ns/app/doc", {
        token: a.token, vars, headers: { "if-match": String(i) },
        body: { format: "app-text", schema: 1, body: `n: ${i}\n`, sha256: await sha256(`n: ${i}\n`), summary: "" },
      });
      expect(response.status).toBe(200);
    }
    const history = await jsonOf(await call("GET", "/v1/ns/app/history", { token: a.token }));
    expect(history.revisions.map((r: { rev: number }) => r.rev)).toEqual([5, 4, 3]);
    expect((await call("GET", "/v1/ns/app/history/2", { token: a.token })).status).toBe(404);
    expect((await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }))).rev).toBe(5); // rev never goes backwards
  });
});

describe("revert", () => {
  it("creates a new revision with the target's body and leaves history untouched", async () => {
    const a = await seed(3);
    const response = await call("POST", "/v1/ns/app/revert", { token: a.token, body: { rev: 1, ifMatch: 3, summary: "Back to the start" } });
    expect(response.status).toBe(200);
    expect(await jsonOf(response)).toEqual({ rev: 4 });

    const doc = await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }));
    expect(doc).toMatchObject({ rev: 4, body: "n: 1\n", summary: "Back to the start" });

    const history = await jsonOf(await call("GET", "/v1/ns/app/history", { token: a.token }));
    expect(history.revisions.map((r: { rev: number }) => r.rev)).toEqual([4, 3, 2, 1]);
    expect(history.revisions[0]).toMatchObject({ rev: 4, kind: "revert", revertedTo: 1 });
    // The revisions it did not touch still hold their own bodies.
    expect((await jsonOf(await call("GET", "/v1/ns/app/history/3", { token: a.token }))).body).toBe("n: 3\n");
    expect(history.revisions[1]).not.toHaveProperty("revertedTo");

    const one = await jsonOf(await call("GET", "/v1/ns/app/history/4", { token: a.token }));
    expect(one).toMatchObject({ kind: "revert", revertedTo: 1 });
  });

  it("can itself be reverted, and gets a default summary", async () => {
    const a = await seed(2);
    await call("POST", "/v1/ns/app/revert", { token: a.token, body: { rev: 1, ifMatch: 2 } });
    const undo = await call("POST", "/v1/ns/app/revert", { token: a.token, body: { rev: 2, ifMatch: 3 } });
    expect(await jsonOf(undo)).toEqual({ rev: 4 });
    expect(await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }))).toMatchObject({ rev: 4, body: "n: 2\n", summary: "Revert to revision 2" });
  });

  it("a stale ifMatch is 409 with the current document and writes nothing", async () => {
    const a = await seed(3);
    const stale = await call("POST", "/v1/ns/app/revert", { token: a.token, body: { rev: 1, ifMatch: 2 } });
    expect(stale.status).toBe(409);
    expect(await jsonOf(stale)).toMatchObject({ rev: 3, body: "n: 3\n", error: "conflict" });
    expect((await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a.token }))).rev).toBe(3);
  });

  it("404 for a revision that does not exist, 400 for bad input", async () => {
    const a = await seed(2);
    expect((await call("POST", "/v1/ns/app/revert", { token: a.token, body: { rev: 9, ifMatch: 2 } })).status).toBe(404);
    expect((await call("POST", "/v1/ns/app/revert", { token: a.token, body: { rev: 0, ifMatch: 2 } })).status).toBe(400);
    expect((await call("POST", "/v1/ns/app/revert", { token: a.token, body: { rev: 1 } })).status).toBe(400);
  });
});
