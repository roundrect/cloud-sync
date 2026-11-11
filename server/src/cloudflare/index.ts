import { createApp } from "../core/app";
import { HttpError } from "../core/errors";
import type { Config, DocHandle, Platform } from "../core/ports";
import { AccountDoc } from "./account-doc";
import { d1Sql } from "./d1";

// The Worker entry. workerd refuses any export but the handler and the Durable Object class, so this module
// has no others (test/workers/entry.test.ts keeps it that way).
export { AccountDoc };

function configOf(env: Env): Config {
  return {
    tokenPepper: env.TOKEN_PEPPER,
    inviteSecret: env.INVITE_SECRET,
    historyLimit: env.HISTORY_LIMIT,
    enforceEntitlement: env.ENFORCE_ENTITLEMENT,
    minClient: env.MIN_CLIENT,
  };
}

function docHandle(env: Env, name: string): DocHandle {
  const stub = env.ACCOUNT_DOC.get(env.ACCOUNT_DOC.idFromName(name));
  return {
    getDoc: () => stub.getDoc(),
    put: (ifMatch, doc, writer) => stub.put(ifMatch, doc, writer),
    revert: (rev, ifMatch, summary, writer) => stub.revert(rev, ifMatch, summary, writer),
    history: (before, limit) => stub.history(before, limit),
    revision: (rev) => stub.revision(rev),
    disconnect: (deviceId) => stub.disconnect(deviceId),
    connect: (request, deviceId) => {
      const headers = new Headers(request.headers);
      headers.set("x-sync-device-id", deviceId); // set by us, never trusted from the client
      return stub.fetch(new Request(request.url, { method: "GET", headers }));
    },
  };
}

function platformOf(env: Env): Platform {
  return {
    sql: d1Sql(env.DB),
    config: configOf(env),
    doc: (name) => docHandle(env, name),
    // Optional: if the binding is absent the Worker simply skips this limit (the approve-attempt limit lives in D1
    // and is always on). Guards /pair/start and /pair/poll per client IP.
    async limitPairing(route, request) {
      const limiter = (env as unknown as { PAIR_LIMITER?: RateLimit }).PAIR_LIMITER;
      if (!limiter) return;
      const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
      const { success } = await limiter.limit({ key: `${route}:${ip}` });
      if (!success) throw new HttpError(429, "rate_limited", "Too many requests. Try again shortly.", { "retry-after": "60" });
    },
  };
}

export default {
  fetch: (request: Request, env: Env): Promise<Response> => createApp(platformOf(env))(request),
} satisfies ExportedHandler<Env>;
