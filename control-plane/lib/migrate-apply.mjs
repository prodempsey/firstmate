import nodeFs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { runExclusive } from './internal-runtime.mjs';
import { createTask } from './domain-store.mjs';
import { createSnapshot } from './domain-store-s6.mjs';
import { REPORT_SCHEMA } from './migrate-report.mjs';
import { MigrateApplyError, MigrateReconcileError } from './errors-cw1.mjs';

// `cp migrate-apply --report <s8-report> --data-dir <store> --out <residual>` (CUTOVER
// stage CW1). The MIGRATION EXECUTOR: it turns the S8 migrate-report's `mapped` proposals
// into real control-plane records and echoes everything it does NOT apply to a residual
// report for firstmate/captain disposition. It never guesses.
//
// Disciplines (all enforced here, all proven by test/cw1-migrate-apply.test.mjs):
//
//  1. VERB-ONLY WRITES. Every control-plane write goes through the landed domain
//     command envelope (`createTask` -> executeCommand; `createSnapshot`). This module
//     issues NO raw SQL against a domain table - its only direct DB access is the
//     locked READ seam (runExclusive) used for the prior-migration probe and the
//     post-apply count verification. The repo-wide owner guard
//     (scripts/check-no-direct-pglite.mjs) forbids any bypass of the PGlite engine, and
//     a create-task that did not commit a command_results row would leave no idempotency
//     record - so a raw-insert bypass is both statically forbidden and would fail the
//     built-in verb-trace check.
//
//  2. LEGACY READ-ONLY BY CONSTRUCTION. The INPUT is the S8 report FILE, already the
//     product of S8's read-only shadow read. migrate-apply opens no legacy store at all,
//     so the legacy stores cannot be mutated by this verb - there is no code path that
//     writes, or even reads, a legacy path.
//
//  3. ONLY `mapped` PROPOSALS ARE APPLIED, and only where the landed verb chain can
//     LEGALLY reach the proposed state. In CW1 the legally-reachable migration is task
//     creation: `create-task` deterministically reaches `queued`. A legacy record whose
//     canonical target is a live/terminal RUN state (a `runs` row, or a run-scoped
//     `task_events` row) cannot be reached without a live endpoint (begin-run ->
//     record-spawn probes a real pane); forcing a synthetic live launch onto historical
//     data would be exactly the "force" the charter forbids. So those records are FLAGGED
//     to the residual report rather than forced. Likewise a task whose legacy status is a
//     non-queued live/terminal state, or whose identity cannot be assembled without
//     guessing (no kind, no title, no captain-order origin link), is FLAGGED. The
//     eventual richer run/terminal migration is a later cutover concern; CW1 applies the
//     honest, safe subset and accounts for the rest.
//
//  4. IDEMPOTENT RESUME. Every applied task is created under a command-id derived from
//     its canonical identity (`migrate-apply:create-task:<task_id>`), so a reapplication
//     is a no-op that returns the stored result (the landed command_results idempotency
//     machinery). The verb REFUSES a target that already holds applied migration state
//     unless --resume is given, in which case it continues idempotently - a real
//     child-crash mid-apply leaves the already-committed tasks durable and --resume
//     replays them and finishes the rest.
//
//  5. BUILT-IN RECONCILIATION. After apply it proves: applied + residual === report's
//     mapped + flagged (totality); the store's task/run/event counts match the applied
//     proposals; and a post-apply `cp snapshot` succeeds. Any failure raises
//     MigrateReconcileError AFTER writing the residual/verification report for audit.

export const RESIDUAL_SCHEMA = 'control-plane/migrate-apply/residual/v1';

// command_results marker prefix for every write this verb makes. The prior-migration
// probe and --resume gate key on it, so a target that has seen a partial apply is
// detected without any new schema (the landed command_results table IS the ledger).
const MIGRATE_CMD_PREFIX = 'migrate-apply';

const VALID_KINDS = new Set(['ship', 'scout', 'secondmate']);

// ---------------------------------------------------------------------------------
// Report load + validation
// ---------------------------------------------------------------------------------

// Read, parse, and validate the S8 report. A malformed, wrong-schema, or
// non-reconciling report is refused BEFORE any store work - an executor that applied a
// report whose own totals do not add up could never produce a trustworthy
// reconciliation, so the report's independently-enforced totality (S8) is a
// precondition here, not a suggestion.
export function loadReport(reportPath) {
  if (typeof reportPath !== 'string' || reportPath.length === 0) {
    throw new MigrateApplyError('migrate-apply requires --report <s8-report-path>', { report: reportPath ?? null });
  }
  let text;
  try {
    text = nodeFs.readFileSync(reportPath, 'utf8');
  } catch (err) {
    throw new MigrateApplyError('--report could not be read', { report: reportPath, cause: err.message });
  }
  let report;
  try {
    report = JSON.parse(text);
  } catch {
    throw new MigrateApplyError('--report is not valid JSON', { report: reportPath });
  }
  if (!report || report.schema !== REPORT_SCHEMA) {
    throw new MigrateApplyError(`--report is not a ${REPORT_SCHEMA} document`, {
      report: reportPath, schema: report && report.schema ? report.schema : null
    });
  }
  if (!Array.isArray(report.records) || !report.totals || typeof report.totals !== 'object') {
    throw new MigrateApplyError('--report is missing records[] or totals{}', { report: reportPath });
  }
  const { mapped, flagged, discovered } = report.totals;
  if (![mapped, flagged, discovered].every((n) => Number.isInteger(n) && n >= 0)) {
    throw new MigrateApplyError('--report totals are not non-negative integers', { report: reportPath, totals: report.totals });
  }
  if (report.records.length !== discovered || mapped + flagged !== discovered) {
    throw new MigrateApplyError('--report does not reconcile (records.length / mapped + flagged != discovered); refusing to apply', {
      report: reportPath, records: report.records.length, totals: report.totals
    });
  }
  if (report.totals.reconciles !== true) {
    throw new MigrateApplyError('--report.totals.reconciles is not true; refusing to apply a non-reconciling report', { report: reportPath });
  }
  // Every disposition must carry the shape S8 guarantees; a corrupted record is refused
  // rather than silently skipped (that would break totality).
  for (const d of report.records) {
    if (!d || typeof d.source_ref !== 'string' || (d.disposition !== 'mapped' && d.disposition !== 'flagged')) {
      throw new MigrateApplyError('--report has a malformed disposition record', { report: reportPath, record: d ?? null });
    }
    if (d.disposition === 'mapped' && (!d.mapping || !Array.isArray(d.mapping.canonical) || d.mapping.canonical.length < 1)) {
      throw new MigrateApplyError('--report has a mapped record with no canonical rows', { report: reportPath, source_ref: d.source_ref });
    }
    if (d.disposition === 'flagged' && (!d.flag || typeof d.flag.reason !== 'string')) {
      throw new MigrateApplyError('--report has a flagged record with no flag reason', { report: reportPath, source_ref: d.source_ref });
    }
  }
  return report;
}

// ---------------------------------------------------------------------------------
// Planning (pure): assemble task identity by joining proposals, then disposition each
// mapped record into apply-or-flag. No fs, no db, no clock - deterministic.
// ---------------------------------------------------------------------------------

function firstOf(set) {
  for (const v of set) return v;
  return undefined;
}

// Fold every `tasks` canonical row across ALL mapped records into a per-task_id
// assembly. A single legacy record only ever gives PART of a task (meta -> kind; a
// backlog bullet -> title + queued status; an order -> the captain-order link), so a
// legal create-task must JOIN them. Conflicting values (two kinds, two titles) make the
// task ineligible rather than picking one - that would be guessing.
export function assembleTasks(report) {
  const assembly = new Map();
  for (const d of report.records) {
    if (d.disposition !== 'mapped') continue;
    for (const row of d.mapping.canonical) {
      if (row.table !== 'tasks') continue;
      const taskId = row.fields && row.fields.task_id;
      if (typeof taskId !== 'string' || taskId.length === 0) continue;
      let a = assembly.get(taskId);
      if (!a) {
        a = { taskId, kinds: new Set(), titles: new Set(), repos: new Set(), orderRefs: new Set(), statuses: new Set(), sourceRefs: [] };
        assembly.set(taskId, a);
      }
      const f = row.fields;
      if (typeof f.kind === 'string' && f.kind.length > 0) a.kinds.add(f.kind);
      if (typeof f.title === 'string' && f.title.length > 0) a.titles.add(f.title);
      if (typeof f.repo === 'string' && f.repo.length > 0) a.repos.add(f.repo);
      if (typeof f.order_ref === 'string' && f.order_ref.length > 0) a.orderRefs.add(f.order_ref);
      if (typeof f.status === 'string' && f.status.length > 0) a.statuses.add(f.status);
      a.sourceRefs.push(d.source_ref);
    }
  }
  for (const a of assembly.values()) finalizeEligibility(a);
  return assembly;
}

// An assembled task is APPLICABLE in CW1 iff create-task can LEGALLY create it as a
// `queued` task without guessing any required field:
//   - exactly one valid kind (from state-meta),
//   - exactly one title (from a backlog/done-archive bullet),
//   - a confirmed 'queued' status (a backlog Queued bullet); ANY non-queued status, or a
//     wholly-unresolved status, makes it ineligible (a live/terminal task cannot be
//     honestly created as queued, and an unknown status must not be guessed as queued),
//   - exactly one captain-order link (-> task_origin captain_order + order_ref); no link
//     means origin is unresolved and would have to be guessed.
function finalizeEligibility(a) {
  if (a.kinds.size === 0) { a.eligible = false; a.reason = 'kind unresolved (no state-meta record joins this task); create-task requires a checked kind'; return; }
  if (a.kinds.size > 1) { a.eligible = false; a.reason = `conflicting kinds ${[...a.kinds].join('/')}; refusing to guess`; return; }
  const kind = firstOf(a.kinds);
  if (!VALID_KINDS.has(kind)) { a.eligible = false; a.reason = `kind '${kind}' is not a valid task kind`; return; }

  if (a.titles.size === 0) { a.eligible = false; a.reason = 'title unresolved (no backlog/done-archive bullet joins this task)'; return; }
  if (a.titles.size > 1) { a.eligible = false; a.reason = 'conflicting titles across sources; refusing to guess'; return; }

  if (a.statuses.size === 0) { a.eligible = false; a.reason = 'status unresolved; cannot confirm the legacy task is queued without guessing'; return; }
  const nonQueued = [...a.statuses].filter((s) => s !== 'queued');
  if (nonQueued.length > 0) { a.eligible = false; a.reason = `legacy status '${nonQueued.join('/')}' is a live/terminal state the create-only migration path cannot reach; flagged rather than forced`; return; }

  if (a.orderRefs.size === 0) { a.eligible = false; a.reason = 'captain-order origin unresolved (no order event links this task); refusing to guess task_origin'; return; }
  if (a.orderRefs.size > 1) { a.eligible = false; a.reason = `conflicting order links ${[...a.orderRefs].join('/')}; refusing to guess`; return; }

  a.eligible = true;
  a.reason = null;
  a.kind = kind;
  a.title = firstOf(a.titles);
  a.repo = a.repos.size === 1 ? firstOf(a.repos) : undefined;
  a.orderRef = firstOf(a.orderRefs);
}

// The create-task params for an eligible task. Deterministic: same report -> same
// params -> same request_hash, so a rerun/replay is idempotent through the command
// envelope. captain_order origin is the only origin CW1 ever writes (no internal-reason
// is ever synthesized - that would be guessing).
export function createTaskParamsFor(a) {
  return {
    taskId: a.taskId,
    kind: a.kind,
    title: a.title,
    repo: a.repo,
    origin: 'captain_order',
    orderRef: a.orderRef,
    commandId: `${MIGRATE_CMD_PREFIX}:create-task:${a.taskId}`
  };
}

function unreachableReason(rows) {
  if (rows.some((r) => r.table === 'runs')) {
    return 'legacy run maps to a live/terminal run state the verb chain cannot reach without a live endpoint (begin-run -> record-spawn probes a real pane); flagged rather than forced';
  }
  if (rows.some((r) => r.table === 'task_events')) {
    return 'legacy event maps to a run/lifecycle event that requires an open run generation or a terminal path the create-only migration cannot legally reach; flagged';
  }
  return 'no applicable canonical rows for the CW1 create-only migration path';
}

// Disposition every MAPPED record into apply-or-flag. A record is applicable iff ALL of
// its canonical rows are `tasks` rows for an eligible task; any record that also carries
// a run or run-scoped event is flagged (its run cannot be reached), even though its
// task-field contributions were still folded into the assembly above.
export function planApply(report, assembly = assembleTasks(report)) {
  const apply = [];
  const flag = [];
  for (const d of report.records) {
    if (d.disposition !== 'mapped') continue;
    const rows = d.mapping.canonical;
    const tasksOnly = rows.length > 0 && rows.every((r) => r.table === 'tasks');
    if (tasksOnly) {
      const taskId = rows[0].fields.task_id;
      const a = assembly.get(taskId);
      if (a && a.eligible) {
        apply.push({ source_ref: d.source_ref, store: d.store, taskId, record: d });
      } else {
        flag.push({ source_ref: d.source_ref, store: d.store, reason: a ? a.reason : 'task not assemblable from the report', record: d });
      }
    } else {
      flag.push({ source_ref: d.source_ref, store: d.store, reason: unreachableReason(rows), record: d });
    }
  }
  return { assembly, apply, flag };
}

// ---------------------------------------------------------------------------------
// Store probes (locked READ seam only - never a domain write)
// ---------------------------------------------------------------------------------

async function tableExists(conn, name) {
  const r = await conn.query(
    "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
    [name]
  );
  return r.rows.length > 0;
}

// Probe the target for existing applied-migration state and for initialization. Pure
// read (runExclusive). A target with no coordinator_state has not been `cp init`ed; a
// target whose command_results holds any `migrate-apply:%` row already carries applied
// migration state.
async function probeTarget(store) {
  return runExclusive(store, async (conn) => {
    const initialized = await tableExists(conn, 'coordinator_state');
    if (!initialized) return { initialized: false, priorMigrationCount: 0 };
    let priorMigrationCount = 0;
    if (await tableExists(conn, 'command_results')) {
      const r = await conn.query(
        "SELECT count(*)::int AS n FROM command_results WHERE command_id LIKE $1",
        [`${MIGRATE_CMD_PREFIX}:%`]
      );
      priorMigrationCount = Number(r.rows[0].n);
    }
    return { initialized: true, priorMigrationCount };
  });
}

// Post-apply domain counts (pure read). Absent tables read as 0 (a store that saw no
// applied task never got the domain schema).
async function domainCounts(store) {
  return runExclusive(store, async (conn) => {
    const counts = { tasks: 0, runs: 0, task_events: 0, created_events: 0 };
    if (await tableExists(conn, 'tasks')) {
      counts.tasks = Number((await conn.query('SELECT count(*)::int AS n FROM tasks')).rows[0].n);
    }
    if (await tableExists(conn, 'runs')) {
      counts.runs = Number((await conn.query('SELECT count(*)::int AS n FROM runs')).rows[0].n);
    }
    if (await tableExists(conn, 'task_events')) {
      counts.task_events = Number((await conn.query('SELECT count(*)::int AS n FROM task_events')).rows[0].n);
      counts.created_events = Number(
        (await conn.query("SELECT count(*)::int AS n FROM task_events WHERE event_type = 'created'")).rows[0].n
      );
    }
    return counts;
  });
}

// Prove every applied task carries a matching command_results row keyed with our
// migration prefix - the verb-trace check. A domain row without a command result would
// mean a write bypassed the command envelope; there is no code path that does so, and
// this asserts it on real data.
async function verbTrace(store, taskIds) {
  return runExclusive(store, async (conn) => {
    if (taskIds.length === 0 || !(await tableExists(conn, 'command_results'))) {
      return { traced: 0, untraced: [] };
    }
    const untraced = [];
    for (const t of taskIds) {
      const r = await conn.query(
        'SELECT 1 FROM command_results WHERE command_id = $1',
        [`${MIGRATE_CMD_PREFIX}:create-task:${t}`]
      );
      if (r.rows.length === 0) untraced.push(t);
    }
    return { traced: taskIds.length - untraced.length, untraced };
  });
}

// ---------------------------------------------------------------------------------
// Atomic, owner-only, symlink-safe write of the residual/verification report
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

// Resolve --out to its real destination and REFUSE any target that resolves at or under
// the control-plane store directory: the residual report is an operator artifact and
// must never be written inside pgdata (a symlinked ancestor cannot smuggle it there).
function resolveContainedOut(outPath, dataDir) {
  const outAbs = path.resolve(outPath);
  const resolvedDir = realDirOf(path.dirname(outAbs));
  const resolvedOut = path.join(resolvedDir, path.basename(outAbs));
  const realStore = nodeFs.existsSync(dataDir) ? nodeFs.realpathSync(dataDir) : path.resolve(dataDir);
  if (isAtOrUnder(realStore, resolvedDir) || isAtOrUnder(realStore, resolvedOut)) {
    throw new MigrateApplyError('--out resolves under the target store directory (symlink or traversal); refused', {
      out: resolvedOut, resolved_dir: resolvedDir, data_dir: realStore
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

// A temporary empty captain-order source for the built-in verification snapshot. The
// verification snapshot is a smoke proof that projection still succeeds over the
// just-migrated domain, NOT the production snapshot; a real run passes --order-source.
function tempEmptyOrderSource() {
  const dir = nodeFs.mkdtempSync(path.join(os.tmpdir(), 'cp-cw1-snap-'));
  const p = path.join(dir, 'captain-orders.jsonl');
  nodeFs.writeFileSync(p, '');
  return { path: p, dir };
}

// ---------------------------------------------------------------------------------
// The executor
// ---------------------------------------------------------------------------------

// Build the residual/verification report body (deterministic given inputs; the caller
// stamps nothing time-varying into it).
function buildResidualReport({ report, reportPath, dataDir, resumed, appliedRecords, residual, reconciliation }) {
  const appliedTaskIds = [...new Set(appliedRecords.map((r) => r.task_id))].sort();
  return {
    schema: RESIDUAL_SCHEMA,
    posture: 'applied mapped proposals via cp verbs only; legacy stores untouched (input is the S8 report file)',
    source_report: reportPath,
    source_report_schema: report.schema,
    data_dir: dataDir,
    resumed,
    totals: {
      report_mapped: report.totals.mapped,
      report_flagged: report.totals.flagged,
      applied: appliedRecords.length,
      residual: residual.length,
      echoed_flagged: residual.filter((r) => r.origin === 'report').length,
      executor_flagged: residual.filter((r) => r.origin === 'executor').length,
      applied_tasks: appliedTaskIds.length
    },
    reconciliation,
    applied: appliedRecords,
    applied_task_ids: appliedTaskIds,
    residual
  };
}

// runMigrateApply: load the report, plan, drive create-task for every legally-applicable
// record (idempotent by command-id), echo everything else to the residual report, then
// reconcile and write the residual/verification report. `hooks.afterApply(n)` is a
// test-only seam for injecting a real crash mid-apply.
export async function runMigrateApply({
  reportPath, dataDir, outPath, resume = false, orderSourcePath, env = process.env, hooks = {}
} = {}) {
  if (typeof dataDir !== 'string' || dataDir.length === 0) {
    throw new MigrateApplyError('migrate-apply requires --data-dir <control-plane store path>', { data_dir: dataDir ?? null });
  }
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new MigrateApplyError('migrate-apply requires --out <residual-report-path>', { out: outPath ?? null });
  }
  const report = loadReport(reportPath);
  const resolvedOut = resolveContainedOut(outPath, dataDir);
  const plan = planApply(report);

  const store = PgliteLocalStore.create({ dataDir, env });
  let snapTmp;
  try {
    // Prior-migration gate.
    const probe = await probeTarget(store);
    if (!probe.initialized) {
      throw new MigrateApplyError('target store is not initialized; run `cp init --data-dir <path>` first', { data_dir: dataDir });
    }
    if (probe.priorMigrationCount > 0 && !resume) {
      throw new MigrateApplyError('target already holds applied migration state; pass --resume to continue idempotently', {
        data_dir: dataDir, prior_migration_commands: probe.priorMigrationCount
      });
    }

    // Apply. Each create-task is its own committed transaction, so a mid-loop crash
    // leaves earlier tasks durable; a rerun with --resume replays them idempotently.
    const appliedRecords = [];
    const executorFlagged = [];
    for (const item of plan.apply) {
      const params = createTaskParamsFor(plan.assembly.get(item.taskId));
      try {
        await createTask(store, params); // idempotent by command-id; replay on --resume is a no-op
        appliedRecords.push({ source_ref: item.source_ref, store: item.store, task_id: item.taskId, command_id: params.commandId });
        if (typeof hooks.afterApply === 'function') await hooks.afterApply(appliedRecords.length);
      } catch (err) {
        // An apply that fails (e.g. a dirty target where the id already exists under a
        // foreign command) is not forced - it drops to residual so totality still holds.
        executorFlagged.push({
          source_ref: item.source_ref, store: item.store, origin: 'executor',
          reason: `apply failed: ${err.message}`, canonical: item.record.mapping.canonical, source: item.record.source ?? null
        });
      }
    }
    for (const item of plan.flag) {
      executorFlagged.push({
        source_ref: item.source_ref, store: item.store, origin: 'executor',
        reason: item.reason, canonical: item.record.mapping.canonical, source: item.record.source ?? null
      });
    }

    // Echo the report's own flagged records straight through - never guessed at.
    const echoedFlagged = report.records
      .filter((d) => d.disposition === 'flagged')
      .map((d) => ({
        source_ref: d.source_ref, store: d.store, origin: 'report',
        reason: `${d.flag.reason}: ${d.flag.detail ?? ''}`.trim(), flag: d.flag, source: d.source ?? null
      }));
    const residual = [...echoedFlagged, ...executorFlagged];

    // Reconciliation.
    const appliedTaskIds = [...new Set(appliedRecords.map((r) => r.task_id))];
    const expected = { tasks: appliedTaskIds.length, runs: 0, task_events: appliedTaskIds.length };
    const counts = await domainCounts(store);
    const trace = await verbTrace(store, appliedTaskIds);

    let snapshotOk = false;
    let snapshotRevision = null;
    let snapshotError = null;
    try {
      let sourceForSnap = orderSourcePath;
      if (typeof sourceForSnap !== 'string' || sourceForSnap.length === 0) {
        snapTmp = tempEmptyOrderSource();
        sourceForSnap = snapTmp.path;
      }
      // A snapshot is a PROJECTION, not a domain command: it writes no command_results
      // row, so it never perturbs the prior-migration probe. Its idempotency is the
      // natural content dedup, so no command-id is passed.
      const snap = await createSnapshot(store, { orderSourcePath: sourceForSnap });
      snapshotOk = true;
      snapshotRevision = snap && Number.isInteger(snap.projection_revision) ? snap.projection_revision : null;
    } catch (err) {
      snapshotError = err.message;
    }

    const totalityHolds = appliedRecords.length + residual.length === report.totals.mapped + report.totals.flagged;
    const countsMatch =
      counts.tasks === expected.tasks &&
      counts.runs === expected.runs &&
      counts.task_events === expected.task_events &&
      counts.created_events === expected.task_events;
    const verbOnly = trace.untraced.length === 0;

    const reconciliation = {
      totality_holds: totalityHolds,
      applied_plus_residual: appliedRecords.length + residual.length,
      report_mapped_plus_flagged: report.totals.mapped + report.totals.flagged,
      store_counts: { tasks: counts.tasks, runs: counts.runs, task_events: counts.task_events },
      expected_counts: expected,
      counts_match: countsMatch,
      verb_only_writes: verbOnly,
      untraced_tasks: trace.untraced,
      snapshot_ok: snapshotOk,
      snapshot_revision: snapshotRevision,
      snapshot_error: snapshotError,
      ok: totalityHolds && countsMatch && verbOnly && snapshotOk
    };

    // Write the residual/verification report ALWAYS (audit), then fail loudly if the
    // reconciliation did not hold.
    const body = buildResidualReport({ report, reportPath, dataDir, resumed: resume, appliedRecords, residual, reconciliation });
    const content = `${JSON.stringify(body, null, 2)}\n`;
    atomicWriteOwnerOnly(resolvedOut, content);

    if (!reconciliation.ok) {
      throw new MigrateReconcileError('migrate-apply reconciliation failed; see the residual/verification report', {
        out: resolvedOut, reconciliation
      });
    }

    return {
      out: resolvedOut,
      data_dir: dataDir,
      source_report: reportPath,
      resumed: resume,
      applied: appliedRecords.length,
      applied_tasks: appliedTaskIds.length,
      residual: residual.length,
      report_mapped: report.totals.mapped,
      report_flagged: report.totals.flagged,
      reconciliation,
      bytes: Buffer.byteLength(content)
    };
  } finally {
    if (snapTmp) {
      try { nodeFs.rmSync(snapTmp.dir, { recursive: true, force: true }); } catch { /* best effort */ }
    }
    await store.close();
  }
}
