import worker, { AccountDoc as SyncAccountDoc } from "../../src/celld/index";
import { migrate } from "../../src/celld/migrate";
import { d1Sql } from "../../src/cloudflare/d1";
import type { Vars } from "../harness/types";

// The entry the celld contract tests run: src/celld/index.ts plus what a test needs to reach inside. It is never shipped
// (celld.jsonc points at src/celld/index.ts; only test/harness/celld.ts points here).

/** The same Durable Object class under the same name (the binding resolves it by name), with one extra RPC method. */
export class AccountDoc extends SyncAccountDoc {
  revisionCount(): number {
    return this.ctx.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM revisions").one().n;
  }
}

// The same mapping as test/harness/workers.ts.
function overrides(vars: Vars): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (vars.historyLimit !== undefined) out.HISTORY_LIMIT = vars.historyLimit;
  if (vars.enforceEntitlement !== undefined) out.ENFORCE_ENTITLEMENT = vars.enforceEntitlement;
  if (vars.minClient !== undefined) out.MIN_CLIENT = vars.minClient;
  if (vars.pairLimiter === "refuse") out.PAIR_LIMITER = { limit: async () => ({ success: false }) };
  if (vars.pairLimiter === "absent") out.PAIR_LIMITER = undefined;
  return out;
}

type SqlCall =
  | { op: "first" | "all" | "run"; sql: string; params: unknown[] }
  | { op: "batch"; statements: { sql: string; params: unknown[] }[] };

async function sql(request: Request, env: Env): Promise<Response> {
  const db = d1Sql(env.DB);
  const call = (await request.json()) as SqlCall;
  switch (call.op) {
    case "first":
      return Response.json((await db.first(call.sql, ...call.params)) ?? null);
    case "all":
      return Response.json(await db.all(call.sql, ...call.params));
    case "run":
      return Response.json(await db.run(call.sql, ...call.params));
    case "batch":
      await db.batch(call.statements);
      return Response.json(null);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/__test/sql" && request.method === "POST") {
      await migrate(env.DB);
      return sql(request, env);
    }
    if (url.pathname === "/__test/revisions") {
      const docs = env.ACCOUNT_DOC as unknown as DurableObjectNamespace<AccountDoc>;
      const n = await docs.get(docs.idFromName(url.searchParams.get("doc") ?? "")).revisionCount();
      return Response.json({ n });
    }
    const raw = request.headers.get("x-test-vars");
    if (raw === null) return worker.fetch(request, env);
    const headers = new Headers(request.headers);
    headers.delete("x-test-vars");
    return worker.fetch(new Request(request, { headers }), { ...env, ...overrides(JSON.parse(raw) as Vars) } as Env);
  },
} satisfies ExportedHandler<Env>;
