import { runExclusive } from './internal-runtime.mjs';

// CW2 SHADOW-ANNOTATION audit table. The shadow writer (lib/shadow-writer.mjs) mirrors
// firstmate lifecycle actions into the live control-plane store fire-and-forget. Many
// chokepoints (dispatch, a run-scoped status transition, completion, teardown, archive)
// have no legal live-path representation UNTIL a real `cp-launch` run generation exists:
// begin-run/event/complete/cleanup/archive all require a run this stage does not create
// (the same anti-ghost rule CW1 encoded - no fabricated runs). Rather than fabricate a run
// to hang those actions on, the writer records an AUDIT ANNOTATION here: an honest
// "firstmate did X to task T" row that carries the lifecycle signal WITHOUT asserting any
// run, event, or binding the live tables would then have to answer for. When a real run
// does exist (post-cp-launch), the writer drives the landed verb instead and no annotation
// is written; see shadow-writer.mjs for that branch.
//
// Like cw1-ledger, this owns exactly ONE table and reaches the exclusive transaction only
// through the sanctioned in-package seam. It exposes NO arbitrary-SQL capability: its only
// writes are the two parameterized statements below (schema apply + idempotent insert), so
// the writer that imports it gains no ad-hoc mutation path. Idempotency is the command_id
// PRIMARY KEY with ON CONFLICT DO NOTHING: a double-mirror of the same logical action is a
// no-op, never a duplicate row.

const ANNOTATIONS_DDL = `
CREATE TABLE IF NOT EXISTS shadow_annotations (
  command_id  TEXT PRIMARY KEY,
  task_id     TEXT NOT NULL,
  action      TEXT NOT NULL,
  detail_json TEXT,
  source      TEXT,
  created_at  TEXT NOT NULL
);`;

// True when the annotation table exists (a cheap presence read). Absent -> no shadow
// annotation has ever been recorded in this store.
export async function annotationsTablePresent(store) {
  return runExclusive(store, async (conn) => {
    const r = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'shadow_annotations'"
    );
    return r.rows.length > 0;
  });
}

// Record ONE annotation idempotently. The command_id is the stable identity of the logical
// mirror action, so a replay (ON CONFLICT DO NOTHING) writes nothing. Returns the number of
// rows actually inserted (0 on replay, 1 on first sight).
export async function recordAnnotation(store, { commandId, taskId, action, detail, source, now }) {
  if (typeof commandId !== 'string' || commandId.length === 0) {
    throw new Error('recordAnnotation: commandId is required');
  }
  return runExclusive(store, async (conn) => {
    await conn.exec(ANNOTATIONS_DDL);
    const detailJson = detail === undefined || detail === null ? null : JSON.stringify(detail);
    // RETURNING (not rowCount) is the reliable new-vs-replay signal: PGlite exposes
    // affectedRows, not rowCount, so an ON CONFLICT DO NOTHING that inserts a new row
    // returns exactly that row, and a replay returns none.
    const r = await conn.query(
      `INSERT INTO shadow_annotations (command_id, task_id, action, detail_json, source, created_at)
         VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (command_id) DO NOTHING RETURNING command_id`,
      [commandId, taskId, action, detailJson, source ?? null, now]
    );
    return { written: r.rows.length };
  });
}

// Load every annotation ordered by (task_id, created_at, command_id) for tests and audit
// surfaces. Absent table -> empty.
export async function loadAnnotations(store) {
  return runExclusive(store, async (conn) => {
    const present = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'shadow_annotations'"
    );
    if (present.rows.length === 0) return [];
    const r = await conn.query(
      `SELECT command_id, task_id, action, detail_json, source, created_at
         FROM shadow_annotations ORDER BY task_id, created_at, command_id`
    );
    return r.rows.map((row) => ({
      command_id: row.command_id,
      task_id: row.task_id,
      action: row.action,
      detail: row.detail_json === null || row.detail_json === undefined ? null : JSON.parse(row.detail_json),
      source: row.source ?? null,
      created_at: row.created_at
    }));
  });
}
