import { runInDurableObject, SELF } from "cloudflare:test";
import { env } from "cloudflare:workers";
import worker from "../../src/cloudflare/index";
import { d1Sql } from "../../src/cloudflare/d1";
import { bufferedSocket } from "./socket";
import type { Harness, Vars } from "./types";

// The Worker, in Miniflare: the real entry, a real D1 and real Durable Objects. Test-only values come from vitest.config.ts.

const BASE = "https://sync.test";

function overrides(vars: Vars): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (vars.historyLimit !== undefined) out.HISTORY_LIMIT = vars.historyLimit;
  if (vars.enforceEntitlement !== undefined) out.ENFORCE_ENTITLEMENT = vars.enforceEntitlement;
  if (vars.minClient !== undefined) out.MIN_CLIENT = vars.minClient;
  if (vars.pairLimiter === "refuse") out.PAIR_LIMITER = { limit: async () => ({ success: false }) };
  if (vars.pairLimiter === "absent") out.PAIR_LIMITER = undefined;
  return out;
}

export const harness: Harness = {
  kind: "workers",
  invite: env.INVITE_SECRET,
  sql: d1Sql(env.DB),

  async request(method, path, { headers, body, vars }) {
    const request = new Request(`${BASE}${path}`, { method, headers, body });
    // Run the Worker's own fetch handler with these vars changed (the bindings stay real).
    if (vars) return worker.fetch(request, { ...env, ...overrides(vars) } as Env);
    return SELF.fetch(request);
  },

  async upgrade(path, token) {
    const headers: Record<string, string> = { upgrade: "websocket" };
    if (token) headers.authorization = `Bearer ${token}`;
    const response = await SELF.fetch(`${BASE}${path}`, { headers });
    const ws = response.webSocket;
    if (response.status !== 101 || !ws) return { status: response.status, text: await response.text() };
    ws.accept();
    const buffered = bufferedSocket((text) => ws.send(text), (code) => ws.close(code));
    ws.addEventListener("message", (event) => buffered.deliver(event.data as string));
    ws.addEventListener("close", (event) => buffered.closed(event.code, event.reason));
    return { status: 101, socket: buffered.socket };
  },

  revisionCount(docName) {
    const stub = env.ACCOUNT_DOC.get(env.ACCOUNT_DOC.idFromName(docName));
    return runInDurableObject(stub, (_instance, state) => state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM revisions").one().n);
  },
};
