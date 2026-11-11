import type { Sql } from "../core/ports";

/** D1 is the shared SQLite dialect, so the queries stay in core and this is the whole adapter. */
export function d1Sql(db: D1Database): Sql {
  const prepare = (sql: string, params: readonly unknown[]) => db.prepare(sql).bind(...params);
  return {
    first: <T>(sql: string, ...params: unknown[]) => prepare(sql, params).first<T>(),
    all: async <T>(sql: string, ...params: unknown[]) => (await prepare(sql, params).all<T>()).results,
    run: async (sql, ...params) => ({ changes: (await prepare(sql, params).run()).meta.changes }),
    batch: async (statements) => {
      await db.batch(statements.map((s) => prepare(s.sql, s.params)));
    },
  };
}
