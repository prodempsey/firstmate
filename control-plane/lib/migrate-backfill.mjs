import nodeFs from 'node:fs';
import path from 'node:path';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { recordKey } from './migrate-apply.mjs';
import { RESIDUAL_SCHEMA as CW1_RESIDUAL_SCHEMA } from './migrate-apply.mjs';
import { writeArchivedHistory, countArchivedHistory } from './cw2-archived-history.mjs';
import { BackfillError, BackfillReconcileError } from './errors-cw2.mjs';

// `cp migrate-backfill --residual <cw1-residual> --data-dir <store> --out <path> [--resume]`
// (CUTOVER stage CW2, archived-history back-fill). Imports the ARCHIVED-HISTORY residual
// that CW1 deliberately DEFERRED - the done-archive / superseded-generation / task-scope-
// archived-event records the CW1 executor residualized "retained for the named CW2 archive
// back-fill stage" - as AUDIT-ONLY historical records in the archived_history table.
//
// THE SYNTHESIS DECISION (documented; QA adjudicates). The task asked whether the terminal-
// delivery + ack + cleanup + archive chain may be SYNTHESIZED for historical import. It may
// NOT, and this back-fill therefore does NOT drive the live archive path. The reasoning:
//
//   1. Spec section 4: `archive` after a terminal state REQUIRES the terminal outbox
//      acknowledgement AND cleanup completion for the current generation. There is no
//      "historical import" bypass of those prerequisites anywhere in the spec.
//   2. Spec section 14 hard-excludes "History synthesis".
//   3. Reaching `archived` legally would mean synthesizing spawned/running_verified
//      (launch-binding identity a task that never launched under the control plane cannot
//      satisfy - spec section 5.2), a firstmate consumer lease + claim-delivery + sink
//      effect + ack (consumer receipts and sink effects that never happened), and a cleanup
//      saga over a pane long gone. That fabricates live-path events - the exact anti-ghost
//      violation CW1 forbade ("no live binding is ever asserted for imported work"), and it
//      would reintroduce the raw domain insert/import seam QA qa-cw1r4-q85 confirmed CW1
//      does NOT have.
//
// So, per the task's explicit fallback ("if genuine synthesis is forbidden, implement the
// back-fill as a distinct historical-record representation the snapshot layer can carry
// without faking live-path events"), the archived-history residual lands in a DISTINCT
// audit-only table (lib/cw2-archived-history.mjs). Each row is a faithful, losslessly
// recoverable pointer to its legacy source (source_ref, digest, the CW1 would-be canonical
// mapping, the raw source, and the CW1 deferral reason). No task, run, event, outbox, or
// consumer row is written; the live control plane is not touched. archived_history is an
// ordinary deterministic store table a later CW3 snapshot revision can fold in - the
// snapshot layer CAN carry it - which this stage intentionally does NOT wire into the
// byte-frozen S6 snapshot.
//
// READ-ONLY LEGACY DISCIPLINE. Like migrate-apply, the INPUT is the retained CW1 residual
// FILE, never a legacy store. This verb never opens or reads the legacy home; the legacy
// stores stay untouched by construction.
//
// IDEMPOTENT. record_key (the CW1 recordKey: sha256(source_ref + source.digest)) is the
// archived_history PRIMARY KEY with ON CONFLICT DO NOTHING, so re-running is safe and
// reports imported_new vs imported_replayed honestly.

export const BACKFILL_RESIDUAL_SCHEMA = 'control-plane/migrate-backfill/residual/v1';

export const BACKFILL_DECISION =
  'Genuine live-path synthesis of the terminal-delivery/ack/cleanup/archive chain is FORBIDDEN '
  + '(spec section 4 requires real ack + cleanup prerequisites; section 14 excludes History synthesis; '
  + 'faking spawned/running_verified/consumer-ack/sink/cleanup rows would assert launch identity, consumer '
  + 'receipts, and sink effects that never happened - the CW1 anti-ghost rule). The archived-history residual '
  + 'is imported as AUDIT-ONLY records in a distinct archived_history table the snapshot layer can carry, with '
  + 'no live-path (task/run/event/outbox/consumer) writes.';

// The CW1 residual deferral reasons that mark a record as archived history to back-fill.
// This predicate is the authoritative, documented scope of the back-fill; QA adjudicates it.
// The "migrated in-flight backlog task ... retained for CW2 re-dispatch/back-fill" reason is
// deliberately EXCLUDED - that is live work retained for re-dispatch (a later cutover
// concern), not archived history.
const CLASS_PREDICATES = [
  { cls: 'done_archive', match: 'archived/finished task with no live-backlog membership' },
  { cls: 'multi_gen', match: 'historical/additional run generation superseded' },
  { cls: 'archive_event', match: 'task-scope archived event needs the acked-terminal' }
];

export function classifyRecordClass(reason) {
  if (typeof reason !== 'string') return null;
  for (const { cls, match } of CLASS_PREDICATES) {
    if (reason.includes(match)) return cls;
  }
  return null;
}

// ---------------------------------------------------------------------------------
// Residual load + validation
// ---------------------------------------------------------------------------------

export function loadResidual(residualPath) {
  if (typeof residualPath !== 'string' || residualPath.length === 0) {
    throw new BackfillError('migrate-backfill requires --residual <cw1-residual-path>', { residual: residualPath ?? null });
  }
  let text;
  try {
    text = nodeFs.readFileSync(residualPath, 'utf8');
  } catch (err) {
    throw new BackfillError('--residual could not be read', { residual: residualPath, cause: err.message });
  }
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    throw new BackfillError('--residual is not valid JSON', { residual: residualPath });
  }
  if (!doc || doc.schema !== CW1_RESIDUAL_SCHEMA) {
    throw new BackfillError(`--residual is not a ${CW1_RESIDUAL_SCHEMA} document`, {
      residual: residualPath, schema: doc && doc.schema ? doc.schema : null
    });
  }
  if (!Array.isArray(doc.residual)) {
    throw new BackfillError('--residual is missing its residual[] array', { residual: residualPath });
  }
  return doc;
}

// ---------------------------------------------------------------------------------
// Extraction (pure)
// ---------------------------------------------------------------------------------

function canonicalRows(rec) {
  return Array.isArray(rec.canonical) ? rec.canonical : [];
}

function extractTaskId(rec) {
  for (const row of canonicalRows(rec)) {
    if (row && row.fields && typeof row.fields.task_id === 'string' && row.fields.task_id.length > 0) {
      return row.fields.task_id;
    }
  }
  return null;
}

function extractRunGeneration(rec) {
  for (const row of canonicalRows(rec)) {
    if (row && row.table === 'runs' && row.fields && Number.isInteger(row.fields.run_generation)) {
      return row.fields.run_generation;
    }
  }
  for (const row of canonicalRows(rec)) {
    if (row && row.fields && Number.isInteger(row.fields.run_generation)) return row.fields.run_generation;
  }
  return null;
}

// Best-effort terminal outcome, NEVER guessed beyond explicit signal: an explicit terminal
// event_type in the canonical mapping, or an explicit closed/archived marker in the raw
// source. Absent an explicit signal it is null (the full source is retained regardless, so
// nothing is lost).
function extractTerminalOutcome(rec) {
  for (const row of canonicalRows(rec)) {
    if (row && row.fields && typeof row.fields.event_type === 'string') {
      const et = row.fields.event_type;
      if (et === 'completed' || et === 'failed' || et === 'archived') return et;
    }
  }
  const v = rec.source && typeof rec.source.value === 'object' ? rec.source.value : {};
  if (v.event === 'closed' || v.event === 'archived') return 'archived';
  return null;
}

function extractArchivedAt(rec) {
  const v = rec.source && typeof rec.source.value === 'object' ? rec.source.value : {};
  if (typeof v.closed_at === 'string' && v.closed_at.length > 0) return v.closed_at;
  if (typeof v.ts === 'string' && v.ts.length > 0) return v.ts;
  return null;
}

// Build the archived_history entry from a matched residual record, or return { flagged } when
// no task identity can be recovered (totality still holds: matched === imported + flagged).
export function buildHistoryEntry(rec, cls) {
  const taskId = extractTaskId(rec);
  if (!taskId) {
    return { flagged: { source_ref: rec.source_ref, reason: 'archived-history record carries no recoverable task_id' } };
  }
  if (!rec.source || typeof rec.source.digest !== 'string') {
    return { flagged: { source_ref: rec.source_ref, reason: 'archived-history record has no source digest for a stable record_key' } };
  }
  return {
    entry: {
      record_key: recordKey(rec),
      task_id: taskId,
      record_class: cls,
      terminal_outcome: extractTerminalOutcome(rec),
      run_generation: extractRunGeneration(rec),
      source_ref: rec.source_ref,
      source_store: typeof rec.store === 'string' ? rec.store : null,
      source_digest: rec.source.digest,
      archived_at: extractArchivedAt(rec),
      canonical: rec.canonical ?? null,
      source: rec.source ?? null,
      reason: rec.reason
    }
  };
}

// ---------------------------------------------------------------------------------
// Out containment
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

function resolveContainedOut(outPath, dataDir, legacyHome) {
  const outAbs = path.resolve(outPath);
  const resolvedDir = realDirOf(path.dirname(outAbs));
  const resolvedOut = path.join(resolvedDir, path.basename(outAbs));
  const roots = [['store data-dir', realOf(dataDir)]];
  if (typeof legacyHome === 'string' && legacyHome.length > 0) roots.push(['legacy home', realOf(legacyHome)]);
  for (const [label, root] of roots) {
    if (isAtOrUnder(root, resolvedDir) || isAtOrUnder(root, resolvedOut)) {
      throw new BackfillError(`--out resolves under the ${label} (symlink or path traversal); refused`, {
        out: resolvedOut, resolved_dir: resolvedDir, root
      });
    }
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

function fixedNow() {
  return '1970-01-01T00:00:00.000Z';
}

// ---------------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------------

export async function runMigrateBackfill({ residualPath, dataDir, outPath, resume = false, env = process.env } = {}) {
  if (typeof dataDir !== 'string' || dataDir.length === 0) {
    throw new BackfillError('migrate-backfill requires --data-dir <control-plane store path>', { data_dir: dataDir ?? null });
  }
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new BackfillError('migrate-backfill requires --out <backfill-residual-path>', { out: outPath ?? null });
  }
  const doc = loadResidual(residualPath);
  const legacyHome = typeof doc.legacy_home === 'string' ? doc.legacy_home : undefined;
  const resolvedOut = resolveContainedOut(outPath, dataDir, legacyHome);

  // Classify and extract (pure). Totality population is the set of residual records that
  // match the archived-history predicate; everything else is out of this stage's scope.
  const matched = [];
  for (const rec of doc.residual) {
    const cls = classifyRecordClass(rec && rec.reason);
    if (cls) matched.push({ rec, cls });
  }
  const entries = [];
  const flagged = [];
  const byClass = { done_archive: 0, multi_gen: 0, archive_event: 0 };
  for (const { rec, cls } of matched) {
    const built = buildHistoryEntry(rec, cls);
    if (built.flagged) {
      flagged.push(built.flagged);
    } else {
      entries.push(built.entry);
      byClass[cls] += 1;
    }
  }

  const now = fixedNow();
  const store = PgliteLocalStore.create({ dataDir, env });
  let writeResult;
  let storeCount;
  try {
    // Dirty-target note: archived_history is idempotent by record_key, so re-running is
    // always safe; --resume is accepted for symmetry with migrate-apply and to make an
    // intentional re-run explicit. The write is a no-op for already-present keys.
    writeResult = await writeArchivedHistory(store, entries, { now });
    storeCount = await countArchivedHistory(store);
  } finally {
    await store.close();
  }

  const importedKeys = new Set(entries.map((e) => e.record_key));
  const imported = entries.length;
  const importedNew = writeResult.newKeys.length;
  const importedReplayed = writeResult.replayedKeys.length;

  const totalityHolds = imported + flagged.length === matched.length;
  const countsCoherent = storeCount >= importedKeys.size
    && importedNew + importedReplayed === entries.length;
  const importedNonzero = matched.length === 0 || imported > 0;
  const ok = totalityHolds && countsCoherent && importedNonzero;

  const reconciliation = {
    matched: matched.length,
    imported,
    imported_new: importedNew,
    imported_replayed: importedReplayed,
    flagged: flagged.length,
    by_class: byClass,
    store_archived_history_count: storeCount,
    imported_distinct_keys: importedKeys.size,
    totality_holds: totalityHolds,
    counts_coherent: countsCoherent,
    imported_nonzero: importedNonzero,
    ok
  };

  const report = {
    schema: BACKFILL_RESIDUAL_SCHEMA,
    posture: 'audit-only archived-history import; live-path terminal/ack/cleanup/archive synthesis forbidden (see decision); legacy stores untouched (input is the CW1 residual file)',
    decision: BACKFILL_DECISION,
    source_residual: path.resolve(residualPath),
    source_residual_schema: CW1_RESIDUAL_SCHEMA,
    data_dir: dataDir,
    resumed: resume === true,
    totals: {
      residual_scanned: doc.residual.length,
      archived_history_matched: matched.length,
      imported,
      imported_new: importedNew,
      imported_replayed: importedReplayed,
      flagged: flagged.length,
      by_class: byClass
    },
    reconciliation,
    imported: entries.map((e) => ({
      task_id: e.task_id,
      record_class: e.record_class,
      record_key: e.record_key,
      terminal_outcome: e.terminal_outcome,
      run_generation: e.run_generation,
      source_ref: e.source_ref,
      archived_at: e.archived_at
    })),
    flagged
  };

  atomicWriteOwnerOnly(resolvedOut, `${JSON.stringify(report, null, 2)}\n`);

  if (!totalityHolds || !countsCoherent) {
    throw new BackfillReconcileError('migrate-backfill reconciliation failed (totality or store counts do not reconcile); residual report written for audit', {
      out: resolvedOut, reconciliation
    });
  }

  return {
    out: resolvedOut,
    data_dir: dataDir,
    totals: report.totals,
    reconciliation,
    ok
  };
}
