import { runExclusive } from './internal-runtime.mjs';

// CW2 ARCHIVED-HISTORY table. The migrate-backfill executor (lib/migrate-backfill.mjs)
// imports the CW1 residual's archived-history deferrals here as AUDIT-ONLY historical
// records. This is a DISTINCT historical-record representation, deliberately separate from
// the live tasks/runs/task_events/outbox/consumer tables, chosen because genuine live-path
// synthesis of the terminal-delivery + ack + cleanup + archive chain is FORBIDDEN for
// historical import (spec section 4 requires the real ack/cleanup prerequisites; section 14
// excludes History synthesis; and fabricating spawned/running_verified/consumer-ack/sink
// rows would assert launch identity, consumer receipts, and sink effects that never
// happened - the same anti-ghost rule CW1 encoded, and the "no raw domain insert/import
// seam" property QA praised). See migrate-backfill.mjs for the full documented decision.
//
// Each row is a faithful pointer back to the legacy source (source_ref, source_store,
// source_digest, reason) plus the CW1 would-be canonical mapping (canonical_json) and the
// raw source record (source_json), so the historical record is losslessly recoverable and
// auditable. The snapshot layer CAN carry this table (it is an ordinary deterministic,
// queryable store table); folding it into a snapshot payload is a later (CW3) concern and
// is intentionally NOT wired into the byte-frozen S6 snapshot here.
//
// Like cw1-ledger, this owns exactly ONE table, reaches the exclusive transaction only
// through the sanctioned in-package seam, and exposes NO arbitrary-SQL capability: its only
// writes are the two parameterized statements below (schema apply + idempotent insert).
// Idempotency is the record_key PRIMARY KEY with ON CONFLICT DO NOTHING, so re-running the
// back-fill never duplicates a historical record.

const ARCHIVED_HISTORY_DDL = `
CREATE TABLE IF NOT EXISTS archived_history (
  record_key       TEXT PRIMARY KEY,
  task_id          TEXT NOT NULL,
  record_class     TEXT NOT NULL CHECK (record_class IN ('done_archive','multi_gen','archive_event')),
  terminal_outcome TEXT,
  run_generation   INTEGER,
  source_ref       TEXT NOT NULL,
  source_store     TEXT,
  source_digest    TEXT NOT NULL,
  archived_at      TEXT,
  canonical_json   TEXT NOT NULL,
  source_json      TEXT NOT NULL,
  reason           TEXT NOT NULL,
  created_at       TEXT NOT NULL
);`;

export async function archivedHistoryTablePresent(store) {
  return runExclusive(store, async (conn) => {
    const r = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'archived_history'"
    );
    return r.rows.length > 0;
  });
}

export async function countArchivedHistory(store) {
  return runExclusive(store, async (conn) => {
    const present = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'archived_history'"
    );
    if (present.rows.length === 0) return 0;
    const r = await conn.query('SELECT count(*)::int AS n FROM archived_history');
    return Number(r.rows[0].n);
  });
}

// Persist every archived-history record in ONE exclusive transaction (batched: one commit,
// not one per record). Idempotent: a record_key already present is left unchanged
// (ON CONFLICT DO NOTHING). Returns { written, newKeys[], replayedKeys[] } so the executor
// can report imported_new vs imported_replayed honestly.
export async function writeArchivedHistory(store, entries, { now }) {
  if (!Array.isArray(entries) || entries.length === 0) {
    return { written: 0, newKeys: [], replayedKeys: [] };
  }
  return runExclusive(store, async (conn) => {
    await conn.exec(ARCHIVED_HISTORY_DDL);
    const newKeys = [];
    const replayedKeys = [];
    let written = 0;
    for (const e of entries) {
      // RETURNING (not rowCount) is the reliable new-vs-replay signal: PGlite exposes
      // affectedRows, not rowCount, so a genuinely new insert returns its key and an
      // already-present record_key returns nothing.
      const r = await conn.query(
        `INSERT INTO archived_history
           (record_key, task_id, record_class, terminal_outcome, run_generation,
            source_ref, source_store, source_digest, archived_at, canonical_json, source_json, reason, created_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11::jsonb,$12,$13)
           ON CONFLICT (record_key) DO NOTHING RETURNING record_key`,
        [
          e.record_key, e.task_id, e.record_class, e.terminal_outcome ?? null, e.run_generation ?? null,
          e.source_ref, e.source_store ?? null, e.source_digest, e.archived_at ?? null,
          JSON.stringify(e.canonical ?? null), JSON.stringify(e.source ?? null), e.reason, now
        ]
      );
      const inserted = r.rows.length;
      written += inserted;
      if (inserted > 0) newKeys.push(e.record_key);
      else replayedKeys.push(e.record_key);
    }
    return { written, newKeys, replayedKeys };
  });
}

export async function loadArchivedHistory(store) {
  return runExclusive(store, async (conn) => {
    const present = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'archived_history'"
    );
    if (present.rows.length === 0) return [];
    const r = await conn.query(
      `SELECT record_key, task_id, record_class, terminal_outcome, run_generation,
              source_ref, source_store, source_digest, archived_at, reason, created_at
         FROM archived_history ORDER BY task_id, record_key`
    );
    return r.rows.map((row) => ({
      record_key: row.record_key,
      task_id: row.task_id,
      record_class: row.record_class,
      terminal_outcome: row.terminal_outcome ?? null,
      run_generation: row.run_generation === null || row.run_generation === undefined ? null : Number(row.run_generation),
      source_ref: row.source_ref,
      source_store: row.source_store ?? null,
      source_digest: row.source_digest,
      archived_at: row.archived_at ?? null,
      reason: row.reason,
      created_at: row.created_at
    }));
  });
}
