import { describe, expect, it } from "vitest";
import { bootstrap, call, jsonOf } from "./helpers";

describe("/v1/meta and routing", () => {
  it("/v1/meta answers without auth with just the api version, and leaks no namespace", async () => {
    const response = await call("GET", "/v1/meta", { vars: { minClient: JSON.stringify({ alpha: "0.3.0" }) } });
    expect(response.status).toBe(200);
    expect(await jsonOf(response)).toEqual({ api: 1 });
  });

  it("/v1/ns/<ns>/meta answers with the api version and that namespace's minClient", async () => {
    const response = await call("GET", "/v1/ns/alpha/meta");
    expect(response.status).toBe(200);
    expect(await jsonOf(response)).toEqual({ api: 1, minClient: "0.0.0" });
  });

  it("a route with no namespace is 404 not_found, however it is called", async () => {
    const account = await bootstrap();
    for (const [method, path] of [["GET", "/v1/doc"], ["PUT", "/v1/doc"], ["GET", "/v1/history"], ["GET", "/v1/devices"], ["POST", "/v1/accounts"], ["POST", "/v1/pair/start"], ["GET", "/v1/ws"]] as const) {
      const response = await call(method, path, { token: account.token });
      expect(response.status, `${method} ${path}`).toBe(404);
      expect(await jsonOf(response)).toMatchObject({ error: "not_found" });
    }
  });

  it("returns the JSON error shape for unknown routes and methods", async () => {
    const missing = await call("GET", "/v1/nope");
    expect(missing.status).toBe(404);
    expect(await jsonOf(missing)).toMatchObject({ error: "not_found", message: expect.any(String) });
    const wrong = await call("DELETE", "/v1/meta");
    expect(wrong.status).toBe(405);
    expect(await jsonOf(wrong)).toMatchObject({ error: "method_not_allowed" });
  });

  it("426 for a Sync-Client below MIN_CLIENT, on authed and pairing routes, but not on meta", async () => {
    const account = await bootstrap();
    const vars = { minClient: JSON.stringify({ app: "0.3.0" }) };
    const old = await call("GET", "/v1/ns/app/doc", { token: account.token, headers: { "sync-client": "0.2.30" }, vars });
    expect(old.status).toBe(426);
    expect(await jsonOf(old)).toMatchObject({ error: "upgrade_required" });
    expect((await call("POST", "/v1/ns/app/pair/start", { body: { deviceName: "x" }, headers: { "sync-client": "0.2.30" }, vars })).status).toBe(426);
    expect((await call("GET", "/v1/meta", { headers: { "sync-client": "0.1.0" }, vars })).status).toBe(200);
    expect((await call("GET", "/v1/ns/app/meta", { headers: { "sync-client": "0.1.0" }, vars })).status).toBe(200);
    // At or above the minimum, and with no header at all, the request goes through.
    expect((await call("GET", "/v1/ns/app/doc", { token: account.token, headers: { "sync-client": "0.3.0" }, vars })).status).toBe(200);
    expect((await call("GET", "/v1/ns/app/doc", { token: account.token, headers: { "sync-client": "0.10.0" }, vars })).status).toBe(200);
    expect((await call("GET", "/v1/ns/app/doc", { token: account.token, vars })).status).toBe(200);
  });
});
