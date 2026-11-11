import { describe, expect, it } from "vitest";
import { bootstrap, call, harness, jsonOf } from "./helpers";

const old = { "sync-client": "0.2.30" };

describe("MIN_CLIENT is a map from namespace to version", () => {
  it("426 for a client below its own namespace's minimum, on the routes of that namespace only", async () => {
    const alpha = await bootstrap("Mac A", "alpha");
    const beta = await bootstrap("Mac B", "beta");
    const vars = { minClient: JSON.stringify({ alpha: "0.3.0" }) };

    const refused = await call("GET", "/v1/ns/alpha/doc", { token: alpha.token, headers: old, vars });
    expect(refused.status).toBe(426);
    expect(await jsonOf(refused)).toMatchObject({ error: "upgrade_required" });
    expect((await call("POST", "/v1/ns/alpha/pair/start", { body: { deviceName: "x" }, headers: old, vars })).status).toBe(426);
    expect((await call("POST", "/v1/ns/alpha/accounts", { body: { invite: harness.invite, deviceName: "x" }, headers: old, vars })).status).toBe(426);

    // A namespace with no entry has no minimum.
    expect((await call("GET", "/v1/ns/beta/doc", { token: beta.token, headers: old, vars })).status).toBe(200);
    expect((await call("POST", "/v1/ns/gamma/pair/start", { body: { deviceName: "x" }, headers: old, vars })).status).toBe(201);

    // At or above the minimum, with no header, and on meta, the request goes through.
    expect((await call("GET", "/v1/ns/alpha/doc", { token: alpha.token, headers: { "sync-client": "0.3.0" }, vars })).status).toBe(200);
    expect((await call("GET", "/v1/ns/alpha/doc", { token: alpha.token, headers: { "sync-client": "0.10.0" }, vars })).status).toBe(200);
    expect((await call("GET", "/v1/ns/alpha/doc", { token: alpha.token, vars })).status).toBe(200);
    expect((await call("GET", "/v1/ns/alpha/meta", { headers: old, vars })).status).toBe(200);
  });

  it("/v1/ns/<ns>/meta answers for that namespace, and /v1/meta publishes no minimum", async () => {
    const vars = { minClient: JSON.stringify({ alpha: "0.3.0", delta: "0.4.1" }) };
    expect(await jsonOf(await call("GET", "/v1/meta", { vars }))).toEqual({ api: 1 });
    expect(await jsonOf(await call("GET", "/v1/ns/alpha/meta", { vars }))).toEqual({ api: 1, minClient: "0.3.0" });
    expect(await jsonOf(await call("GET", "/v1/ns/beta/meta", { vars }))).toEqual({ api: 1, minClient: "0.0.0" });
    // A namespace named like an Object.prototype member has no minimum, not a function.
    expect(await jsonOf(await call("GET", "/v1/ns/constructor/meta", { vars }))).toEqual({ api: 1, minClient: "0.0.0" });
  });

  it("a malformed value fails closed: 500 on every route, and nobody is let through", async () => {
    const a = await bootstrap("Mac A", "alpha");
    const bad = ["not json", "[]", "null", '"0.3.0"', "0.3.0", '{"alpha":3}', '{"alpha":"v1"}', '{"Bad Slug":"1.0"}', '{"alpha":"1.0"', '{"alpha":""}'];
    for (const minClient of bad) {
      for (const [method, path, token] of [
        ["GET", "/v1/ns/alpha/doc", a.token],
        ["GET", "/v1/ns/alpha/meta", undefined],
        ["GET", "/v1/meta", undefined],
        ["POST", "/v1/ns/alpha/pair/start", undefined],
      ] as const) {
        const response = await call(method, path, { token, body: method === "POST" ? { deviceName: "x" } : undefined, vars: { minClient } });
        expect(response.status, `${minClient} ${path}`).toBe(500);
        expect(await jsonOf(response)).toMatchObject({ error: "misconfigured" });
      }
    }
    // An empty value is "no minimums", the same as {}.
    expect((await call("GET", "/v1/ns/alpha/doc", { token: a.token, vars: { minClient: "" } })).status).toBe(200);
  });
});
