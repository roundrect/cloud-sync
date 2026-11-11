import { describe, expect, it } from "vitest";
import { bootstrap, call, harness, jsonOf } from "./helpers";

describe("authentication", () => {
  it("401 with no token, a malformed token, a wrong secret and an unknown device", async () => {
    const account = await bootstrap();
    expect((await call("GET", "/v1/ns/app/doc")).status).toBe(401);
    expect((await call("GET", "/v1/ns/app/doc", { token: "garbage" })).status).toBe(401);
    expect((await call("GET", "/v1/ns/app/doc", { token: "shk1_dev_0000000000000000_" + "A".repeat(43) })).status).toBe(401);
    const tampered = account.token.slice(0, -1) + (account.token.endsWith("A") ? "B" : "A");
    const response = await call("GET", "/v1/ns/app/doc", { token: tampered });
    expect(response.status).toBe(401);
    expect(await jsonOf(response)).toMatchObject({ error: "unauthorized" });
    expect((await call("GET", "/v1/ns/app/doc", { token: account.token })).status).toBe(200);
  });

  it("401 once the device is revoked", async () => {
    const account = await bootstrap();
    expect((await call("GET", "/v1/ns/app/devices", { token: account.token })).status).toBe(200);
    const revoke = await call("DELETE", `/v1/ns/app/devices/${account.deviceId}`, { token: account.token });
    expect(revoke.status).toBe(200);
    expect((await call("GET", "/v1/ns/app/doc", { token: account.token })).status).toBe(401);
    expect((await call("GET", "/v1/ns/app/devices", { token: account.token })).status).toBe(401);
  });

  it("stores only a hash of the token secret", async () => {
    const account = await bootstrap();
    const row = await harness.sql.first<{ token_hash: string }>("SELECT token_hash FROM devices WHERE id = ?", account.deviceId);
    const secret = account.token.split("_").slice(3).join("_");
    expect(row?.token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(account.token).not.toContain(row!.token_hash);
    expect(row!.token_hash).not.toContain(secret);
  });
});

describe("account bootstrap", () => {
  it("creates an account and a first device with the invite", async () => {
    const response = await call("POST", "/v1/ns/app/accounts", { body: { invite: harness.invite, deviceName: "  MacBook Pro " } });
    expect(response.status).toBe(201);
    const data = await jsonOf(response);
    expect(data.accountId).toMatch(/^acc_[0-9a-f]{16}$/);
    expect(data.device).toEqual({ id: expect.stringMatching(/^dev_[0-9a-f]{16}$/), name: "MacBook Pro" });
    expect(data.token).toMatch(/^shk1_dev_[0-9a-f]{16}_[A-Za-z0-9_-]{43}$/);
    const doc = await call("GET", "/v1/ns/app/doc", { token: data.token });
    expect(await jsonOf(doc)).toEqual({ rev: 0 });
  });

  it("401 without the invite, with a wrong one, and with an empty one", async () => {
    for (const body of [{ deviceName: "x" }, { invite: "wrong", deviceName: "x" }, { invite: "", deviceName: "x" }]) {
      const response = await call("POST", "/v1/ns/app/accounts", { body });
      expect(response.status).toBe(401);
      expect(await jsonOf(response)).toMatchObject({ error: "invalid_invite" });
    }
  });

  it("400 for a bad device name or a body that is not JSON", async () => {
    expect((await call("POST", "/v1/ns/app/accounts", { body: { invite: harness.invite } })).status).toBe(400);
    expect((await call("POST", "/v1/ns/app/accounts", { body: { invite: harness.invite, deviceName: "   " } })).status).toBe(400);
    expect((await call("POST", "/v1/ns/app/accounts", { body: "not json" })).status).toBe(400);
  });
});
