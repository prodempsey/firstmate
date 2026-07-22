import { runExclusive } from './internal-runtime.mjs';

// CW1 read-only store seam. migrate-apply needs a few locked READS (the pre-mutation
// dirty-target probe, the post-apply coherence counts, the verb-trace check). QA
// qa-cw1-q82 finding 5 showed that reaching those reads through the raw `runExclusive`
// connection also handed the executor an unrestricted arbitrary-SQL capability - a raw
// `UPDATE coordinator_state ...` added to the executor was caught by nothing.
//
// This module is the ONLY place in CW1 that imports the exclusive connection primitive,
// and it exposes a SINGLE narrow capability: `readOnlyQuery`, which runs one statement
// inside a genuine Postgres READ ONLY transaction. The read-only property is enforced by
// the database, not by string inspection: `SET TRANSACTION READ ONLY` makes the engine
// reject INSERT/UPDATE/DELETE/DDL/data-modifying-CTE at runtime ("cannot execute UPDATE in
// a read-only transaction"), so a mutation added to the executor and routed through this
// seam FAILS rather than silently corrupting the store. A cheap lexical check also rejects
// anything that is not a leading SELECT/WITH, so obvious misuse fails fast with a clear
// message. migrate-apply imports ONLY this (never `internal-runtime`), so the executor has
// no path to a domain write except the landed command-envelope verb functions. Both
// guards are mutation-tested in test/cw1-migrate-apply.test.mjs.

// Cheap fail-fast lexical gate: a read must begin with SELECT or WITH. The AUTHORITATIVE
// guard is the READ ONLY transaction below; this only turns obvious misuse into a clear
// error instead of a database error.
export function assertSelectShape(sql) {
  if (typeof sql !== 'string' || sql.length === 0) {
    throw new Error('cw1-readonly: query must be a non-empty string');
  }
  if (!/^\s*(select|with)\b/i.test(sql)) {
    throw new Error(`cw1-readonly: only SELECT/WITH reads are permitted (got: ${sql.trim().slice(0, 24)}...)`);
  }
}

// Run one read-only statement under the exclusive flock and a READ ONLY transaction, and
// return its rows. A non-SELECT lexical shape fails fast; any statement that actually
// attempts to mutate fails at the database (the transaction is read-only).
export async function readOnlyQuery(store, sql, params) {
  assertSelectShape(sql);
  return runExclusive(store, async (conn) => {
    await conn.query('SET TRANSACTION READ ONLY');
    const r = await conn.query(sql, params);
    return r.rows;
  });
}
