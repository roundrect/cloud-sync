import { describe, expect, it } from "vitest";
import { bootstrap, call, connect, envelope, harness, jsonOf, pairDevice, putDoc, route, type Account } from "./helpers";

const approve = (approver: Account, code: string, confirm = true) =>
  call("POST", route(approver.ns, "/pair/approve"), { token: approver.token, body: confirm ? { code, confirm: true } : { code } });
const startPairing = async (ns: string, deviceName = "Mac B") =>
  jsonOf<{ pairingId: string; pollSecret: string; code: string }>(await call("POST", route(ns, "/pair/start"), { body: { deviceName } }));
const poll = (ns: string, s: { pairingId: string; pollSecret: string }) =>
  call("POST", route(ns, "/pair/poll"), { body: { pairingId: s.pairingId, pollSecret: s.pollSecret } });

describe("namespace isolation", () => {
  it("403 namespace_mismatch for a token on another namespace's doc, history, history/:rev, revert and ws", async () => {
    const a = await bootstrap("Mac A", "alpha");
    await putDoc(a, 0, "v: 1\n");
    const attempts: Array<[string, string, unknown?]> = [
      ["GET", "/v1/ns/beta/doc"],
      ["PUT", "/v1/ns/beta/doc"],
      ["GET", "/v1/ns/beta/history"],
      ["GET", "/v1/ns/beta/history/1"],
      ["POST", "/v1/ns/beta/revert", { rev: 1, ifMatch: 0 }],
      ["GET", "/v1/ns/beta/devices"],
      ["POST", "/v1/ns/beta/pair/approve", { code: "AAAA-AAAA" }],
    ];
    for (const [method, path, body] of attempts) {
      const response = await call(method, path, { token: a.token, body: body ?? (method === "PUT" ? await envelope("x") : undefined), headers: method === "PUT" ? { "if-match": "0" } : {} });
      expect(response.status, `${method} ${path}`).toBe(403);
      expect(await jsonOf(response)).toMatchObject({ error: "namespace_mismatch" });
    }
    const socket = await harness.upgrade("/v1/ns/beta/ws", a.token);
    expect(socket.status).toBe(403);
    expect(JSON.parse(socket.text!)).toMatchObject({ error: "namespace_mismatch" });
    expect(await harness.revisionCount(`${a.accountId}:beta`)).toBe(0);
  });

  it("is checked before entitlement: a lapsed account learns nothing about another namespace", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const response = await call("GET", "/v1/ns/beta/doc", { token: a.token, vars: { enforceEntitlement: "1" } });
    expect(response.status).toBe(403);
  });

  it("an unknown token is 401 on every namespace, and a bad slug is 400", async () => {
    expect((await call("GET", "/v1/ns/alpha/doc", { token: "garbage" })).status).toBe(401);
    for (const slug of ["Alpha", "1alpha", "al_pha", "a".repeat(33), "al:pha"]) {
      const response = await call("GET", `/v1/ns/${slug}/meta`);
      expect(response.status, slug).toBe(400);
      expect(await jsonOf(response)).toMatchObject({ error: "bad_namespace" });
    }
    expect((await call("GET", `/v1/ns/${"a".repeat(32)}/meta`)).status).toBe(200);
  });

  it("two namespaces of one account hold separate documents and revisions, and broadcasts do not cross", async () => {
    const alpha = await bootstrap("Mac A", "alpha");
    const beta = await pairDevice(alpha, "Mac A (beta)", "beta"); // beta has no device yet, so alpha may approve into it
    expect(beta.accountId).toBe(alpha.accountId);
    const [sa, sb] = [await connect(alpha), await connect(beta)];
    await Promise.all([sa.next((m) => m.type === "hello"), sb.next((m) => m.type === "hello")]);

    expect((await putDoc(alpha, 0, "v: alpha\n", "in alpha")).status).toBe(200);
    expect((await putDoc(beta, 0, "v: beta 1\n", "in beta")).status).toBe(200); // beta's rev 0 is still rev 0
    expect((await putDoc(beta, 1, "v: beta 2\n", "again")).status).toBe(200);

    expect(await jsonOf(await call("GET", route("alpha", "/doc"), { token: alpha.token }))).toMatchObject({ rev: 1, body: "v: alpha\n" });
    expect(await jsonOf(await call("GET", route("beta", "/doc"), { token: beta.token }))).toMatchObject({ rev: 2, body: "v: beta 2\n" });
    const historyAlpha = await jsonOf(await call("GET", route("alpha", "/history"), { token: alpha.token }));
    const historyBeta = await jsonOf(await call("GET", route("beta", "/history"), { token: beta.token }));
    expect(historyAlpha.revisions.map((r: { rev: number }) => r.rev)).toEqual([1]);
    expect(historyBeta.revisions.map((r: { rev: number }) => r.rev)).toEqual([2, 1]);
    expect((await call("GET", route("alpha", "/history/2"), { token: alpha.token })).status).toBe(404);
    expect(await harness.revisionCount(`${alpha.accountId}:alpha`)).toBe(1);
    expect(await harness.revisionCount(`${alpha.accountId}:beta`)).toBe(2);

    // A revert in beta writes beta only.
    expect((await call("POST", route("beta", "/revert"), { token: beta.token, body: { rev: 1, ifMatch: 2 } })).status).toBe(200);
    expect((await jsonOf(await call("GET", route("alpha", "/doc"), { token: alpha.token }))).rev).toBe(1);

    await sb.next((m) => m.type === "doc" && m.rev === 3);
    await sa.next((m) => m.type === "doc");
    expect(sa.messages.filter((m) => m.type === "doc").map((m) => m.body)).toEqual(["v: alpha\n"]);
    expect(sb.messages.filter((m) => m.type === "doc").map((m) => m.body)).toEqual(["v: beta 1\n", "v: beta 2\n", "v: beta 1\n"]);
    sa.raw.close(1000);
    sb.raw.close(1000);
  });
});

describe("pairing across namespaces", () => {
  it("approves within the approver's own namespace, and the new device carries it", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const s = await startPairing("alpha");
    expect(await jsonOf(await approve(a, s.code, false))).toEqual({ deviceName: "Mac B", namespace: "alpha" });
    expect((await approve(a, s.code)).status).toBe(200);
    const done = await jsonOf(await poll("alpha", s));
    expect(done).toMatchObject({ status: "approved", accountId: a.accountId });
    expect((await call("GET", route("alpha", "/doc"), { token: done.token })).status).toBe(200);
    expect((await call("GET", route("beta", "/doc"), { token: done.token })).status).toBe(403);
    const devices = await jsonOf(await call("GET", route("alpha", "/devices"), { token: a.token }));
    expect(devices.devices.map((d: { name: string; namespace: string }) => [d.name, d.namespace])).toEqual([["Mac A", "alpha"], ["Mac B", "alpha"]]);
  });

  it("approves across namespaces into one where the account has no device, minting the device into the pairing's namespace", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const s = await startPairing("beta", "Mac A for beta");
    expect(await jsonOf(await approve(a, s.code, false))).toEqual({ deviceName: "Mac A for beta", namespace: "beta" });
    expect((await approve(a, s.code)).status).toBe(200);
    const done = await jsonOf(await poll("beta", s));
    expect(done.status).toBe("approved");
    expect(done.accountId).toBe(a.accountId);
    expect((await call("GET", route("beta", "/doc"), { token: done.token })).status).toBe(200);
    expect((await call("GET", route("alpha", "/doc"), { token: done.token })).status).toBe(403);
  });

  it("refuses when the target namespace already has a device, before the preview discloses a device name", async () => {
    const a = await bootstrap("Mac A", "alpha");
    await pairDevice(a, "First in beta", "beta");
    const s = await startPairing("beta", "Secret Name 123");
    for (const confirm of [false, true]) {
      const response = await approve(a, s.code, confirm);
      expect(response.status).toBe(403);
      const text = await response.text();
      expect(JSON.parse(text)).toMatchObject({ error: "namespace_mismatch" });
      expect(text).not.toContain("Secret Name 123");
    }
    expect((await jsonOf(await poll("beta", s))).status).toBe("pending"); // nothing was approved
  });

  it("a revoked device still counts: the namespace is not free again", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const first = await pairDevice(a, "First in beta", "beta");
    expect((await call("DELETE", route("beta", `/devices/${first.deviceId}`), { token: first.token })).status).toBe(200);
    const s = await startPairing("beta", "Another");
    const response = await approve(a, s.code);
    expect(response.status).toBe(403);
    expect(await jsonOf(response)).toMatchObject({ error: "namespace_mismatch" });
  });

  it("refuses in both directions once both namespaces have devices", async () => {
    const alpha = await bootstrap("Mac A", "alpha");
    const beta = await pairDevice(alpha, "Mac A in beta", "beta");
    const intoAlpha = await startPairing("alpha", "New alpha Mac");
    expect((await approve(beta, intoAlpha.code)).status).toBe(403);
    const intoBeta = await startPairing("beta", "New beta Mac");
    expect((await approve(alpha, intoBeta.code)).status).toBe(403);
    // Each may still approve into its own.
    expect((await approve(beta, intoBeta.code)).status).toBe(200);
    expect((await approve(alpha, intoAlpha.code)).status).toBe(200);
    expect((await jsonOf(await poll("beta", intoBeta))).status).toBe("approved");
  });

  it("an approval held across namespaces lapses if the namespace gains a device before the poll", async () => {
    const alpha = await bootstrap("Mac A", "alpha");
    const held = await startPairing("beta", "Waiting");
    expect((await approve(alpha, held.code)).status).toBe(200);

    // The namespace was empty at approval, but it isn't when the held pairing collects its token.
    const first = await pairDevice(alpha, "First in beta", "beta");
    await putDoc(first, 0, "v: private\n");
    expect(await jsonOf(await poll("beta", held))).toEqual({ status: "expired" });

    const { devices } = await jsonOf<{ devices: Array<{ name: string }> }>(await call("GET", route("alpha", "/devices"), { token: alpha.token }));
    expect(devices.map((d) => d.name).sort()).toEqual(["First in beta", "Mac A"]);
  });

  it("an approval from the namespace's own device is not affected by others joining first", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const held = await startPairing("alpha", "Waiting");
    expect((await approve(a, held.code)).status).toBe(200);
    await pairDevice(a, "Mac C", "alpha");
    expect(await jsonOf(await poll("alpha", held))).toMatchObject({ status: "approved" });
  });

  it("a poll that names a different namespace reads as expired and leaves the pairing alone", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const s = await startPairing("alpha");
    await approve(a, s.code);
    expect(await jsonOf(await poll("beta", s))).toEqual({ status: "expired" });
    expect((await jsonOf(await poll("alpha", s))).status).toBe("approved");
  });
});

describe("devices across namespaces", () => {
  it("lists the whole account with each device's namespace", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const b = await pairDevice(a, "Mac A in beta", "beta");
    const c = await pairDevice(a, "Mac C", "alpha");
    for (const viewer of [a, b]) {
      const list = await jsonOf(await call("GET", route(viewer.ns, "/devices"), { token: viewer.token }));
      expect(list.devices.map((d: { id: string; namespace: string }) => [d.id, d.namespace])).toEqual([
        [a.deviceId, "alpha"],
        [b.deviceId, "beta"],
        [c.deviceId, "alpha"],
      ]);
      expect(list.devices.filter((d: { current: boolean }) => d.current).map((d: { id: string }) => d.id)).toEqual([viewer.deviceId]);
    }
  });

  it("rename and revoke across namespaces are 404, and the device is untouched", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const b = await pairDevice(a, "Mac B", "beta");
    expect((await call("PATCH", route("alpha", `/devices/${b.deviceId}`), { token: a.token, body: { name: "Hijacked" } })).status).toBe(404);
    expect((await call("DELETE", route("alpha", `/devices/${b.deviceId}`), { token: a.token })).status).toBe(404);
    expect((await call("PATCH", route("beta", `/devices/${a.deviceId}`), { token: b.token, body: { name: "Hijacked" } })).status).toBe(404);
    expect((await call("DELETE", route("beta", `/devices/${a.deviceId}`), { token: b.token })).status).toBe(404);
    expect((await call("GET", route("beta", "/doc"), { token: b.token })).status).toBe(200);
    const list = await jsonOf(await call("GET", route("alpha", "/devices"), { token: a.token }));
    expect(list.devices.map((d: { name: string }) => d.name)).toEqual(["Mac A", "Mac B"]);
    // Within its own namespace it still works, and closes only that namespace's sockets.
    const sa = await connect(a);
    const sb = await connect(b);
    await Promise.all([sa.next(), sb.next()]);
    expect((await call("DELETE", route("beta", `/devices/${b.deviceId}`), { token: b.token })).status).toBe(200);
    expect((await sb.closed).code).toBe(4401);
    expect((await call("GET", route("alpha", "/doc"), { token: a.token })).status).toBe(200);
    sa.raw.close(1000);
  });
});
