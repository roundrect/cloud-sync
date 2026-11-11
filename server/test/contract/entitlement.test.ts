import { describe, expect, it } from "vitest";
import { bootstrap, call, envelope, harness, jsonOf, putDoc } from "./helpers";

const enforce = { enforceEntitlement: "1" };

const revisionCount = (accountId: string) => harness.revisionCount(`${accountId}:app`);

describe("entitlement seam", () => {
  it("is off by default: an account with no entitlement works", async () => {
    const a = await bootstrap();
    expect((await putDoc(a, 0, "v: 1\n")).status).toBe(200);
  });

  it("402 for a lapsed account before the Durable Object is touched", async () => {
    const a = await bootstrap();
    await harness.sql.run("UPDATE accounts SET entitled_until = ? WHERE id = ?", new Date(Date.now() - 86_400_000).toISOString(), a.accountId);

    const put = await call("PUT", "/v1/ns/app/doc", { token: a.token, vars: enforce, headers: { "if-match": "0" }, body: await envelope("v: 1\n") });
    expect(put.status).toBe(402);
    expect(await jsonOf(put)).toMatchObject({ error: "payment_required" });
    for (const [method, path, body] of [["GET", "/v1/ns/app/doc"], ["GET", "/v1/ns/app/history"], ["GET", "/v1/ns/app/history/1"], ["POST", "/v1/ns/app/revert", { rev: 1, ifMatch: 0 }]] as const) {
      expect((await call(method, path, { token: a.token, vars: enforce, body })).status).toBe(402);
    }
    expect(await revisionCount(a.accountId)).toBe(0);

    // Without enforcement the same account is fine, and nothing was queued by the refused attempts.
    expect((await putDoc(a, 0, "v: 1\n")).status).toBe(200);
    expect(await revisionCount(a.accountId)).toBe(1);
  });

  it("fails closed for an account with no entitlement once enforcement is on; a future date passes", async () => {
    const a = await bootstrap();
    expect((await call("GET", "/v1/ns/app/doc", { token: a.token, vars: enforce })).status).toBe(402);
    await harness.sql.run("UPDATE accounts SET entitled_until = ? WHERE id = ?", new Date(Date.now() + 86_400_000).toISOString(), a.accountId);
    expect((await call("GET", "/v1/ns/app/doc", { token: a.token, vars: enforce })).status).toBe(200);
  });

  it("device management and unlinking stay available to a lapsed account", async () => {
    const a = await bootstrap();
    expect((await call("GET", "/v1/ns/app/devices", { token: a.token, vars: enforce })).status).toBe(200);
    expect((await call("DELETE", `/v1/ns/app/devices/${a.deviceId}`, { token: a.token, vars: enforce })).status).toBe(200);
  });
});
