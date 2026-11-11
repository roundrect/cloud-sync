import { readdirSync } from "node:fs";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { INVITE, makeProject, removeProject, startCelld, type RunningCelld } from "./project";

// What only celld means: the self-host entry applies the D1 migrations itself, once, and the store survives a restart.
// (The API's behaviour is in test/contract, which runs against celld through test/harness/celld.ts.)

const files = readdirSync(join(import.meta.dirname, "../../migrations")).filter((name) => name.endsWith(".sql")).sort();

const dir = makeProject();
let running: RunningCelld | undefined;
afterAll(async () => {
  await running?.stop();
  removeProject(dir);
});

async function sql<T>(celld: RunningCelld, statement: string, ...params: unknown[]): Promise<T[]> {
  const response = await fetch(`${celld.url}/__test/sql`, { method: "POST", body: JSON.stringify({ op: "all", sql: statement, params }) });
  return (await response.json()) as T[];
}

const ledger = (celld: RunningCelld) => sql<{ name: string }>(celld, "SELECT name FROM d1_migrations ORDER BY id");

async function createAccount(celld: RunningCelld): Promise<string> {
  const response = await fetch(`${celld.url}/v1/ns/example/accounts`, { method: "POST", body: JSON.stringify({ invite: INVITE, deviceName: "Mac" }) });
  expect(response.status).toBe(201);
  return ((await response.json()) as { accountId: string }).accountId;
}

describe("the self-host entry on celld", () => {
  it("applies every migration in migrations/ once, and records each as wrangler does", async () => {
    running = await startCelld(dir);
    expect(files).toContain("0001_init.sql");
    // Equal to the directory listing, so a migration missing from src/celld/migrate.ts's list fails here.
    expect(await ledger(running)).toEqual(files.map((name) => ({ name })));
    const columns = await sql<{ name: string }>(running, "SELECT name FROM pragma_table_info('d1_migrations') ORDER BY cid");
    expect(columns.map((c) => c.name)).toEqual(["id", "name", "applied_at"]);
    for (const table of ["accounts", "devices", "pairings", "approve_failures"]) {
      expect(await sql(running, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", table)).toHaveLength(1);
    }
  });

  it("keeps its data across a restart of the same project and does not reapply migrations", async () => {
    const accountId = await createAccount(running!);
    const before = await sql<{ id: number; applied_at: string }>(running!, "SELECT id, applied_at FROM d1_migrations ORDER BY id");
    await running!.stop();

    running = await startCelld(dir);
    expect(await sql(running, "SELECT id FROM accounts WHERE id = ?", accountId)).toEqual([{ id: accountId }]);
    // Same rows, same ids, same timestamps: nothing was recorded a second time. (Re-running CREATE TABLE would have thrown.)
    expect(await sql(running, "SELECT id, applied_at FROM d1_migrations ORDER BY id")).toEqual(before);
    expect(await ledger(running)).toHaveLength(files.length);
  });
});
