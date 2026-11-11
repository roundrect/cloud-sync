import { describe, expect, it } from "vitest";
import { bootstrap, call, harness, jsonOf, pairDevice, putDoc } from "./helpers";

async function start(deviceName = "Mac B") {
  const response = await call("POST", "/v1/ns/app/pair/start", { body: { deviceName } });
  expect(response.status).toBe(201);
  return jsonOf<{ pairingId: string; pollSecret: string; code: string; expiresIn: number }>(response);
}

const poll = (s: { pairingId: string; pollSecret: string }) => call("POST", "/v1/ns/app/pair/poll", { body: { pairingId: s.pairingId, pollSecret: s.pollSecret } });

describe("pairing", () => {
  it("start returns a Crockford code, a poll secret and a 10 minute lifetime; only hashes are stored", async () => {
    const s = await start();
    expect(s.code).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/);
    expect(s.expiresIn).toBe(600);
    expect(s.pairingId).toMatch(/^pair_/);
    const row = await harness.sql.first<Record<string, string>>("SELECT code_hash, poll_secret_hash FROM pairings WHERE id = ?", s.pairingId);
    expect(row!.code_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(row)).not.toContain(s.pollSecret);
    expect(JSON.stringify(row)).not.toContain(s.code.replace("-", ""));
  });

  it("the optional PAIR_LIMITER binding, when it refuses, gives 429 on start and poll", async () => {
    const startResponse = await call("POST", "/v1/ns/app/pair/start", { body: { deviceName: "x" }, vars: { pairLimiter: "refuse" } });
    expect(startResponse.status).toBe(429);
    expect(await jsonOf(startResponse)).toMatchObject({ error: "rate_limited" });
    const pollResponse = await call("POST", "/v1/ns/app/pair/poll", { body: { pairingId: "p", pollSecret: "s" }, vars: { pairLimiter: "refuse" } });
    expect(pollResponse.status).toBe(429);
  });

  it("works with no PAIR_LIMITER binding at all", async () => {
    const response = await call("POST", "/v1/ns/app/pair/start", { body: { deviceName: "x" }, vars: { pairLimiter: "absent" } });
    expect(response.status).toBe(201);
  });

  it("poll is pending until approved, then returns the device and token exactly once", async () => {
    const approver = await bootstrap("Mac A");
    const s = await start("Mac B");
    expect(await jsonOf(await poll(s))).toEqual({ status: "pending" });

    // Previewing the code does not approve it.
    const preview = await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: s.code.toLowerCase() } });
    expect(preview.status).toBe(200);
    expect(await jsonOf(preview)).toEqual({ deviceName: "Mac B", namespace: "app" });
    expect(await jsonOf(await poll(s))).toEqual({ status: "pending" });

    const approve = await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: s.code, confirm: true } });
    expect(await jsonOf(approve)).toEqual({ approved: true, deviceName: "Mac B" });

    const first = await jsonOf(await poll(s));
    expect(first.status).toBe("approved");
    expect(first.accountId).toBe(approver.accountId);
    expect(first.device.name).toBe("Mac B");
    expect(first.token).toMatch(/^shk1_dev_/);
    expect((await call("GET", "/v1/ns/app/doc", { token: first.token })).status).toBe(200);

    expect((await jsonOf(await poll(s))).status).toBe("expired"); // consumed: no second token
    const devices = await jsonOf(await call("GET", "/v1/ns/app/devices", { token: approver.token }));
    expect(devices.devices.map((d: { name: string }) => d.name).sort()).toEqual(["Mac A", "Mac B"]);
  });

  it("a wrong poll secret never learns anything", async () => {
    const s = await start();
    const wrong = await call("POST", "/v1/ns/app/pair/poll", { body: { pairingId: s.pairingId, pollSecret: "nope" } });
    expect(await jsonOf(wrong)).toEqual({ status: "expired" });
  });

  it("an expired pairing cannot be approved or polled", async () => {
    const approver = await bootstrap();
    const s = await start();
    await harness.sql.run("UPDATE pairings SET expires_at = ? WHERE id = ?", new Date(Date.now() - 1000).toISOString(), s.pairingId);
    const approve = await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: s.code, confirm: true } });
    expect(approve.status).toBe(404);
    expect(await jsonOf(approve)).toMatchObject({ error: "invalid_code" });
    expect(await jsonOf(await poll(s))).toEqual({ status: "expired" });
  });

  it("an approved pairing that expires before the poll mints nothing", async () => {
    const approver = await bootstrap();
    const s = await start();
    await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: s.code, confirm: true } });
    await harness.sql.run("UPDATE pairings SET expires_at = ? WHERE id = ?", new Date(Date.now() - 1000).toISOString(), s.pairingId);
    expect((await jsonOf(await poll(s))).status).toBe("expired");
  });

  it("approve needs a token and a code that exists", async () => {
    expect((await call("POST", "/v1/ns/app/pair/approve", { body: { code: "AAAA-AAAA" } })).status).toBe(401);
    const approver = await bootstrap();
    expect((await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: "AAAA-AAAA" } })).status).toBe(404);
    expect((await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: 12 } })).status).toBe(404);
  });

  it("a pairing can be approved only once", async () => {
    const a = await bootstrap();
    const b = await bootstrap();
    const s = await start();
    expect((await call("POST", "/v1/ns/app/pair/approve", { token: a.token, body: { code: s.code, confirm: true } })).status).toBe(200);
    expect((await call("POST", "/v1/ns/app/pair/approve", { token: b.token, body: { code: s.code, confirm: true } })).status).toBe(404);
    expect((await jsonOf(await poll(s))).accountId).toBe(a.accountId);
  });

  it("rate limits approving: 5 wrong codes per device in 10 minutes, then 429 even for the right code", async () => {
    const approver = await bootstrap();
    const other = await bootstrap();
    const s = await start();
    for (let i = 0; i < 5; i++) {
      const bad = await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: "ZZZZ-ZZZZ" } });
      expect(bad.status).toBe(404);
    }
    const blocked = await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: s.code, confirm: true } });
    expect(blocked.status).toBe(429);
    expect(blocked.headers.get("retry-after")).toBeTruthy();
    expect(await jsonOf(blocked)).toMatchObject({ error: "rate_limited" });
    // The pairing is untouched, another device is unaffected, and the window slides.
    expect((await jsonOf(await poll(s))).status).toBe("pending");
    expect((await call("POST", "/v1/ns/app/pair/approve", { token: other.token, body: { code: s.code } })).status).toBe(200);
    await harness.sql.run("UPDATE approve_failures SET at = ? WHERE device_id = ?", new Date(Date.now() - 11 * 60 * 1000).toISOString(), approver.deviceId);
    expect((await call("POST", "/v1/ns/app/pair/approve", { token: approver.token, body: { code: s.code, confirm: true } })).status).toBe(200);
  });

  it("isolates accounts: the new device lands in the approver's account only", async () => {
    const a = await bootstrap("A1");
    const b = await bootstrap("B1");
    await putDoc(a, 0, "version: 1\n# a\n");
    await putDoc(b, 0, "version: 1\n# b\n");
    const a2 = await pairDevice(a, "A2");
    expect(a2.accountId).toBe(a.accountId);

    const seenByA2 = await jsonOf(await call("GET", "/v1/ns/app/doc", { token: a2.token }));
    expect(seenByA2.body).toBe("version: 1\n# a\n");
    const devicesOfB = await jsonOf(await call("GET", "/v1/ns/app/devices", { token: b.token }));
    expect(devicesOfB.devices.map((d: { id: string }) => d.id)).toEqual([b.deviceId]);

    // B can neither rename nor revoke A's devices.
    expect((await call("DELETE", `/v1/ns/app/devices/${a2.deviceId}`, { token: b.token })).status).toBe(404);
    expect((await call("PATCH", `/v1/ns/app/devices/${a.deviceId}`, { token: b.token, body: { name: "x" } })).status).toBe(404);
    expect((await call("GET", "/v1/ns/app/doc", { token: a2.token })).status).toBe(200);
  });
});

describe("devices", () => {
  it("lists, renames and revokes", async () => {
    const a = await bootstrap("Mac A");
    const b = await pairDevice(a, "Mac B");
    const list = await jsonOf(await call("GET", "/v1/ns/app/devices", { token: a.token }));
    expect(list.devices).toHaveLength(2);
    expect(list.devices.find((d: { id: string }) => d.id === a.deviceId).current).toBe(true);

    const renamed = await call("PATCH", `/v1/ns/app/devices/${b.deviceId}`, { token: a.token, body: { name: "Mini" } });
    expect(renamed.status).toBe(200);
    expect((await jsonOf(renamed)).name).toBe("Mini");
    expect((await call("PATCH", `/v1/ns/app/devices/${b.deviceId}`, { token: a.token, body: { name: "" } })).status).toBe(400);

    expect((await call("DELETE", `/v1/ns/app/devices/${b.deviceId}`, { token: a.token })).status).toBe(200);
    expect((await call("DELETE", `/v1/ns/app/devices/${b.deviceId}`, { token: a.token })).status).toBe(404);
    expect((await call("GET", "/v1/ns/app/doc", { token: b.token })).status).toBe(401);
    const after = await jsonOf(await call("GET", "/v1/ns/app/devices", { token: a.token }));
    expect(after.devices.map((d: { name: string }) => d.name)).toEqual(["Mac A"]);
  });
});
