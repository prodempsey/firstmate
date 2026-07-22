import { runExclusive } from './internal-runtime.mjs';

// CW1 per-source-record RECEIPT LEDGER (qa-cw1r2-q83 finding 3). Every mapped source
// record's application decision is keyed by its own (source_ref, source.digest) - the
// stable `recordKey` - and persisted here, INCLUDING subsumed and collapsed records that
// do not own a domain command. On resume, a record whose recordKey is already in the
// ledger is classified a replay; a record whose source hash CHANGED has a different
// recordKey, is absent from the ledger, and is honestly reprocessed as new (never a false
// replay). This closes the finding-3 gap where subsumed records inherited an owner
// command's replay status.
//
// Like every domain-store module, this owns exactly ONE table and reaches the exclusive
// transaction only through the sanctioned in-package seam. It exposes NO arbitrary-SQL
// capability: its only writes are the two parameterized statements below (schema apply +
// batched receipt upsert), so it does not reopen the finding-5 hole - the executor still
// has no path to an ad-hoc mutation.

const RECEIPTS_DDL = `
CREATE TABLE IF NOT EXISTS migration_receipts (
  record_key    TEXT PRIMARY KEY,
  source_ref    TEXT NOT NULL,
  source_digest TEXT NOT NULL,
  disposition   TEXT NOT NULL CHECK (disposition IN ('applied','residual')),
  verb          TEXT,
  reason        TEXT,
  created_at    TEXT NOT NULL
);`;

// True when the ledger table exists (a cheap presence read).
export async function receiptsTablePresent(store) {
  return runExclusive(store, async (conn) => {
    const r = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'migration_receipts'"
    );
    return r.rows.length > 0;
  });
}

// Load every prior receipt as record_key -> { source_ref, disposition, verb, reason }.
// Absent table -> empty (a fresh target has no prior migration).
export async function loadReceipts(store) {
  return runExclusive(store, async (conn) => {
    const present = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'migration_receipts'"
    );
    const out = new Map();
    if (present.rows.length === 0) return out;
    const r = await conn.query('SELECT record_key, source_ref, source_digest, disposition, verb, reason FROM migration_receipts');
    for (const row of r.rows) {
      out.set(row.record_key, { source_ref: row.source_ref, source_digest: row.source_digest, disposition: row.disposition, verb: row.verb, reason: row.reason });
    }
    return out;
  });
}

// Persist every record's receipt in ONE exclusive transaction (batched so the ledger
// costs one commit, not one per record). Idempotent: a record_key already present is left
// unchanged (ON CONFLICT DO NOTHING), so a resume never rewrites a prior decision.
export async function writeReceipts(store, entries, { now }) {
  if (!Array.isArray(entries) || entries.length === 0) return { written: 0 };
  return runExclusive(store, async (conn) => {
    await conn.exec(RECEIPTS_DDL);
    let written = 0;
    for (const e of entries) {
      const r = await conn.query(
        `INSERT INTO migration_receipts (record_key, source_ref, source_digest, disposition, verb, reason, created_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (record_key) DO NOTHING`,
        [e.record_key, e.source_ref, e.source_digest, e.disposition, e.verb ?? null, e.reason ?? null, now]
      );
      written += r.rowCount ?? 0;
    }
    return { written };
  });
}
