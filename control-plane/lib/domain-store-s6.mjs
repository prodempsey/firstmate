import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runExclusive } from './internal-runtime.mjs';
import { ValidationError } from './errors.mjs';
import { ensureInitialized, canonicalJson, sha256hex, coerceJson } from './domain-store.mjs';
import { acquireStableOrderPrefix } from './order-prefix.mjs';
import { SnapshotNotFoundError } from './errors-s6.mjs';

// S6 domain layer: snapshot insertion and the locked snapshot read (spec 9.1-9.3,
// section 12 S6 row 891).
//
// Like S2/S3/S4/S5 this module adds NO new arbitrary-SQL path: it reaches the store
// only through the sanctioned in-package seam (runExclusive), and it imports no
// PGlite (owner-guard clean). It owns exactly one table (snapshots, sql/domain-schema-s6.sql)
// and NEVER mutates any S0-S5 table - the snapshot build READS tasks/runs/anomalies/
// outbox/consumer rows inside the same exclusive transaction that inserts the snapshot,
// for a consistent view, and writes nothing back to them.
//
// projection_revision OWNERSHIP. `cp snapshot` is the ONLY writer of
// coordinator_state.projection_revision in the whole system. A NEW snapshot bumps
// projection_revision +1 AND commit_sequence +1, and leaves domain_revision UNTOUCHED
// (a snapshot is a projection of domain state, not a domain mutation; the dedup key in
// spec 411/765 depends on domain_revision staying put across idempotent rebuilds). The
// idempotent-return path bumps NOTHING. tasks.revision is never touched. This is why
// every S1-S5 mutation-sensitive test still asserts projection_revision stays 0 across
// THEIR operations: nothing but this verb moves it.

const SQL_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'sql');
const DOMAIN_SCHEMA_S6 = fs.readFileSync(path.join(SQL_DIR, 'domain-schema-s6.sql'), 'utf8');

const DOMAIN_SCHEMA_S6_KEY = 'domain_schema_s6';
const DOMAIN_SCHEMA_S6_VERSION = 's6';

function nowIso() {
  return new Date().toISOString();
}

// Apply the S6 schema idempotently at the start of an S6 snapshot transaction (the
// applyS2Schema pattern). The snapshots table is IF NOT EXISTS, so this is a no-op
// after the first snapshot. Deliberately does NOT run during `cp init` or any S1-S5
// verb, so those slices' schema footprints stay byte-identical.
async function applyS6Schema(conn) {
  await conn.exec(DOMAIN_SCHEMA_S6);
  await conn.query(
    `INSERT INTO schema_meta (key, value) VALUES ($1, $2)
       ON CONFLICT (key) DO NOTHING`,
    [DOMAIN_SCHEMA_S6_KEY, DOMAIN_SCHEMA_S6_VERSION]
  );
}

// Presence check for a table an earlier slice creates lazily (tasks/runs/anomalies
// are S1; outbox is S2; consumer_* are S4). A snapshot of a freshly-`init`ed store
// with no domain commands has none of them, and that is a valid empty projection, not
// an error - each read below degrades to an empty section when its table is absent.
async function tablePresent(conn, table) {
  const r = await conn.query('SELECT to_regclass($1) AS reg', [`public.${table}`]);
  return r.rows[0].reg !== null;
}

function numOrNull(v) {
  return v === null || v === undefined ? null : Number(v);
}

// Build the deterministic snapshot payload from a consistent in-transaction view of
// the domain tables plus the folded order prefix (spec 757-763). Determinism is
// load-bearing: the payload is what the checksum covers, so every read is ORDER BY its
// primary key and every value is a stable scalar (bigints -> Number, timestamptz cast
// to ::text in SQL). Nothing volatile (no build-time now(), no wall-clock age) enters
// the payload, or the dedup-by-checksum idempotency (spec 765) would break - a rebuild
// over unchanged domain+order state MUST reproduce the identical checksum.
async function buildPayload(conn, orderPrefix) {
  const tasks = [];
  if (await tablePresent(conn, 'tasks')) {
    const r = await conn.query(
      `SELECT task_id, kind, title, repo, task_origin, order_ref, internal_reason, status,
              revision, current_generation,
              created_at::text AS created_at, updated_at::text AS updated_at,
              archived_at::text AS archived_at
         FROM tasks ORDER BY task_id`
    );
    for (const t of r.rows) {
      tasks.push({
        task_id: t.task_id, kind: t.kind, title: t.title, repo: t.repo ?? null,
        task_origin: t.task_origin, order_ref: t.order_ref ?? null,
        internal_reason: t.internal_reason ?? null, status: t.status,
        revision: numOrNull(t.revision), current_generation: numOrNull(t.current_generation),
        created_at: t.created_at, updated_at: t.updated_at, archived_at: t.archived_at ?? null
      });
    }
  }

  const runs = [];
  if (await tablePresent(conn, 'runs')) {
    const r = await conn.query(
      `SELECT task_id, run_generation, status, binding_state, cleanup_state,
              endpoint_id, pane_id, harness, worktree, backend,
              created_at::text AS created_at, verified_at::text AS verified_at,
              closed_at::text AS closed_at
         FROM runs ORDER BY task_id, run_generation`
    );
    for (const rn of r.rows) {
      runs.push({
        task_id: rn.task_id, run_generation: numOrNull(rn.run_generation), status: rn.status,
        binding_state: rn.binding_state, cleanup_state: rn.cleanup_state,
        endpoint_id: rn.endpoint_id ?? null, pane_id: rn.pane_id ?? null,
        harness: rn.harness ?? null, worktree: rn.worktree ?? null, backend: rn.backend ?? null,
        created_at: rn.created_at, verified_at: rn.verified_at ?? null, closed_at: rn.closed_at ?? null
      });
    }
  }

  // Active AND resolved anomaly summaries (spec 761). The active list drives the
  // orphan inspector and any staleness/anomaly surfacing; resolved rows are preserved
  // history (spec 828), summarized here as a count so the payload stays bounded.
  const activeAnomalies = [];
  let resolvedAnomalyCount = 0;
  if (await tablePresent(conn, 'anomalies')) {
    const r = await conn.query(
      `SELECT fingerprint, anomaly_class, task_id, run_generation, endpoint_id, pane_id,
              agent_pid, agent_start_ticks, terminal_fingerprint, status, resolution_kind,
              occurrence_count, first_seen_at::text AS first_seen_at, last_seen_at::text AS last_seen_at
         FROM anomalies ORDER BY fingerprint`
    );
    for (const a of r.rows) {
      if (a.status === 'resolved') { resolvedAnomalyCount += 1; continue; }
      activeAnomalies.push({
        fingerprint: a.fingerprint, anomaly_class: a.anomaly_class, task_id: a.task_id ?? null,
        run_generation: numOrNull(a.run_generation), endpoint_id: a.endpoint_id ?? null,
        pane_id: a.pane_id ?? null, agent_pid: numOrNull(a.agent_pid),
        agent_start_ticks: numOrNull(a.agent_start_ticks),
        terminal_fingerprint: a.terminal_fingerprint ?? null,
        occurrence_count: numOrNull(a.occurrence_count),
        first_seen_at: a.first_seen_at, last_seen_at: a.last_seen_at
      });
    }
  }

  // Consumer/outbox delivery summary (spec 762; Q2 ruling: MINIMAL faithful summary).
  // Per-consumer cursor position, the unacked outbox count, and the oldest unacked
  // event's id + its stored created_at. AGE is deliberately NOT computed here: a
  // wall-clock age would be volatile and shatter idempotent dedup; projections derive a
  // display age from oldest_unacked.created_at at render time (spec 786 staleness).
  const consumers = [];
  if (await tablePresent(conn, 'consumer_cursors')) {
    const r = await conn.query(
      `SELECT consumer_id, last_acked_outbox_id, last_acked_at::text AS last_acked_at
         FROM consumer_cursors ORDER BY consumer_id`
    );
    for (const c of r.rows) {
      consumers.push({
        consumer_id: c.consumer_id, last_acked_outbox_id: numOrNull(c.last_acked_outbox_id),
        last_acked_at: c.last_acked_at ?? null
      });
    }
  }
  let unackedCount = 0;
  let oldestUnacked = null;
  if (await tablePresent(conn, 'outbox')) {
    const cnt = await conn.query('SELECT count(*)::int AS n FROM outbox WHERE acked_at IS NULL');
    unackedCount = Number(cnt.rows[0].n);
    if (unackedCount > 0) {
      const o = await conn.query(
        `SELECT event_id, outbox_id, created_at::text AS created_at
           FROM outbox WHERE acked_at IS NULL ORDER BY outbox_id LIMIT 1`
      );
      const row = o.rows[0];
      oldestUnacked = { event_id: row.event_id, outbox_id: numOrNull(row.outbox_id), created_at: row.created_at };
    }
  }

  const payload = {
    tasks,
    runs,
    anomalies: { active: activeAnomalies, active_count: activeAnomalies.length, resolved_count: resolvedAnomalyCount },
    delivery: { consumers, unacked_count: unackedCount, oldest_unacked: oldestUnacked },
    orders: {
      source_path: orderPrefix.path,
      bytes: orderPrefix.bytes,
      hash: orderPrefix.hash,
      present: orderPrefix.present,
      count: orderPrefix.records.length,
      records: orderPrefix.records
    }
  };

  // CW2 (ORD-256): carry the audit-only archived_history projection so the archive back-fill
  // is VISIBLE to the canonical snapshot/export/projection boundary rather than invisible to
  // it. The section is deterministic (ORDER BY record_key, stable scalars, no wall-clock) so
  // it folds into the dedup checksum exactly like every other section. The key is added ONLY
  // when the table exists AND holds rows, so a store that never ran the CW2 back-fill
  // produces the byte-identical S0-S8 payload it always did - existing snapshot checksums and
  // dedup behavior are unchanged; the payload grows only once history is actually imported.
  if (await tablePresent(conn, 'archived_history')) {
    const ah = await conn.query(
      `SELECT record_key, task_id, record_class, terminal_outcome, run_generation,
              source_ref, source_store, source_digest, archived_at
         FROM archived_history ORDER BY record_key`
    );
    if (ah.rows.length > 0) {
      payload.archived_history = ah.rows.map((r) => ({
        record_key: r.record_key,
        task_id: r.task_id,
        record_class: r.record_class,
        terminal_outcome: r.terminal_outcome ?? null,
        run_generation: numOrNull(r.run_generation),
        source_ref: r.source_ref,
        source_store: r.source_store ?? null,
        source_digest: r.source_digest,
        archived_at: r.archived_at ?? null
      }));
    }
  }

  return payload;
}

// createSnapshot: acquire the stable order prefix, then in ONE exclusive transaction
// read a consistent domain view, dedup by (domain_revision, order bytes, order hash,
// checksum), and either return the matching latest snapshot unchanged (idempotent, no
// counter moves) or increment projection_revision + commit_sequence and insert a new
// row (spec 765-766).
//
// Fault seams (test-only, both wired by test/workers/crash-snapshot-writer.mjs):
//   * `fault` fires INSIDE the transaction right after the INSERT and before COMMIT;
//     throwing (or a hard exit) rolls the WHOLE bundle back - no row, no counter move -
//     proving atomicity.
//   * `faultAfterCommit` fires AFTER the transaction has durably committed and before
//     the result is returned, modelling a crash "between insert and return"; recovery
//     is a plain rerun, which dedups to the same row (idempotent, no second row).
export async function createSnapshot(store, {
  orderSourcePath,
  now = nowIso(),
  // eslint-disable-next-line no-unused-vars
  commandId, // accepted for symmetry (spec 593 note); the natural dedup IS the idempotency
  orderPrefixOptions = {},
  orderPrefix = null,
  fault,
  faultAfterCommit
} = {}) {
  const outcome = await runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    await applyS6Schema(conn);

    // FINDING-1 FIX (qa-s6-q72): capture the stable order prefix INSIDE the exclusive
    // transaction, under the same per-home flock that guards the insert. Previously the
    // prefix was captured BEFORE runExclusive, which let two callers serialize in the
    // OPPOSITE order from their prefix captures: a caller that read a one-order prefix and
    // paused could commit a NEWER projection_revision carrying an OLDER prefix than a later
    // capture that had already committed. With capture under the lock, capture order ==
    // commit order == projection_revision order, so under an append-only source
    // order_source_bytes is monotonically non-decreasing with projection_revision and a
    // later revision can never forget an append an earlier revision already folded (spec
    // 753). Tests may still inject a pre-captured `orderPrefix` for exact byte boundaries.
    const prefix = orderPrefix || await acquireStableOrderPrefix(orderSourcePath, orderPrefixOptions);

    const cs = await conn.query('SELECT domain_revision FROM coordinator_state WHERE id = 1');
    const domainRevision = Number(cs.rows[0].domain_revision);

    const payload = await buildPayload(conn, prefix);
    const checksum = sha256hex(canonicalJson(payload));

    // Dedup by the spec-411/765 four-tuple. Under the whole-transaction flock this SELECT
    // sees every prior committed snapshot, so a rebuild over unchanged state - even a
    // concurrent racer's just-committed row - matches and returns idempotently. The
    // four-column UNIQUE is the structural backstop behind this check.
    const dedup = await conn.query(
      `SELECT snapshot_id, projection_revision, checksum, created_at::text AS created_at
         FROM snapshots
        WHERE domain_revision = $1 AND order_source_bytes = $2 AND order_source_hash = $3 AND checksum = $4
        ORDER BY projection_revision DESC LIMIT 1`,
      [domainRevision, prefix.bytes, prefix.hash, checksum]
    );
    if (dedup.rows.length > 0) {
      const row = dedup.rows[0];
      return {
        deduped: true,
        result: {
          snapshot_id: Number(row.snapshot_id),
          projection_revision: Number(row.projection_revision),
          domain_revision: domainRevision,
          checksum: row.checksum,
          order_source_path: prefix.path,
          order_source_bytes: prefix.bytes,
          order_source_hash: prefix.hash,
          created_at: row.created_at,
          deduped: true
        }
      };
    }

    // A NEW snapshot: bump projection_revision + commit_sequence (domain_revision
    // untouched), insert the row at the bumped projection revision.
    const bumped = await conn.query(
      `UPDATE coordinator_state
          SET projection_revision = projection_revision + 1, commit_sequence = commit_sequence + 1
        WHERE id = 1
        RETURNING projection_revision`
    );
    const newRevision = Number(bumped.rows[0].projection_revision);
    const ins = await conn.query(
      `INSERT INTO snapshots
         (projection_revision, domain_revision, checksum, order_source_path,
          order_source_bytes, order_source_hash, created_at, payload_json)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
       RETURNING snapshot_id, created_at::text AS created_at`,
      [newRevision, domainRevision, checksum, prefix.path, prefix.bytes, prefix.hash, now, JSON.stringify(payload)]
    );

    // Test-only pre-commit crash: the INSERT + counter bump are written but uncommitted;
    // throwing rolls the whole transaction back, persisting nothing.
    if (typeof fault === 'function') fault();

    return {
      deduped: false,
      result: {
        snapshot_id: Number(ins.rows[0].snapshot_id),
        projection_revision: newRevision,
        domain_revision: domainRevision,
        checksum,
        order_source_path: prefix.path,
        order_source_bytes: prefix.bytes,
        order_source_hash: prefix.hash,
        created_at: ins.rows[0].created_at,
        deduped: false
      }
    };
  });

  // Test-only post-commit crash: the row is durable; a rerun dedups to it idempotently.
  if (typeof faultAfterCommit === 'function') faultAfterCommit(outcome.result);

  return outcome.result;
}

// getSnapshot: the locked READ behind `cp project` and `cp export-snapshot`. Reads the
// snapshots table ONLY - never a domain table (spec 733-734) - so a projection can
// never surface live domain state that was not in the captured snapshot. No command-id,
// no counter bump. `revision` absent -> the latest snapshot; a REQUESTED revision that
// is absent -> SnapshotNotFoundError, NEVER a silent fall-back to latest (Q6 ruling).
export async function getSnapshot(store, { revision = null } = {}) {
  return runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    if (!(await tablePresent(conn, 'snapshots'))) {
      throw new SnapshotNotFoundError(
        revision === null
          ? 'no snapshot exists yet (run `cp snapshot` first)'
          : `snapshot revision ${revision} not found (no snapshots exist yet)`,
        { requested_revision: revision }
      );
    }
    let row;
    if (revision === null) {
      const r = await conn.query(
        `SELECT snapshot_id, projection_revision, domain_revision, checksum, order_source_path,
                order_source_bytes, order_source_hash, created_at::text AS created_at, payload_json
           FROM snapshots ORDER BY projection_revision DESC LIMIT 1`
      );
      if (r.rows.length === 0) {
        throw new SnapshotNotFoundError('no snapshot exists yet (run `cp snapshot` first)', { requested_revision: null });
      }
      row = r.rows[0];
    } else {
      const r = await conn.query(
        `SELECT snapshot_id, projection_revision, domain_revision, checksum, order_source_path,
                order_source_bytes, order_source_hash, created_at::text AS created_at, payload_json
           FROM snapshots WHERE projection_revision = $1`,
        [revision]
      );
      if (r.rows.length === 0) {
        throw new SnapshotNotFoundError(
          `snapshot revision ${revision} not found (never taken; S6 prunes nothing)`,
          { requested_revision: revision }
        );
      }
      row = r.rows[0];
    }
    return {
      snapshot_id: Number(row.snapshot_id),
      projection_revision: Number(row.projection_revision),
      domain_revision: Number(row.domain_revision),
      checksum: row.checksum,
      order_source_path: row.order_source_path,
      order_source_bytes: Number(row.order_source_bytes),
      order_source_hash: row.order_source_hash,
      created_at: row.created_at,
      payload: coerceJson(row.payload_json)
    };
  });
}

// Resolve the canonical order inbox path for `cp snapshot` WITHOUT ever guessing the
// real captain inbox: an explicit --order-source flag or CP_ORDER_SOURCE_PATH env
// (the test-isolation and explicit-override path), else FM_HOME/config/orders-path's
// contents. If none resolves, it raises loudly rather than defaulting into a real
// ledger - production inbox wiring is a cutover concern (out of S6 scope), and S6 must
// never read or lock the real captain inbox on a guess.
export function resolveOrderSourcePath({ explicit, env = process.env } = {}) {
  if (typeof explicit === 'string' && explicit.length > 0) return explicit;
  if (typeof env.CP_ORDER_SOURCE_PATH === 'string' && env.CP_ORDER_SOURCE_PATH.length > 0) {
    return env.CP_ORDER_SOURCE_PATH;
  }
  const home = env.FM_HOME;
  if (home) {
    const pointer = path.join(home, 'config', 'orders-path');
    try {
      const p = fs.readFileSync(pointer, 'utf8').trim();
      if (p.length > 0) return p;
    } catch {
      // no pointer file; fall through to the loud error
    }
  }
  throw new ValidationError(
    'cp snapshot could not resolve the order source path; pass --order-source <path> or set CP_ORDER_SOURCE_PATH',
    { fm_home: home ?? null }
  );
}

export { applyS6Schema, buildPayload, DOMAIN_SCHEMA_S6_KEY };
