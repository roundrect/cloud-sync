import init from "../../migrations/0001_init.sql";

// `celld dev` has no migration command (`celld d1 migrations apply` needs a fleet bucket), so the self-host entry applies
// the D1 migrations itself. The list is explicit because a bundle cannot read a directory; test/celld/celld.test.ts
// fails if a file in migrations/ is missing from it.
export const MIGRATIONS: readonly { name: string; sql: string }[] = [{ name: "0001_init.sql", sql: init }];

/** Splits a migration into statements: drops `--` comments, then splits on `;` (no migration holds one in a string). */
export function statementsOf(sql: string): string[] {
  return sql
    .replace(/--[^\n]*/g, "")
    .split(";")
    .map((statement) => statement.trim())
    .filter((statement) => statement !== "");
}

// The same table, with the same columns, that `wrangler d1 migrations apply` keeps.
const CREATE_LEDGER =
  "CREATE TABLE IF NOT EXISTS d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)";

async function applied(db: D1Database): Promise<Set<string>> {
  const { results } = await db.prepare("SELECT name FROM d1_migrations").all<{ name: string }>();
  return new Set(results.map((row) => row.name));
}

/** Applies every pending migration, each as one atomic batch together with its ledger row. Returns the names applied. */
export async function migrate(db: D1Database, migrations: readonly { name: string; sql: string }[] = MIGRATIONS): Promise<string[]> {
  await db.prepare(CREATE_LEDGER).run();
  const done = await applied(db);
  const ran: string[] = [];
  for (const { name, sql } of migrations) {
    if (done.has(name)) continue;
    try {
      await db.batch([...statementsOf(sql).map((statement) => db.prepare(statement)), db.prepare("INSERT INTO d1_migrations (name) VALUES (?)").bind(name)]);
      ran.push(name);
    } catch (error) {
      // Another isolate may have applied it first, in which case ours failed whole and there is nothing to do.
      if (!(await applied(db)).has(name)) throw error;
    }
  }
  return ran;
}
