import { describe, expect, it } from "vitest";
import { bootstrap, call, connect, harness, jsonOf, pairDevice, putDoc } from "./helpers";

describe("WebSocket", () => {
  it("rejects an upgrade with no token, and a plain GET with no upgrade", async () => {
    expect((await harness.upgrade("/v1/ns/app/ws")).status).toBe(401);
    const a = await bootstrap();
    const plain = await call("GET", "/v1/ns/app/ws", { token: a.token });
    expect(plain.status).toBe(400);
    expect(await jsonOf(plain)).toMatchObject({ error: "websocket_required" });
  });

  it("hello carries the current rev", async () => {
    const a = await bootstrap();
    const empty = await connect(a);
    expect(await empty.next()).toEqual({ type: "hello", rev: 0 });
    empty.raw.close(1000);
    await putDoc(a, 0, "v: 1\n");
    await putDoc(a, 1, "v: 2\n");
    const later = await connect(a);
    expect(await later.next()).toEqual({ type: "hello", rev: 2 });
    later.raw.close(1000);
  });

  it("answers the application-level ping with a pong", async () => {
    const a = await bootstrap();
    const socket = await connect(a);
    await socket.next((m) => m.type === "hello");
    socket.raw.send('{"type":"ping"}');
    expect(await socket.next((m) => m.type === "pong")).toEqual({ type: "pong" });
    socket.raw.close(1000);
  });

  it("broadcasts every write to every socket of the account, and to no other account", async () => {
    const a = await bootstrap("Mac A");
    const b = await pairDevice(a, "Mac B");
    const stranger = await bootstrap("Elsewhere");
    const [sa, sb, ss] = [await connect(a), await connect(b), await connect(stranger)];
    await Promise.all([sa.next((m) => m.type === "hello"), sb.next((m) => m.type === "hello"), ss.next((m) => m.type === "hello")]);

    expect((await putDoc(a, 0, "v: 1\n", "first")).status).toBe(200);
    for (const socket of [sa, sb]) {
      const message = await socket.next((m) => m.type === "doc");
      expect(message).toMatchObject({
        type: "doc", rev: 1, format: "app-text", schema: 1, body: "v: 1\n", summary: "first", kind: "bootstrap",
        deviceId: a.deviceId, deviceName: "Mac A", sha256: expect.stringMatching(/^[0-9a-f]{64}$/),
      });
    }

    // A revert is broadcast like any write.
    expect((await call("POST", "/v1/ns/app/revert", { token: b.token, body: { rev: 1, ifMatch: 1 } })).status).toBe(200);
    const reverted = await sa.next((m) => m.type === "doc" && m.rev === 2);
    expect(reverted).toMatchObject({ kind: "revert", revertedTo: 1, deviceName: "Mac B" });

    // A rejected write is not broadcast.
    expect((await putDoc(a, 0, "v: stale\n")).status).toBe(409);
    expect(sa.messages.filter((m) => m.type === "doc")).toHaveLength(2);
    expect(ss.messages.map((m) => m.type)).toEqual(["hello"]);
    for (const s of [sa, sb, ss]) s.raw.close(1000);
  });

  it("revoking a device closes that device's socket and no other", async () => {
    const a = await bootstrap("Mac A");
    const b = await pairDevice(a, "Mac B");
    const sa = await connect(a);
    const sb = await connect(b);
    await Promise.all([sa.next(), sb.next()]);

    expect((await call("DELETE", `/v1/ns/app/devices/${b.deviceId}`, { token: a.token })).status).toBe(200);
    const closed = await sb.closed;
    expect(closed.code).toBe(4401);
    expect(closed.reason).toBe("revoked");

    // Mac A is still connected and still hears writes; the revoked token cannot reconnect.
    await putDoc(a, 0, "v: 1\n");
    expect(await sa.next((m) => m.type === "doc")).toMatchObject({ rev: 1 });
    expect((await harness.upgrade("/v1/ns/app/ws", b.token)).status).toBe(401);
    sa.raw.close(1000);
  });
});
