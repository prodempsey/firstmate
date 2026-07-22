import nodeFs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { createTask, beginRun, appendEvent } from './domain-store.mjs';
import { recordSpawn, commitRunning } from './domain-store-s3.mjs';
import { completeRun, failRun } from './domain-store-s2.mjs';
import { createSnapshot } from './domain-store-s6.mjs';
import { readOnlyQuery } from './cw1-readonly.mjs';
import { loadReceipts, writeReceipts } from './cw1-ledger.mjs';
import { REPORT_SCHEMA } from './migrate-report.mjs';
import { MigrateApplyError, MigrateReconcileError } from './errors-cw1.mjs';

// `cp migrate-apply --report <s8-report> --data-dir <store> --out <residual>` (CUTOVER
// stage CW1). The MIGRATION EXECUTOR drives the landed cp verb chain to materialize the
// S8 report's mapped proposals, and echoes to a residual report only what it cannot
// legally reach - honestly, with committed-state verification.
//
// Design, and the round-2 QA (qa-cw1r2-q83) corrections it encodes:
//
//  * CURRENT STATE, NOT HISTORY (finding 2 / ruling Q2). A task lands at its ACTUAL current
//    state. LIVE backlog membership (store=backlog In flight/Queued/Done) is authoritative and
//    WINS over any done-archive source for the same task_id, so a task that has RETURNED to the
//    active backlog is current and its historical archive rows fall through to superseded
//    residuals. Events order by a NUMERIC ordinal (the `#L<n>` line number, or a lifecycle
//    timestamp), never by a lexical source_ref, so `#L10` no longer sorts before `#L2`. A
//    completeness GATE (same class as totality/ceiling) fails the run if any live In flight /
//    Queued backlog task ends fully residual.
//
//  * NO FABRICATED RUNS FOR CURRENT WORK (finding 4 / ruling Q1b). A migrated run has NO live
//    endpoint, so a currently in-flight task materializes as QUEUED with NO run row - the
//    was-in-flight/worktree fact rides the internalReason metadata channel, never a run.
//    Because a queued task is not a reconcile candidate (snapshotCandidates selects only
//    spawning/open/cleanup_pending), elapsed migration time can never terminal-fail imported
//    live work. Only a genuinely terminal (completed/failed) task materializes a run, and its
//    run ends CLOSED - no live binding is ever asserted for imported work.
//
//  * TRUTHFUL COUNTS (finding 1). Archive-shaped records prescribe an `archived` state
//    that needs an acked terminal delivery + finished cleanup saga (S4/S3 live path); CW1
//    does not simulate that consumer/cleanup lifecycle, so archived tasks are RESIDUALIZED
//    (never created and never falsely counted applied). A post-commit verification pass
//    then re-reads the committed store and downgrades ANY applied record whose prescribed
//    status is not actually present, so "applied" always reflects committed store state.
//
//  * PER-SOURCE RESUME IDENTITY (finding 3). Every mapped source record's decision is
//    persisted in a receipt ledger keyed by its own (source_ref, source.digest) - the
//    stable recordKey - INCLUDING subsumed/collapsed records. Resume classifies each
//    record new-or-replayed by its OWN key, so a changed source hash is honestly
//    reprocessed rather than falsely inheriting an owner command's replay status.
//
// DRIVE-AND-CATCH remains the safety spine: every write is a landed verb through the
// command envelope; a domain rejection flags that record with its reason and moves on, so
// the executor can neither corrupt the store nor force an illegal state.
//
// Retained round-1 hardening: --out realpath-contained against the store AND the report's
// legacy_home (finding 2 r1); a non-empty target rejected BEFORE any mutation unless
// --resume (finding 4 r1); reads only through the SELECT-only READ-ONLY-transaction seam
// (finding 5 r1). RECONCILIATION FAILS LOUDLY: applied + executor-flagged === mapped, and
// the run is rejected when applied is zero or the residual fraction of mapped exceeds
// --allow-residual-over (default DEFAULT_MAX_RESIDUAL_PCT).

export const RESIDUAL_SCHEMA = 'control-plane/migrate-apply/residual/v1';

const MIGRATE_CMD_PREFIX = 'migrate-apply';
const VALID_KINDS = new Set(['ship', 'scout', 'secondmate']);
// Run-scoped events that require a verified RUNNING task (a migrated in-flight task rests
// unverified, so these are honestly residualized for it). `progress` is legal on any open
// generation and is NOT in this set.
const NEEDS_RUNNING = new Set(['blocked', 'unblocked', 'waiting_firstmate', 'needs_human', 'rework']);
const APPENDABLE = new Set(['progress', 'blocked', 'unblocked', 'waiting_firstmate', 'needs_human', 'rework']);
const EVENT_PRODUCERS = new Set(['coordinator', 'adapter', 'crewmate', 'firstmate', 'reconciler']);

export const DEFAULT_MAX_RESIDUAL_PCT = 35;

// ---------------------------------------------------------------------------------
// Report load + validation
// ---------------------------------------------------------------------------------

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
  const seen = new Set();
  for (const d of report.records) {
    if (!d || typeof d.source_ref !== 'string' || (d.disposition !== 'mapped' && d.disposition !== 'flagged')) {
      throw new MigrateApplyError('--report has a malformed disposition record', { report: reportPath, record: d ?? null });
    }
    if (seen.has(d.source_ref)) {
      throw new MigrateApplyError('--report has a duplicate source_ref; a strict source-pointer bijection is required', {
        report: reportPath, source_ref: d.source_ref
      });
    }
    seen.add(d.source_ref);
    if (!d.source || typeof d.source.digest !== 'string' || d.source.digest.length === 0) {
      throw new MigrateApplyError('--report record is missing source.digest (the application identity)', {
        report: reportPath, source_ref: d.source_ref
      });
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

// Stable per-record application identity: sha(source_ref, source.digest).
export function recordKey(d) {
  return crypto.createHash('sha256').update(`${d.source_ref} ${d.source.digest}`).digest('hex');
}
function cmdId(verb, key) {
  return `${MIGRATE_CMD_PREFIX}:${verb}:${key}`;
}

// Numeric chronological ordinal of a record (finding 2): the source line number `#L<n>`,
// else a lifecycle timestamp, else 0. Never the lexical source_ref.
export function ordinalOf(d) {
  const m = /#L(\d+)/.exec(d.source_ref);
  if (m) return Number(m[1]);
  const v = d.source && typeof d.source.value === 'object' ? d.source.value : {};
  if (typeof v.ts === 'number') return v.ts;
  if (typeof v.ts === 'string') { const t = Date.parse(v.ts); if (!Number.isNaN(t)) return t; }
  return 0;
}

// ---------------------------------------------------------------------------------
// Assembly (pure)
// ---------------------------------------------------------------------------------

function harvestFromSource(d) {
  const v = (d.source && typeof d.source.value === 'object' && d.source.value) || {};
  const out = {};
  if (typeof v.kind === 'string' && VALID_KINDS.has(v.kind)) out.kind = v.kind;
  else if (typeof v.line === 'string') {
    const m = /\(kind:\s*([a-z]+)\)/.exec(v.line);
    if (m && VALID_KINDS.has(m[1])) out.kind = m[1];
  }
  if (typeof v.title === 'string' && v.title.length > 0) out.title = v.title;
  if (typeof v.project === 'string' && v.project.length > 0) out.repo = v.project.split('/').filter(Boolean).pop();
  if (typeof v.worktree === 'string' && v.worktree.length > 0) out.hasWorktree = true;
  return out;
}

function parseRecord(d) {
  const rows = d.mapping.canonical;
  const taskRow = rows.find((r) => r.table === 'tasks') || null;
  const runRow = rows.find((r) => r.table === 'runs') || null;
  const eventRow = rows.find((r) => r.table === 'task_events') || null;
  const anchor = taskRow || runRow || eventRow;
  const taskId = anchor && anchor.fields ? anchor.fields.task_id : null;
  const primary = runRow ? 'run' : eventRow ? 'event' : 'task';
  return { d, source_ref: d.source_ref, key: recordKey(d), taskId, taskRow, runRow, eventRow, primary, ordinal: ordinalOf(d) };
}

const firstSorted = (set) => [...set].sort()[0];

export function assembleTasks(report) {
  const tasks = new Map();
  for (const d of report.records) {
    if (d.disposition !== 'mapped') continue;
    const p = parseRecord(d);
    if (!p.taskId) continue;
    let t = tasks.get(p.taskId);
    if (!t) {
      t = {
        taskId: p.taskId, records: [], kinds: new Set(), titles: new Set(), repos: new Set(),
        orderRefs: new Set(), backlogStatuses: new Set(), liveBacklog: new Set(), hasArchivedBacklog: false,
        stores: new Set(), hasLiveMeta: false, hasWorktree: false,
        runRecords: [], eventRecords: [], taskRecords: []
      };
      tasks.set(p.taskId, t);
    }
    t.records.push(p);
    t.stores.add(d.store);
    if (d.store === 'state-meta') t.hasLiveMeta = true;
    if (p.taskRow) {
      const f = p.taskRow.fields;
      if (typeof f.kind === 'string' && f.kind.length > 0) t.kinds.add(f.kind);
      if (typeof f.title === 'string' && f.title.length > 0) t.titles.add(f.title);
      if (typeof f.repo === 'string' && f.repo.length > 0) t.repos.add(f.repo);
      if (typeof f.order_ref === 'string' && f.order_ref.length > 0) t.orderRefs.add(f.order_ref);
      if (typeof f.status === 'string' && f.status.length > 0) t.backlogStatuses.add(f.status);
    }
    // LIVE backlog membership is store=backlog ONLY (a task's presence on the current
    // In flight / Queued / Done backlog). A done-archive source is NOT live membership.
    if (d.store === 'backlog' && p.taskRow && typeof p.taskRow.fields.status === 'string') {
      const st = p.taskRow.fields.status;
      if (st === 'running' || st === 'queued' || st === 'completed') t.liveBacklog.add(st);
      else if (st === 'archived') t.hasArchivedBacklog = true;
    }
    const h = harvestFromSource(d);
    if (h.kind) t.kinds.add(h.kind);
    if (h.title) t.titles.add(h.title);
    if (h.repo) t.repos.add(h.repo);
    if (h.hasWorktree) t.hasWorktree = true;
    if (p.primary === 'run') t.runRecords.push(p);
    else if (p.primary === 'event') t.eventRecords.push(p);
    else t.taskRecords.push(p);
  }
  for (const t of tasks.values()) resolveIdentity(t);
  return tasks;
}

function resolveIdentity(t) {
  if (t.kinds.size === 1 && VALID_KINDS.has(firstSorted(t.kinds))) t.kind = firstSorted(t.kinds);
  else if (t.kinds.size === 0) { t.kind = null; t.kindReason = 'kind un-prescribed (no state-meta/lifecycle/ledger record supplies a kind; create-task kind is a checked enum and is not guessed)'; }
  else { t.kind = null; t.kindReason = `conflicting kinds ${[...t.kinds].sort().join('/')}; refusing to guess`; }
  t.title = t.titles.size >= 1 ? firstSorted(t.titles) : t.taskId;
  t.repo = t.repos.size === 1 ? firstSorted(t.repos) : undefined;
  if (t.orderRefs.size >= 1) { t.origin = 'captain_order'; t.orderRef = firstSorted(t.orderRefs); }
  else { t.origin = 'internal'; t.internalReason = 'migrated from legacy fleet state (no captain-order link recorded in the legacy stores)'; }
}

function createOwner(t) {
  const carriers = t.records.filter((p) => p.taskRow).sort((a, b) => (a.source_ref < b.source_ref ? -1 : 1));
  return carriers[0] || null;
}

// The status a run-scope event maps a task toward (used to read the LAST chronological signal).
const EVENT_TO_STATE = { progress: 'running', blocked: 'running', needs_human: 'running', unblocked: 'running', waiting_firstmate: 'running', rework: 'running', completed: 'completed', failed: 'failed' };

// Derive the task's ACTUAL CURRENT state (finding 2). The backlog section (or a
// done-archive record) is authoritative; absent that, the LAST chronological run-scope
// status line; absent that, the last run's outcome; a bare live meta is in-flight.
export function deriveCurrentState(t) {
  // F2 (ruling Q2): LIVE backlog membership (store=backlog In flight/Queued/Done) WINS over
  // any done-archive/archived source for the same task_id. A task that has RETURNED to the
  // active backlog is current; its historical archive rows fall through to superseded-history
  // residuals. Archived is a last-resort classification ONLY when no live-backlog membership
  // exists.
  if (t.liveBacklog.has('running')) return 'running';
  if (t.liveBacklog.has('queued')) return 'queued';
  if (t.liveBacklog.has('completed')) return 'completed';
  if (t.stores.has('done-archive') || t.hasArchivedBacklog) return 'archived';
  const runEvents = t.eventRecords.filter((p) => p.eventRow.fields.event_scope === 'run').sort((a, b) => a.ordinal - b.ordinal);
  if (runEvents.length > 0) {
    const last = runEvents[runEvents.length - 1].eventRow.fields.event_type;
    if (EVENT_TO_STATE[last]) return EVENT_TO_STATE[last];
  }
  const runs = t.runRecords.slice().sort((a, b) => a.ordinal - b.ordinal);
  if (runs.length > 0) {
    const st = runs[runs.length - 1].runRow.fields.status;
    if (st === 'completed') return 'completed';
    if (st === 'failed') return 'failed';
    return 'running';
  }
  if (t.hasLiveMeta || t.hasWorktree) return 'running';
  return 'queued';
}

function hasRunningOnlyEvents(t) {
  return t.eventRecords.some((p) => p.eventRow.fields.event_scope === 'run' && NEEDS_RUNNING.has(p.eventRow.fields.event_type));
}

// ---------------------------------------------------------------------------------
// Store probes (read-only seam only)
// ---------------------------------------------------------------------------------

async function tableExists(store, name) {
  const rows = await readOnlyQuery(store, "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1", [name]);
  return rows.length > 0;
}
async function countRows(store, table) {
  if (!(await tableExists(store, table))) return 0;
  const rows = await readOnlyQuery(store, `SELECT count(*)::int AS n FROM ${table}`);
  return Number(rows[0].n);
}

const STATE_TABLES = ['tasks', 'runs', 'task_events', 'outbox', 'snapshots', 'command_results', 'migration_receipts'];
async function probeTarget(store) {
  const initialized = await tableExists(store, 'coordinator_state');
  const counts = {};
  let nonEmpty = 0;
  for (const tbl of STATE_TABLES) { counts[tbl] = await countRows(store, tbl); nonEmpty += counts[tbl]; }
  return { initialized, counts, nonEmpty };
}
async function taskStatusMap(store) {
  const out = new Map();
  if (await tableExists(store, 'tasks')) {
    const rows = await readOnlyQuery(store, 'SELECT task_id, status FROM tasks');
    for (const r of rows) out.set(r.task_id, r.status);
  }
  return out;
}

// ---------------------------------------------------------------------------------
// Synthesized migration identity (only for the transient terminal promotion path).
// ---------------------------------------------------------------------------------

function migrationCapture(taskId, gen, run) {
  const tag = `migrated:${taskId}/${gen}`;
  const paneHash = crypto.createHash('sha256').update(tag).digest('hex').slice(0, 12);
  return () => ({
    ok: true,
    identity: {
      endpointId: tag, paneId: `%mig-${paneHash}`, paneLeaderPid: 1, paneStartTicks: 1, bootId: 'migrated',
      agentPid: 1, agentStartTicks: 1, agentExe: 'migrated', agentArgvHash: `mig-${paneHash}`,
      agentPpid: 1, agentPty: 'migrated', worktree: (run && run.worktree) || null, harness: (run && run.harness) || null
    }
  });
}
const migrationProbeMatch = () => ({ matches: true });

function reasonFrom(err) { return `apply rejected: ${err && err.message ? err.message : String(err)}`; }

// ---------------------------------------------------------------------------------
// Materialize one task (drive-and-catch).
// ---------------------------------------------------------------------------------

const REST_UNVERIFIED_REASON = 'requires a verified running binding, which a migrated in-flight task cannot honestly assert (it has no live endpoint); the task rests unverified (spawning) for the S5 reconciler to settle - event not applied';

async function materializeTask(store, t, ctx) {
  const dispo = new Map();
  const set = (ref, v) => dispo.set(ref, { taskId: t.taskId, ...v });
  const flagAll = (reason) => { for (const p of t.records) set(p.source_ref, { applied: false, reason }); };

  if (!t.kind) { flagAll(t.kindReason); return dispo; }

  const current = deriveCurrentState(t);
  if (current === 'archived') {
    flagAll('archived/finished task with no live-backlog membership: the terminal-delivery + ack + cleanup + archive chain is deferred to the named CW2 archive back-fill stage; not materialized into the live control plane in CW1');
    return dispo;
  }

  // 1. create-task. F1 (ruling Q1b): a current-running task with no captured live endpoint
  // materializes as QUEUED with NO run row - a queued task is not a reconcile candidate
  // (snapshotCandidates selects only spawning/open/cleanup_pending), so elapsed migration
  // time can never terminal-fail it. The was-in-flight/worktree fact rides the internalReason
  // metadata channel (internal origin only), NEVER a fabricated run.
  const owner = createOwner(t);
  const ownerKey = owner ? cmdId('create-task', owner.key) : cmdId('create-task', recordKey({ source_ref: t.taskId, source: { digest: t.taskId } }));
  let internalReason = t.internalReason;
  if (current === 'running' && t.origin === 'internal') {
    internalReason = `${t.internalReason}; migrated in-flight backlog task${t.hasWorktree ? ' (worktree present)' : ''} materialized queued for re-dispatch - no live endpoint captured`;
  }
  let rev;
  try {
    const r = await createTask(store, { taskId: t.taskId, kind: t.kind, title: t.title, repo: t.repo, origin: t.origin, orderRef: t.orderRef, internalReason, commandId: ownerKey });
    rev = r.revision;
    ctx.counters.tasksCreated += 1;
    for (const p of t.records) {
      if (p.primary === 'task') set(p.source_ref, { applied: true, verb: 'create-task', prescribedStatus: p.taskRow.fields.status });
      else if (p.primary === 'event' && p.eventRow.fields.event_scope === 'task' && p.eventRow.fields.event_type === 'created') set(p.source_ref, { applied: true, verb: 'create-task(subsumed)' });
    }
  } catch (err) { flagAll(reasonFrom(err)); return dispo; }

  // Task-scope archived events are not reconstructed in CW1.
  for (const p of t.eventRecords) {
    if (p.eventRow.fields.event_scope === 'task' && p.eventRow.fields.event_type === 'archived' && !dispo.has(p.source_ref)) {
      set(p.source_ref, { applied: false, reason: 'task-scope archived event needs the acked-terminal + cleanup archive chain (S4/S3 live path) not reconstructed in CW1' });
    }
  }

  // F1: a queued task, AND a migrated in-flight task, both land queued with NO run row.
  if (current === 'queued' || current === 'running') {
    const note = current === 'running'
      ? 'migrated in-flight backlog task materialized queued (no live endpoint captured); its run/event history is not replayed as a live run in CW1 - retained for CW2 re-dispatch/back-fill'
      : 'task is currently queued; run/event history not materialized for a queued task';
    for (const p of t.records) if (!dispo.has(p.source_ref)) set(p.source_ref, { applied: false, reason: note });
    return dispo;
  }

  // 2. begin-run (single generation - CW1 does not reconstruct multi-generation history).
  const gen = 1;
  const primaryRun = t.runRecords.slice().sort((a, b) => a.ordinal - b.ordinal)[0] || null;
  const runKeyRec = primaryRun || owner || t.records[0];
  let running = false;
  try {
    const b = await beginRun(store, { taskId: t.taskId, expectedRevision: rev, backend: primaryRun && primaryRun.runRow.fields.backend ? primaryRun.runRow.fields.backend : undefined, commandId: cmdId('begin-run', runKeyRec.key) });
    rev = b.revision;
    ctx.counters.runsBegun += 1;

    // 3. Transient verified promotion ONLY for a terminal task (its run ends CLOSED, so no
    // live binding lie persists). A currently-running task is NEVER promoted (finding 4).
    const reachRunning = current === 'completed' || (current === 'failed' && hasRunningOnlyEvents(t));
    if (reachRunning) {
      const info = primaryRun ? primaryRun.runRow.fields : {};
      const rs = await recordSpawn(store, { taskId: t.taskId, generation: gen, expectedRevision: rev, launchMarker: b.launch_marker, endpoint: `migrated:${t.taskId}/${gen}`, pane: '%mig', regFile: b.registration_path, commandId: cmdId('record-spawn', runKeyRec.key) }, { captureIdentity: migrationCapture(t.taskId, gen, info) });
      rev = rs.revision;
      const cr = await commitRunning(store, { taskId: t.taskId, generation: gen, expectedRevision: rev, commandId: cmdId('commit-running', runKeyRec.key) }, { probeIdentity: migrationProbeMatch });
      rev = cr.revision;
      running = true;
    }
  } catch (err) {
    const reason = reasonFrom(err);
    for (const p of [...t.runRecords, ...t.eventRecords]) if (!dispo.has(p.source_ref)) set(p.source_ref, { applied: false, reason });
    return dispo;
  }

  // 4. Non-terminal run-scope events in CHRONOLOGICAL order (finding 2).
  const seqByProducer = new Map();
  const nextSeq = (producer) => { const n = (seqByProducer.get(producer) || 0) + 1; seqByProducer.set(producer, n); return n; };
  const runEvents = t.eventRecords.filter((p) => p.eventRow.fields.event_scope === 'run').sort((a, b) => a.ordinal - b.ordinal);
  for (const p of runEvents) {
    if (dispo.has(p.source_ref)) continue;
    const f = p.eventRow.fields;
    if (f.event_type === 'completed' || f.event_type === 'failed') continue; // terminal, step 5
    if (!APPENDABLE.has(f.event_type)) { set(p.source_ref, { applied: false, reason: `event type '${f.event_type}' is not caller-appendable` }); continue; }
    if (NEEDS_RUNNING.has(f.event_type) && !running) { set(p.source_ref, { applied: false, reason: REST_UNVERIFIED_REASON }); continue; }
    const producer = EVENT_PRODUCERS.has(f.producer_id) ? f.producer_id : 'crewmate';
    try {
      const e = await appendEvent(store, { taskId: t.taskId, generation: gen, eventType: f.event_type, producer, seq: nextSeq(producer), expectedRevision: rev, payload: f.payload_json && typeof f.payload_json === 'object' ? f.payload_json : {}, commandId: cmdId('event', p.key) });
      rev = e.revision;
      ctx.counters.eventsApplied += 1;
      set(p.source_ref, { applied: true, verb: 'event' });
    } catch (err) { set(p.source_ref, { applied: false, reason: reasonFrom(err) }); }
  }

  // 5. Terminal, at most once, ONLY when it is the CURRENT state (a historical terminal
  // superseded by a later state is NOT applied).
  let terminalApplied = false;
  if (current === 'completed' || current === 'failed') {
    const drivers = [
      ...t.runRecords.filter((p) => p.runRow.fields.status === current),
      ...t.eventRecords.filter((p) => p.eventRow.fields.event_scope === 'run' && p.eventRow.fields.event_type === current)
    ].sort((a, b) => a.ordinal - b.ordinal);
    const driver = drivers[0] || primaryRun || owner;
    const producer = 'crewmate';
    try {
      if (current === 'completed') {
        const c = await completeRun(store, { taskId: t.taskId, generation: gen, expectedRevision: rev, outcome: 'success', producer, seq: nextSeq(producer), evidence: { migrated: true }, commandId: cmdId('complete', driver.key) });
        rev = c.revision;
      } else {
        const c = await failRun(store, { taskId: t.taskId, generation: gen, expectedRevision: rev, reason: 'migrated: legacy terminal failure', producer, seq: nextSeq(producer), artifacts: { migrated: true }, commandId: cmdId('fail', driver.key) });
        rev = c.revision;
      }
      terminalApplied = true;
      ctx.counters.terminalsApplied += 1;
      set(driver.source_ref, { applied: true, verb: current });
    } catch (err) { set(driver.source_ref, { applied: false, reason: reasonFrom(err) }); }
  }

  // 6. Disposition the remaining run/event records.
  for (const p of t.runRecords) {
    if (dispo.has(p.source_ref)) continue;
    const st = p.runRow.fields.status;
    if ((st === undefined || st === 'open') && current === 'running') set(p.source_ref, { applied: true, verb: 'begin-run(unverified)' });
    else if (st === current && terminalApplied) set(p.source_ref, { applied: true, verb: 'terminal(collapsed)' });
    else set(p.source_ref, { applied: false, reason: 'historical/additional run generation superseded by the current state (single-generation collapse); retained for CW2 history back-fill' });
  }
  for (const p of t.eventRecords) {
    if (dispo.has(p.source_ref)) continue;
    const f = p.eventRow.fields;
    if (['completed', 'failed'].includes(f.event_type)) {
      if (terminalApplied && f.event_type === current) set(p.source_ref, { applied: true, verb: 'terminal(subsumed)' });
      else set(p.source_ref, { applied: false, reason: 'historical terminal superseded by the current state (rework cycle); not applied' });
    } else set(p.source_ref, { applied: false, reason: 'run-scope event could not be attributed to the materialized generation' });
  }
  return dispo;
}

// ---------------------------------------------------------------------------------
// Post-commit per-record verification (finding 1)
// ---------------------------------------------------------------------------------

// Is a committed task status CONSISTENT with a record's prescribed status? A migrated
// in-flight task prescribed 'running' legitimately rests in the spawning/in-flight family.
export function statusConsistent(prescribed, actual) {
  if (!prescribed) return true;
  if (prescribed === actual) return true;
  // A migrated in-flight ('running') backlog task lands 'queued' (F1: no fabricated run), and
  // the spawning/in-flight family is also acceptable, so all count as consistent.
  if (prescribed === 'running') return ['queued', 'spawning', 'running', 'blocked', 'needs_human', 'waiting_firstmate'].includes(actual);
  return false;
}

// Re-read the committed store and downgrade any applied record whose prescribed status is
// not actually present, so the applied count reflects committed state, never intent.
async function verifyAppliedAgainstStore(store, dispoBySource) {
  const statuses = await taskStatusMap(store);
  let downgraded = 0;
  for (const [ref, v] of dispoBySource) {
    if (!v.applied || !v.prescribedStatus) continue;
    const actual = statuses.get(v.taskId);
    if (!statusConsistent(v.prescribedStatus, actual)) {
      dispoBySource.set(ref, { taskId: v.taskId, applied: false, reason: `prescribed status '${v.prescribedStatus}' not committed (store status '${actual ?? 'absent'}'); counted residual, not applied` });
      downgraded += 1;
    }
  }
  return downgraded;
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
function realOf(p) { return nodeFs.existsSync(p) ? nodeFs.realpathSync(p) : path.resolve(p); }

function resolveContainedOut(outPath, dataDir, legacyHome) {
  const outAbs = path.resolve(outPath);
  const resolvedDir = realDirOf(path.dirname(outAbs));
  const resolvedOut = path.join(resolvedDir, path.basename(outAbs));
  const forbidden = [{ label: 'target store', root: realOf(dataDir) }];
  if (typeof legacyHome === 'string' && legacyHome.length > 0) forbidden.push({ label: 'legacy home', root: realOf(legacyHome) });
  for (const f of forbidden) {
    if (isAtOrUnder(f.root, resolvedDir) || isAtOrUnder(f.root, resolvedOut)) {
      throw new MigrateApplyError(`--out resolves under the ${f.label} (symlink or traversal); refused`, { out: resolvedOut, resolved_dir: resolvedDir, root: f.root });
    }
  }
  return resolvedOut;
}
function atomicWriteOwnerOnly(outPath, content) {
  const dir = path.dirname(outPath);
  if (!nodeFs.existsSync(dir)) { nodeFs.mkdirSync(dir, { recursive: true }); nodeFs.chmodSync(dir, 0o700); }
  const tmp = `${outPath}.tmp.${process.pid}`;
  const fd = nodeFs.openSync(tmp, 'w', 0o600);
  try { nodeFs.writeFileSync(fd, content); nodeFs.fsyncSync(fd); } finally { nodeFs.closeSync(fd); }
  nodeFs.chmodSync(tmp, 0o600);
  nodeFs.renameSync(tmp, outPath);
  nodeFs.chmodSync(outPath, 0o600);
}
function tempEmptyOrderSource() {
  const dir = nodeFs.mkdtempSync(path.join(os.tmpdir(), 'cp-cw1-snap-'));
  const p = path.join(dir, 'captain-orders.jsonl');
  nodeFs.writeFileSync(p, '');
  return { path: p, dir };
}

// ---------------------------------------------------------------------------------
// The executor
// ---------------------------------------------------------------------------------

// A deterministic fixed timestamp for receipt rows (keeps the module clock-free; receipt
// created_at is not part of the reconciliation).
function fixedNow() { return '1970-01-01T00:00:00.000Z'; }

export async function runMigrateApply({
  reportPath, dataDir, outPath, resume = false, orderSourcePath,
  allowResidualOver = DEFAULT_MAX_RESIDUAL_PCT, env = process.env, hooks = {}
} = {}) {
  if (typeof dataDir !== 'string' || dataDir.length === 0) throw new MigrateApplyError('migrate-apply requires --data-dir <control-plane store path>', { data_dir: dataDir ?? null });
  if (typeof outPath !== 'string' || outPath.length === 0) throw new MigrateApplyError('migrate-apply requires --out <residual-report-path>', { out: outPath ?? null });
  const report = loadReport(reportPath);
  const resolvedOut = resolveContainedOut(outPath, dataDir, report.legacy_home);
  const tasks = assembleTasks(report);
  const mappedCount = report.records.filter((d) => d.disposition === 'mapped').length;

  const store = PgliteLocalStore.create({ dataDir, env });
  let snapTmp;
  try {
    const probe = await probeTarget(store);
    if (!probe.initialized) throw new MigrateApplyError('target store is not initialized; run `cp init --data-dir <path>` first', { data_dir: dataDir });
    if (probe.nonEmpty > 0 && !resume) {
      throw new MigrateApplyError('target store already contains state; refusing to migrate into a non-empty store without --resume', { data_dir: dataDir, counts: probe.counts });
    }

    // Finding 3: prior per-source receipts drive honest resume classification.
    const priorReceipts = resume ? await loadReceipts(store) : new Map();
    const ctx = { counters: { tasksCreated: 0, runsBegun: 0, eventsApplied: 0, terminalsApplied: 0 } };

    const orderedTasks = [...tasks.values()].sort((a, b) => (a.taskId < b.taskId ? -1 : 1));
    const dispoBySource = new Map();
    for (const t of orderedTasks) {
      const dispo = await materializeTask(store, t, ctx);
      for (const [ref, v] of dispo) dispoBySource.set(ref, v);
      if (typeof hooks.afterTask === 'function') await hooks.afterTask(ctx.counters.tasksCreated);
    }

    // Finding 1: verify applied records against COMMITTED store state; downgrade mismatches.
    const downgraded = await verifyAppliedAgainstStore(store, dispoBySource);

    // F2 COMPLETENESS GATE: a task with LIVE-BACKLOG In flight/Queued membership is current
    // operational work and MUST be materialized (at least one of its records applied). If any
    // such task ends fully residual, that is a hard failure in the same class as the
    // totality/ceiling gates - current live work must never silently drop into the residual.
    const liveSurfaceViolations = [];
    for (const t of orderedTasks) {
      if (!(t.liveBacklog.has('running') || t.liveBacklog.has('queued'))) continue;
      const anyApplied = t.records.some((p) => { const v = dispoBySource.get(p.source_ref); return v && v.applied; });
      if (!anyApplied) liveSurfaceViolations.push(t.taskId);
    }

    // Build the applied receipt (new vs replayed per SOURCE record) and the residual.
    const executorFlagged = [];
    const appliedRecords = [];
    const receiptEntries = [];
    for (const d of report.records) {
      if (d.disposition !== 'mapped') continue;
      const v = dispoBySource.get(d.source_ref) || { applied: false, reason: 'record not reached by the planner' };
      const application = priorReceipts.has(recordKey(d)) ? 'replay' : 'new';
      receiptEntries.push({ record_key: recordKey(d), source_ref: d.source_ref, source_digest: d.source.digest, disposition: v.applied ? 'applied' : 'residual', verb: v.verb ?? null, reason: v.reason ?? null });
      if (v.applied) appliedRecords.push({ source_ref: d.source_ref, store: d.store, verb: v.verb, application });
      else executorFlagged.push({ source_ref: d.source_ref, store: d.store, origin: 'executor', reason: v.reason, canonical: d.mapping.canonical, source: d.source ?? null });
    }
    const echoedFlagged = report.records.filter((d) => d.disposition === 'flagged').map((d) => ({ source_ref: d.source_ref, store: d.store, origin: 'report', reason: `${d.flag.reason}: ${d.flag.detail ?? ''}`.trim(), flag: d.flag, source: d.source ?? null }));
    const residual = [...echoedFlagged, ...executorFlagged];

    // Persist per-source receipts (batched, one commit).
    await writeReceipts(store, receiptEntries, { now: fixedNow() });

    // Reconciliation.
    const counts = { tasks: await countRows(store, 'tasks'), runs: await countRows(store, 'runs'), task_events: await countRows(store, 'task_events') };
    let snapshotOk = false; let snapshotRevision = null; let snapshotError = null;
    try {
      let src = orderSourcePath;
      if (typeof src !== 'string' || src.length === 0) { snapTmp = tempEmptyOrderSource(); src = snapTmp.path; }
      const snap = await createSnapshot(store, { orderSourcePath: src });
      snapshotOk = true;
      snapshotRevision = snap && Number.isInteger(snap.projection_revision) ? snap.projection_revision : null;
    } catch (err) { snapshotError = err.message; }

    const residualOfMapped = mappedCount === 0 ? 0 : ((mappedCount - appliedRecords.length) / mappedCount) * 100;
    const totalityHolds = appliedRecords.length + executorFlagged.length === mappedCount;
    const countsCoherent = counts.tasks === ctx.counters.tasksCreated && counts.runs === ctx.counters.runsBegun;
    const reconciliation = {
      mapped: mappedCount,
      applied: appliedRecords.length,
      applied_new: appliedRecords.filter((r) => r.application === 'new').length,
      applied_replayed: appliedRecords.filter((r) => r.application === 'replay').length,
      executor_flagged: executorFlagged.length,
      echoed_flagged: echoedFlagged.length,
      downgraded_by_verification: downgraded,
      residual_of_mapped_pct: Math.round(residualOfMapped * 100) / 100,
      allow_residual_over_pct: allowResidualOver,
      totality_holds: totalityHolds,
      applied_nonzero: appliedRecords.length > 0,
      residual_within_ceiling: residualOfMapped <= allowResidualOver,
      live_surface_complete: liveSurfaceViolations.length === 0,
      live_surface_violations: liveSurfaceViolations,
      store_counts: counts,
      materialized: ctx.counters,
      counts_coherent: countsCoherent,
      snapshot_ok: snapshotOk,
      snapshot_revision: snapshotRevision,
      snapshot_error: snapshotError,
      ok: totalityHolds && appliedRecords.length > 0 && residualOfMapped <= allowResidualOver && countsCoherent && snapshotOk && liveSurfaceViolations.length === 0
    };

    const body = buildResidualReport({ report, reportPath, dataDir, resumed: resume, appliedRecords, residual, reconciliation });
    atomicWriteOwnerOnly(resolvedOut, `${JSON.stringify(body, null, 2)}\n`);

    if (!reconciliation.ok) throw new MigrateReconcileError('migrate-apply reconciliation failed; see the residual/verification report', { out: resolvedOut, reconciliation });

    return { out: resolvedOut, data_dir: dataDir, source_report: reportPath, resumed: resume, mapped: mappedCount, applied: appliedRecords.length, executor_flagged: executorFlagged.length, echoed_flagged: echoedFlagged.length, residual: residual.length, reconciliation };
  } finally {
    if (snapTmp) { try { nodeFs.rmSync(snapTmp.dir, { recursive: true, force: true }); } catch { /* best effort */ } }
    await store.close();
  }
}

function buildResidualReport({ report, reportPath, dataDir, resumed, appliedRecords, residual, reconciliation }) {
  return {
    schema: RESIDUAL_SCHEMA,
    posture: 'materialized mapped proposals via cp verbs only; archived/finished tasks residualized; legacy stores untouched (input is the S8 report file)',
    source_report: reportPath,
    source_report_schema: report.schema,
    legacy_home: report.legacy_home ?? null,
    data_dir: dataDir,
    resumed,
    totals: {
      report_mapped: report.totals.mapped,
      report_flagged: report.totals.flagged,
      applied: appliedRecords.length,
      applied_new: appliedRecords.filter((r) => r.application === 'new').length,
      applied_replayed: appliedRecords.filter((r) => r.application === 'replay').length,
      residual: residual.length,
      echoed_flagged: residual.filter((r) => r.origin === 'report').length,
      executor_flagged: residual.filter((r) => r.origin === 'executor').length
    },
    reconciliation,
    applied: appliedRecords,
    residual
  };
}
