import nodeFs from 'node:fs';
import path from 'node:path';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import {
  executeCommand, readTask, canonicalJson, sha256hex
} from './domain-store.mjs';
import { StateTransitionError } from './errors-s1.mjs';
import { ControlPlaneError } from './errors.mjs';
import { readOnlyQuery } from './cw1-readonly.mjs';
import { recordAnnotation, annotationsTablePresent } from './cw2-annotations.mjs';
import { runExclusive } from './internal-runtime.mjs';

// `cp shadow-reconcile --ledger <path> --data-dir <path> --out <path> --captain-approved [--task <id>]`
// (CW2+ shadow-window divergence reconciler). A narrow, sanctioned ADMINISTRATIVE path for
// reconciling the DOCUMENTED pre-shadow-enable divergence a captain-approved reconcile ledger
// names: legacy-derived expected terminal status is `completed`, but the store row is wrong
// (e.g. `failed` after the reconciler's spawn-timeout close of a synthetic generation-1 run).
//
// WHY A DEDICATED VERB (documented decision; QA adjudicates). The normal terminal path
// (`complete`) cannot express this reconciliation, and MUST NOT be forced to:
//   1. `complete` is legal only from {running, waiting_firstmate} over an OPEN run generation
//      (domain-store-s2.mjs COMPLETE_FROM). These rows are `failed` with the junk gen-1 run
//      already CLOSED, so `complete` rejects on both the task-state guard and the closed-run
//      terminal-conflict guard.
//   2. Reaching a legal `complete` would require fabricating a fresh RUN generation and a
//      real launch binding - the S3 identity-binding guard (record-spawn requires a genuine
//      launch registration) correctly refuses a hand-authored completion, and inventing a
//      run is exactly the CW1/CW2 anti-ghost violation (no run is ever asserted for work that
//      never launched under the control plane).
// So this verb reconciles the TASK terminal state DIRECTLY - and only the task row - through
// the sanctioned domain command envelope (executeCommand), fabricating NO run, event, or
// binding. The junk generation-1 run history is left BYTE-UNTOUCHED (not deleted): a
// reconciled task keeps its closed `failed` gen-1 run and its `failed` terminal event; only
// `tasks.status` advances to the ledger's expected terminal. The reconcile is "recorded as
// such" two ways - a dedicated `reconcile_terminals` marker row (producer `reconciler`,
// from/to status, ledger digest) AND an audit annotation per row in the shared
// `shadow_annotations` table (the same cp-shadow audit surface) carrying the ledger digest.
//
// NO NEW TASK-EVENT TYPE. A `completed` task_events row is impossible here (it must be
// run-scoped and unique-per-generation, and gen-1 already holds a terminal), and there is no
// `reconciled` event type in the ratified DDL vocabulary. Adding one would edit a landed
// schema, which this slice does not do. The marker table + annotation ARE the auditable
// record of the reconcile; the event log honestly still shows the original `failed` terminal.
//
// GATES (each refuses loudly, before ANY store write):
//   * `--captain-approved` is REQUIRED as an explicit bare flag (the ledger is a captain-
//     authorized administrative action; a missing/mistyped flag fails closed).
//   * the `--ledger` file must exist, be valid JSON, carry the ledger schema, and name a
//     non-empty, well-formed `entries[]` (task_id, terminal expected_status, evidence).
//   * a `--task <id>` filter naming a task NOT in the ledger is refused (the ledger is the
//     allowlist; nothing outside it is ever touched).
//   * the shadow window must be OPEN: the target store must show shadow-mode activity (the
//     `shadow_annotations` table present). A store the shadow writer never touched is not in
//     a shadow window and is refused.
//   * a row whose store status ALREADY equals its expected terminal is refused-in-place
//     (recorded `already_matched`, no core-domain write) rather than rewritten.
//
// IDEMPOTENT. Each entry's command is keyed by a deterministic command-id derived from the
// ledger digest and task id, so the command envelope replays a re-run instead of double-
// applying, and the marker/annotation inserts are ON CONFLICT DO NOTHING. Re-running the same
// approved ledger reports every row `replayed` and changes nothing.
//
// READ-ONLY-ELSEWHERE. The verb only ever writes `tasks` (via the envelope), its own marker
// table, and `shadow_annotations`. It never reads or writes the legacy home; the legacy
// stores remain the operational authority (a later cutover stage flips authority, not this).

export const RECONCILE_LEDGER_SCHEMA = 'control-plane/shadow-reconcile/ledger/v1';
export const RECONCILE_RECEIPT_SCHEMA = 'control-plane/shadow-reconcile/receipt/v1';

const CMD_PREFIX = 'cp-reconcile';

// The terminal task statuses a reconcile ledger may assert. `archived` has its own acked-
// terminal + cleaned prerequisites and is out of scope; reconcile targets the two run
// terminals only.
const TERMINAL_STATUSES = new Set(['completed', 'failed']);

// The reconcile marker table. Owned solely by this module and reached only through the
// sanctioned exclusive seam; its writes are the two parameterized statements below (schema
// apply inside the envelope mutate + the idempotent insert), so it opens no ad-hoc SQL path.
// command_id is the idempotency receipt (PRIMARY KEY, ON CONFLICT DO NOTHING).
const RECONCILE_TERMINALS_DDL = `
CREATE TABLE IF NOT EXISTS reconcile_terminals (
  command_id    TEXT PRIMARY KEY,
  task_id       TEXT NOT NULL,
  from_status   TEXT NOT NULL,
  to_status     TEXT NOT NULL,
  disposition   TEXT NOT NULL CHECK (disposition IN ('reconciled','already_matched')),
  producer      TEXT NOT NULL,
  ledger_digest TEXT NOT NULL,
  evidence_json TEXT,
  created_at    TEXT NOT NULL
);`;

// A shadow-reconcile CLI invocation was malformed at the surface, its ledger was missing/
// invalid/unapproved, the shadow window was not open, or per-entry reconciliation errored.
// Extends ControlPlaneError so bin/cp.mjs maps it to a typed nonzero exit like every verb.
export class ReconcileError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'shadow_reconcile');
    this.detail = detail || null;
  }
}

function nowIso() {
  return new Date().toISOString();
}

// ---------------------------------------------------------------------------------
// Ledger load + validation + digest
// ---------------------------------------------------------------------------------

// Deterministic digest over the ledger's reconciliation-bearing content (schema + normalized
// entries), independent of entry order and of any incidental fields (comments, provenance).
// This digest binds every derived command-id, so a tampered ledger produces different
// command-ids and can never masquerade as a replay of the approved one.
export function computeLedgerDigest(doc) {
  const normalized = doc.entries
    .map((e) => ({ task_id: e.task_id, expected_status: e.expected_status, evidence: e.evidence ?? null }))
    .sort((a, b) => (a.task_id < b.task_id ? -1 : a.task_id > b.task_id ? 1 : 0));
  return sha256hex(canonicalJson({ schema: doc.schema, entries: normalized }));
}

export function loadLedger(ledgerPath) {
  if (typeof ledgerPath !== 'string' || ledgerPath.length === 0) {
    throw new ReconcileError('shadow-reconcile requires --ledger <reconcile-ledger-path>', { ledger: ledgerPath ?? null });
  }
  let text;
  try {
    text = nodeFs.readFileSync(ledgerPath, 'utf8');
  } catch (err) {
    throw new ReconcileError('--ledger could not be read', { ledger: ledgerPath, cause: err.message });
  }
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    throw new ReconcileError('--ledger is not valid JSON', { ledger: ledgerPath });
  }
  if (!doc || doc.schema !== RECONCILE_LEDGER_SCHEMA) {
    throw new ReconcileError(`--ledger is not a ${RECONCILE_LEDGER_SCHEMA} document`, {
      ledger: ledgerPath, schema: doc && doc.schema ? doc.schema : null
    });
  }
  if (!Array.isArray(doc.entries) || doc.entries.length === 0) {
    throw new ReconcileError('--ledger has no entries[] to reconcile', { ledger: ledgerPath });
  }
  const seen = new Set();
  for (const e of doc.entries) {
    if (!e || typeof e.task_id !== 'string' || e.task_id.length === 0) {
      throw new ReconcileError('every ledger entry requires a non-empty task_id', { entry: e ?? null });
    }
    if (seen.has(e.task_id)) {
      throw new ReconcileError(`ledger names task '${e.task_id}' more than once`, { task_id: e.task_id });
    }
    seen.add(e.task_id);
    if (!TERMINAL_STATUSES.has(e.expected_status)) {
      throw new ReconcileError(
        `ledger entry '${e.task_id}' expected_status must be one of ${[...TERMINAL_STATUSES].join(', ')}`,
        { task_id: e.task_id, expected_status: e.expected_status ?? null }
      );
    }
    const refs = e.evidence && Array.isArray(e.evidence.source_refs) ? e.evidence.source_refs : null;
    if (!refs || refs.length === 0 || !refs.every((r) => typeof r === 'string' && r.length > 0)) {
      throw new ReconcileError(
        `ledger entry '${e.task_id}' requires evidence.source_refs[] (non-empty legacy source references)`,
        { task_id: e.task_id }
      );
    }
  }
  return { doc, digest: computeLedgerDigest(doc) };
}

// ---------------------------------------------------------------------------------
// Out containment (identical discipline to shadow-diff / migrate-backfill)
// ---------------------------------------------------------------------------------

function isAtOrUnder(root, p) {
  const rel = path.relative(root, p);
  return rel === '' || (!rel.startsWith(`..${path.sep}`) && rel !== '..' && !path.isAbsolute(rel));
}

function realDirOf(p) {
  let cur = path.resolve(p);
  const tail = [];
  for (;;) {
    if (nodeFs.existsSync(cur)) return path.join(nodeFs.realpathSync(cur), ...tail);
    const parent = path.dirname(cur);
    tail.unshift(path.basename(cur));
    if (parent === cur) return path.join(cur, ...tail);
    cur = parent;
  }
}

function realOf(p) {
  return nodeFs.existsSync(p) ? nodeFs.realpathSync(p) : path.resolve(p);
}

// Refuse an --out that resolves under the store directory: a reconcile receipt must never be
// written into the state it mutates (a symlinked ancestor is defeated by resolving the
// nearest existing output ancestor).
function resolveContainedOut(outPath, dataDir) {
  const outAbs = path.resolve(outPath);
  const resolvedDir = realDirOf(path.dirname(outAbs));
  const resolvedOut = path.join(resolvedDir, path.basename(outAbs));
  const realStore = realOf(dataDir);
  if (isAtOrUnder(realStore, resolvedDir) || isAtOrUnder(realStore, resolvedOut)) {
    throw new ReconcileError('--out resolves under the store data-dir (symlink or path traversal); refused', {
      out: resolvedOut, resolved_dir: resolvedDir, root: realStore
    });
  }
  return resolvedOut;
}

function atomicWriteOwnerOnly(outPath, content) {
  const dir = path.dirname(outPath);
  if (!nodeFs.existsSync(dir)) {
    nodeFs.mkdirSync(dir, { recursive: true });
    nodeFs.chmodSync(dir, 0o700);
  }
  const tmp = `${outPath}.tmp.${process.pid}`;
  const fd = nodeFs.openSync(tmp, 'w', 0o600);
  try {
    nodeFs.writeFileSync(fd, content);
    nodeFs.fsyncSync(fd);
  } finally {
    nodeFs.closeSync(fd);
  }
  nodeFs.chmodSync(tmp, 0o600);
  nodeFs.renameSync(tmp, outPath);
  nodeFs.chmodSync(outPath, 0o600);
}

// ---------------------------------------------------------------------------------
// Store reads (marker table load + receipt probe), through the read-only seam
// ---------------------------------------------------------------------------------

export async function reconcileTerminalsTablePresent(store) {
  return runExclusive(store, async (conn) => {
    const r = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'reconcile_terminals'"
    );
    return r.rows.length > 0;
  });
}

// Load every reconcile marker ordered by (task_id, created_at, command_id) for audit/tests.
export async function loadReconcileTerminals(store) {
  if (!(await reconcileTerminalsTablePresent(store))) return [];
  const rows = await readOnlyQuery(
    store,
    `SELECT command_id, task_id, from_status, to_status, disposition, producer, ledger_digest, evidence_json, created_at
       FROM reconcile_terminals ORDER BY task_id, created_at, command_id`
  );
  return rows.map((row) => ({
    command_id: row.command_id,
    task_id: row.task_id,
    from_status: row.from_status,
    to_status: row.to_status,
    disposition: row.disposition,
    producer: row.producer,
    ledger_digest: row.ledger_digest,
    evidence: row.evidence_json === null || row.evidence_json === undefined ? null : JSON.parse(row.evidence_json),
    created_at: row.created_at
  }));
}

// True when a committed command result already exists for this command-id (i.e. this exact
// reconcile has landed before). Read-only; tolerates a store with no command_results yet.
async function commandReceiptExists(store, commandId) {
  const present = await readOnlyQuery(
    store,
    "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'command_results'"
  );
  if (present.length === 0) return false;
  const rows = await readOnlyQuery(store, 'SELECT 1 FROM command_results WHERE command_id = $1', [commandId]);
  return rows.length > 0;
}

// ---------------------------------------------------------------------------------
// The domain reconcile: advance ONE task's terminal status through the command envelope
// ---------------------------------------------------------------------------------

// Reconcile a single task's terminal state to `expectedStatus`, WITHOUT fabricating a live
// run identity. Goes through the sanctioned executeCommand envelope (idempotency by
// command-id, the atomic domain-write + counter-bump + command_results bundle). The mutate
// touches only the `tasks` row and this slice's own `reconcile_terminals` marker; runs and
// task_events (including the junk gen-1 terminal) are never read or written, so history is
// preserved. A row already at `expectedStatus` is recorded `already_matched` with no core
// change.
export async function reconcileTerminal(store, {
  taskId, expectedStatus, ledgerDigest, evidence, producer = 'reconciler', commandId
}, { now = nowIso() } = {}) {
  if (typeof taskId !== 'string' || taskId.length === 0) {
    throw new ReconcileError('reconcileTerminal requires a task_id');
  }
  if (!TERMINAL_STATUSES.has(expectedStatus)) {
    throw new ReconcileError(`expected_status must be one of ${[...TERMINAL_STATUSES].join(', ')}`, { expected_status: expectedStatus ?? null });
  }
  if (typeof commandId !== 'string' || commandId.length === 0) {
    throw new ReconcileError('reconcileTerminal requires a commandId');
  }
  const evidenceJson = evidence === undefined || evidence === null ? null : JSON.stringify(evidence);
  const requestHash = sha256hex(canonicalJson({
    verb: 'shadow-reconcile', task_id: taskId, expected_status: expectedStatus,
    ledger_digest: ledgerDigest ?? null, producer, evidence: evidence ?? null
  }));

  return executeCommand(store, {
    verb: 'shadow-reconcile', commandId, requestHash, taskId, now,
    mutate: async (conn, ctx) => {
      await conn.exec(RECONCILE_TERMINALS_DDL);
      const task = await readTask(conn, taskId);
      if (!task) {
        throw new StateTransitionError(`unknown task: ${taskId}`, { task_id: taskId });
      }
      const fromStatus = task.status;

      // Refuse-in-place: a row already at its expected terminal is recorded as such and left
      // untouched (no revision bump, no status write).
      if (fromStatus === expectedStatus) {
        await conn.query(
          `INSERT INTO reconcile_terminals
             (command_id, task_id, from_status, to_status, disposition, producer, ledger_digest, evidence_json, created_at)
             VALUES ($1,$2,$3,$4,'already_matched',$5,$6,$7,$8) ON CONFLICT (command_id) DO NOTHING`,
          [commandId, taskId, fromStatus, expectedStatus, producer, ledgerDigest ?? '', evidenceJson, ctx.now]
        );
        return {
          result: {
            task_id: taskId, disposition: 'already_matched', from_status: fromStatus,
            to_status: expectedStatus, status: fromStatus, revision: Number(task.revision),
            ledger_digest: ledgerDigest ?? null
          },
          committedRevision: Number(task.revision), domainChanged: false
        };
      }

      // Advance ONLY the task row. No run generation, terminal event, or binding is created:
      // the reconcile carries no fabricated live-run identity. The origin-immutable trigger is
      // untouched (task_origin/order_ref/internal_reason are not modified).
      const newRevision = Number(task.revision) + 1;
      await conn.query(
        'UPDATE tasks SET status = $1, revision = $2, updated_at = $3 WHERE task_id = $4 AND revision = $5',
        [expectedStatus, newRevision, ctx.now, taskId, Number(task.revision)]
      );
      await conn.query(
        `INSERT INTO reconcile_terminals
           (command_id, task_id, from_status, to_status, disposition, producer, ledger_digest, evidence_json, created_at)
           VALUES ($1,$2,$3,$4,'reconciled',$5,$6,$7,$8) ON CONFLICT (command_id) DO NOTHING`,
        [commandId, taskId, fromStatus, expectedStatus, producer, ledgerDigest ?? '', evidenceJson, ctx.now]
      );
      return {
        result: {
          task_id: taskId, disposition: 'reconciled', from_status: fromStatus,
          to_status: expectedStatus, status: expectedStatus, revision: newRevision,
          ledger_digest: ledgerDigest ?? null
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// ---------------------------------------------------------------------------------
// Executor (the `cp shadow-reconcile` verb)
// ---------------------------------------------------------------------------------

export async function runShadowReconcile({
  ledgerPath, dataDir, outPath, captainApproved = false, taskFilter, env = process.env, now = nowIso
} = {}) {
  if (typeof dataDir !== 'string' || dataDir.length === 0) {
    throw new ReconcileError('shadow-reconcile requires --data-dir <control-plane store path>', { data_dir: dataDir ?? null });
  }
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new ReconcileError('shadow-reconcile requires --out <receipt-path>', { out: outPath ?? null });
  }
  // Unsigned-by-flag refusal: the explicit bare --captain-approved flag is the whole consent.
  if (captainApproved !== true) {
    throw new ReconcileError(
      'shadow-reconcile refuses without --captain-approved: the reconcile ledger is a captain-authorized administrative action and must be explicitly approved',
      { captain_approved: captainApproved }
    );
  }

  const { doc, digest } = loadLedger(ledgerPath);
  const allowed = new Map(doc.entries.map((e) => [e.task_id, e]));
  if (taskFilter !== undefined) {
    if (!allowed.has(taskFilter)) {
      throw new ReconcileError(`refused: task '${taskFilter}' is not named in the ledger (the ledger is the allowlist)`, { task_id: taskFilter });
    }
  }
  const resolvedOut = resolveContainedOut(outPath, dataDir);
  const clock = typeof now === 'function' ? now : () => now;
  const shortDigest = digest.slice(0, 16);

  const store = PgliteLocalStore.create({ dataDir, env });
  const results = [];
  try {
    // Shadow-window-open gate: the target store must show shadow-mode activity. A store the
    // shadow writer never touched is not in a shadow window, so reconcile is refused.
    if (!(await annotationsTablePresent(store))) {
      throw new ReconcileError(
        'shadow window is not open: the target store shows no shadow-mode activity (no shadow_annotations); reconcile is only sanctioned during the CW2+ shadow window',
        { data_dir: dataDir }
      );
    }

    const toProcess = taskFilter !== undefined ? [allowed.get(taskFilter)] : doc.entries;
    for (const entry of toProcess) {
      const commandId = `${CMD_PREFIX}:${shortDigest}:${entry.task_id}`;
      const receiptExists = await commandReceiptExists(store, commandId);
      let record;
      try {
        const res = await reconcileTerminal(store, {
          taskId: entry.task_id, expectedStatus: entry.expected_status,
          ledgerDigest: digest, evidence: entry.evidence, producer: 'reconciler', commandId
        }, { now: clock() });
        const disposition = receiptExists ? 'replayed' : res.disposition;
        // Audit annotation carrying the ledger digest (idempotent by command-id; separate
        // exclusive section, so it is written after the envelope commits rather than nested).
        await recordAnnotation(store, {
          commandId: `${CMD_PREFIX}:annot:${entry.task_id}:${shortDigest}`,
          taskId: entry.task_id,
          action: 'reconcile-terminal',
          detail: {
            ledger_digest: digest, expected_status: entry.expected_status,
            from_status: res.from_status, disposition, command_id: commandId,
            evidence: entry.evidence ?? null
          },
          source: CMD_PREFIX,
          now: clock()
        });
        record = {
          task_id: entry.task_id, expected_status: entry.expected_status, disposition,
          from_status: res.from_status, to_status: res.to_status, revision: res.revision
        };
      } catch (err) {
        record = {
          task_id: entry.task_id, expected_status: entry.expected_status, disposition: 'error',
          error: err && err.message ? err.message : String(err),
          code: err && err.code ? err.code : null
        };
      }
      results.push(record);
    }
  } finally {
    await store.close();
  }

  const totals = { reconciled: 0, already_matched: 0, replayed: 0, error: 0 };
  for (const r of results) {
    if (totals[r.disposition] !== undefined) totals[r.disposition] += 1;
  }
  const ok = totals.error === 0;

  const report = {
    schema: RECONCILE_RECEIPT_SCHEMA,
    posture: 'administrative task-terminal reconcile of documented pre-shadow-enable divergence; no run/event/binding fabricated; gen-1 run history preserved; legacy stores untouched',
    ledger: path.resolve(ledgerPath),
    ledger_schema: doc.schema,
    ledger_digest: digest,
    data_dir: dataDir,
    captain_approved: true,
    shadow_window_open: true,
    task_filter: taskFilter ?? null,
    totals,
    entries: results,
    ok
  };
  atomicWriteOwnerOnly(resolvedOut, `${JSON.stringify(report, null, 2)}\n`);

  if (!ok) {
    throw new ReconcileError('shadow-reconcile completed with per-entry errors; receipt written for audit', {
      out: resolvedOut, totals
    });
  }

  return { out: resolvedOut, data_dir: dataDir, ledger_digest: digest, totals, ok };
}
