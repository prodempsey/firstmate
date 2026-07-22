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
import { REPORT_SCHEMA } from './migrate-report.mjs';
import { MigrateApplyError, MigrateReconcileError } from './errors-cw1.mjs';

// `cp migrate-apply --report <s8-report> --data-dir <store> --out <residual>` (CUTOVER
// stage CW1). The MIGRATION EXECUTOR: it turns the S8 migrate-report's `mapped` proposals
// into real control-plane records by driving the LANDED cp verb chain, and echoes to a
// residual report only what it cannot legally apply.
//
// The S8 report's `mapped` records are a PRESCRIPTION to apply, not a menu to decline
// (qa-cw1-q82 finding 1). So the executor materializes every mapped shape it can reach
// through the verb chain:
//
//   * task records (state-meta / backlog / done-archive / captain-order) -> create-task,
//     with kind/title/origin RESOLVED by joining the task's proposals (meta supplies the
//     kind a backlog bullet lacks; an order event supplies the captain-order origin).
//   * run-bearing records (a ship/scout meta with a worktree, a task-runs ledger entry)
//     -> create-task -> begin-run, then to the mapping's prescribed run state: a
//     record-spawn/commit-running pair using a SYNTHESIZED migration identity (the
//     mapping itself marks the launch identity "synthesized-at-migration"), or the
//     partial-launch fail path, or a terminal complete/fail.
//   * lifecycle / status events -> the generic `event` verb (progress/blocked/
//     needs_human/unblocked) or `complete`/`fail` per the mapping's event type.
//
// DRIVE-AND-CATCH is the safety spine. Every write is a landed verb through the command
// envelope; the domain layer enforces every invariant (legal transition, monotone
// producer seq, CAS revision, terminal-once). The executor ATTEMPTS the prescribed
// operation and, on any domain rejection, records that record as executor-FLAGGED with
// the rejection reason and moves on. It therefore can never corrupt the store (a rejected
// command rolls its own transaction back) and can never force an illegal state (an
// illegal op is flagged, not retried differently). Only genuinely un-prescribed or
// un-reachable shapes go residual - each with a concrete reason.
//
// Hardening (qa-cw1-q82 findings 2-5):
//   2. --out is realpath-contained against BOTH the target store AND the report's
//      legacy_home, symlink-safe, so the executor can never write into a legacy store.
//   3. Application identity is the SOURCE POINTER + SOURCE HASH: every command-id is
//      keyed by sha(source_ref, source.digest), loadReport enforces a strict source_ref
//      bijection and a present digest, and duplicates are REJECTED, not counted applied.
//      The residual/receipt distinguishes newly-applied, replayed, and residual records.
//   4. A pre-populated target is REJECTED BEFORE ANY MUTATION: the preflight probes every
//      domain + migration table and refuses a non-empty store unless --resume.
//   5. The executor has NO arbitrary-SQL capability: reads go through the SELECT-only
//      cw1-readonly seam; writes go only through the landed verb functions.
//
// RECONCILIATION FAILS LOUDLY (finding 1): applied + executor-flagged === mapped, and the
// run is rejected when applied is zero or the residual fraction of mapped exceeds
// --allow-residual-over (default DEFAULT_MAX_RESIDUAL_PCT).

export const RESIDUAL_SCHEMA = 'control-plane/migrate-apply/residual/v1';

const MIGRATE_CMD_PREFIX = 'migrate-apply';
const VALID_KINDS = new Set(['ship', 'scout', 'secondmate']);
const APPENDABLE = new Set(['progress', 'blocked', 'unblocked', 'waiting_firstmate', 'needs_human', 'rework']);
const EVENT_PRODUCERS = new Set(['coordinator', 'adapter', 'crewmate', 'firstmate', 'reconciler']);

// Default ceiling on the residual fraction of MAPPED records. A run that leaves more than
// this un-applied fails unless the operator passes --allow-residual-over <pct> after
// reviewing the residual report. applied === 0 always fails regardless of this ceiling.
export const DEFAULT_MAX_RESIDUAL_PCT = 35;

// ---------------------------------------------------------------------------------
// Report load + validation (finding 3: strict source bijection + present digest)
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
    // Finding 3: strict source-ref bijection - a duplicate source pointer is a malformed
    // report, refused, never counted as applied.
    if (seen.has(d.source_ref)) {
      throw new MigrateApplyError('--report has a duplicate source_ref; a strict source-pointer bijection is required', {
        report: reportPath, source_ref: d.source_ref
      });
    }
    seen.add(d.source_ref);
    // Finding 3: every record must carry its source hash - the application identity.
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

// Stable per-record application identity: sha(source_ref, source.digest). Idempotency and
// resume key on THIS, so a source record whose content changed gets a different id (not a
// false replay), and the same record always maps to the same command.
export function recordKey(d) {
  return crypto.createHash('sha256').update(`${d.source_ref} ${d.source.digest}`).digest('hex');
}
function cmdId(verb, key) {
  return `${MIGRATE_CMD_PREFIX}:${verb}:${key}`;
}

// ---------------------------------------------------------------------------------
// Assembly (pure): join every mapped record into per-task facts.
// ---------------------------------------------------------------------------------

function parseRecord(d) {
  const rows = d.mapping.canonical;
  const taskRow = rows.find((r) => r.table === 'tasks') || null;
  const runRow = rows.find((r) => r.table === 'runs') || null;
  const eventRow = rows.find((r) => r.table === 'task_events') || null;
  const anchor = taskRow || runRow || eventRow;
  const taskId = anchor && anchor.fields ? anchor.fields.task_id : null;
  const primary = runRow ? 'run' : eventRow ? 'event' : 'task';
  return { d, source_ref: d.source_ref, key: recordKey(d), taskId, taskRow, runRow, eventRow, primary };
}

const firstSorted = (set) => [...set].sort()[0];

// The S8 canonical `tasks` row leaves kind/title unresolved for a record whose store does
// not carry them (a backlog bullet has no kind; a done-archive line has no kind), but the
// report's per-record `source.value` payload DOES preserve them: task-runs and
// task-lifecycle records carry `kind`/`title`/`project` directly, and backlog/done-archive
// lines carry an inline `(kind: ...)`. Harvesting them here is the "resolve kind per the S8
// mapping fields" the charter asks for - it reads only what the report already contains,
// and never edits S8. Only a VALID kind is harvested; an invalid or conflicting value is
// left to resolveIdentity to flag rather than silently pick.
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
  return out;
}

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
        orderRefs: new Set(), backlogStatuses: new Set(), runRecords: [], eventRecords: [], taskRecords: []
      };
      tasks.set(p.taskId, t);
    }
    t.records.push(p);
    if (p.taskRow) {
      const f = p.taskRow.fields;
      if (typeof f.kind === 'string' && f.kind.length > 0) t.kinds.add(f.kind);
      if (typeof f.title === 'string' && f.title.length > 0) t.titles.add(f.title);
      if (typeof f.repo === 'string' && f.repo.length > 0) t.repos.add(f.repo);
      if (typeof f.order_ref === 'string' && f.order_ref.length > 0) t.orderRefs.add(f.order_ref);
      if (typeof f.status === 'string' && f.status.length > 0) t.backlogStatuses.add(f.status);
    }
    // Harvest kind/title/repo from the record's source payload for the (common) tasks
    // whose canonical row lacks them - the historical tasks with no live meta file.
    const h = harvestFromSource(d);
    if (h.kind) t.kinds.add(h.kind);
    if (h.title) t.titles.add(h.title);
    if (h.repo) t.repos.add(h.repo);
    if (p.primary === 'run') t.runRecords.push(p);
    else if (p.primary === 'event') t.eventRecords.push(p);
    else t.taskRecords.push(p);
  }
  for (const t of tasks.values()) resolveIdentity(t);
  return tasks;
}

// Resolve the create-task identity by joining the task's proposals. kind is required and
// checked (never guessed); title falls back to the task id (a label, not a semantic
// claim) when no bullet supplied one; origin is captain_order when an order event links
// the task, else internal with an explicit migration provenance.
function resolveIdentity(t) {
  if (t.kinds.size === 1 && VALID_KINDS.has(firstSorted(t.kinds))) {
    t.kind = firstSorted(t.kinds);
  } else if (t.kinds.size === 0) {
    t.kind = null; t.kindReason = 'kind un-prescribed (no state-meta/lifecycle record supplies a kind; create-task kind is a checked enum and is not guessed)';
  } else {
    t.kind = null; t.kindReason = `conflicting kinds ${[...t.kinds].sort().join('/')}; refusing to guess`;
  }
  t.title = t.titles.size >= 1 ? firstSorted(t.titles) : t.taskId;
  t.repo = t.repos.size === 1 ? firstSorted(t.repos) : undefined;
  if (t.orderRefs.size >= 1) {
    t.origin = 'captain_order';
    t.orderRef = firstSorted(t.orderRefs);
  } else {
    t.origin = 'internal';
    t.internalReason = 'migrated from legacy fleet state (no captain-order link recorded in the legacy stores)';
  }
}

// The single deterministic owner of a task's create-task: the smallest source_ref among
// records carrying a tasks row (so the command-id keys on a stable source pointer+hash).
function createOwner(t) {
  const carriers = t.records.filter((p) => p.taskRow).sort((a, b) => (a.source_ref < b.source_ref ? -1 : 1));
  return carriers[0] || null;
}

// The task's target lifecycle disposition, derived from the strongest signal across its
// run rows, event rows, and backlog status.
function targetOf(t) {
  let terminal = null; // 'completed' | 'failed'
  let wantRunning = false;
  let wantRun = false;
  for (const p of t.runRecords) {
    wantRun = true;
    const st = p.runRow.fields.status;
    if (st === 'failed') terminal = terminal || 'failed';
    else if (st === 'completed') terminal = terminal || 'completed';
    else wantRunning = true; // 'open' or unset -> running
  }
  for (const p of t.eventRecords) {
    const f = p.eventRow.fields;
    if (f.event_scope === 'task') continue; // created/archived handled separately
    wantRun = true;
    if (f.event_type === 'failed') { terminal = terminal || 'failed'; }
    else if (f.event_type === 'completed') { terminal = terminal || 'completed'; }
    else wantRunning = true; // progress/blocked/needs_human/unblocked need an open (running) generation
  }
  for (const s of t.backlogStatuses) {
    if (s === 'running') { wantRun = true; wantRunning = true; }
    else if (s === 'completed') { wantRun = true; terminal = terminal || 'completed'; }
    // 'archived' terminal-archive is not reconstructable in CW1 (needs acked terminal +
    // cleanup saga); it is handled as a residual note, not a target here.
  }
  if (terminal === 'completed') wantRunning = true; // complete requires a running task
  return { wantRun, wantRunning, terminal };
}

// ---------------------------------------------------------------------------------
// Store probes (read-only seam only)
// ---------------------------------------------------------------------------------

async function tableExists(store, name) {
  const rows = await readOnlyQuery(
    store,
    "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
    [name]
  );
  return rows.length > 0;
}
async function countRows(store, table) {
  if (!(await tableExists(store, table))) return 0;
  const rows = await readOnlyQuery(store, `SELECT count(*)::int AS n FROM ${table}`);
  return Number(rows[0].n);
}

// Finding 4: a full pre-mutation dirty-target probe. Any pre-existing domain, outbox,
// snapshot, or command-result row makes the target non-empty; it is refused before the
// first write unless --resume.
const STATE_TABLES = ['tasks', 'runs', 'task_events', 'outbox', 'snapshots', 'command_results'];
async function probeTarget(store) {
  const initialized = await tableExists(store, 'coordinator_state');
  const counts = {};
  let nonEmpty = 0;
  let priorMigrationCommands = 0;
  for (const tbl of STATE_TABLES) {
    counts[tbl] = await countRows(store, tbl);
    nonEmpty += counts[tbl];
  }
  if (await tableExists(store, 'command_results')) {
    const rows = await readOnlyQuery(
      store, 'SELECT count(*)::int AS n FROM command_results WHERE command_id LIKE $1', [`${MIGRATE_CMD_PREFIX}:%`]
    );
    priorMigrationCommands = Number(rows[0].n);
  }
  return { initialized, counts, nonEmpty, priorMigrationCommands };
}
async function existingMigrationCommandIds(store) {
  if (!(await tableExists(store, 'command_results'))) return new Set();
  const rows = await readOnlyQuery(
    store, 'SELECT command_id FROM command_results WHERE command_id LIKE $1', [`${MIGRATE_CMD_PREFIX}:%`]
  );
  return new Set(rows.map((r) => r.command_id));
}

// ---------------------------------------------------------------------------------
// Synthesized migration identity for the record-spawn/commit-running chain.
// The mapping marks the launch identity "synthesized-at-migration"; this is that
// synthesis. It is deterministic per (task, generation) and clearly migration-tagged, so
// a later reconciler re-verifies liveness rather than trusting it.
// ---------------------------------------------------------------------------------

function migrationCapture(taskId, gen, run) {
  const tag = `migrated:${taskId}/${gen}`;
  const paneHash = crypto.createHash('sha256').update(tag).digest('hex').slice(0, 12);
  return () => ({
    ok: true,
    identity: {
      endpointId: tag, paneId: `%mig-${paneHash}`, paneLeaderPid: 1, paneStartTicks: 1, bootId: 'migrated',
      agentPid: 1, agentStartTicks: 1, agentExe: 'migrated', agentArgvHash: `mig-${paneHash}`,
      agentPpid: 1, agentPty: 'migrated',
      worktree: (run && run.worktree) || null, harness: (run && run.harness) || null
    }
  });
}
const migrationProbeMatch = () => ({ matches: true });

// ---------------------------------------------------------------------------------
// Materialize one task through the verb chain (drive-and-catch).
// ---------------------------------------------------------------------------------

// Classify a domain error message into a compact residual reason.
function reasonFrom(err) {
  return `apply rejected: ${err && err.message ? err.message : String(err)}`;
}

async function materializeTask(store, t, ctx) {
  const dispo = new Map(); // source_ref -> { applied, reason, verb, replay }
  const flagAll = (reason) => { for (const p of t.records) dispo.set(p.source_ref, { applied: false, reason }); };
  const markVerb = (key) => ctx.preexisting.has(key) ? 'replay' : 'new';

  // 1. create-task.
  if (!t.kind) { flagAll(t.kindReason); return dispo; }
  const owner = createOwner(t);
  const ownerKey = owner ? cmdId('create-task', owner.key) : cmdId('create-task', recordKey({ source_ref: t.taskId, source: { digest: t.taskId } }));
  // A task's create-task command-id already present means this whole task's chain is being
  // REPLAYED (a resume), so every applied record of this task is marked replay, not new.
  const taskReplay = ctx.preexisting.has(ownerKey) ? 'replay' : 'new';
  let rev;
  try {
    const r = await createTask(store, {
      taskId: t.taskId, kind: t.kind, title: t.title, repo: t.repo,
      origin: t.origin, orderRef: t.orderRef, internalReason: t.internalReason, commandId: ownerKey
    });
    rev = r.revision;
    ctx.counters.tasksCreated += 1;
    if (markVerb(ownerKey) === 'replay') ctx.counters.replayed += 1;
    // Every task-primary record, plus any task-scope 'created' event record, is satisfied
    // by this create-task (create-task emits the canonical `created` event itself).
    for (const p of t.records) {
      if (p.primary === 'task') dispo.set(p.source_ref, { applied: true, verb: 'create-task', replay: taskReplay });
      else if (p.primary === 'event' && p.eventRow.fields.event_scope === 'task' && p.eventRow.fields.event_type === 'created') {
        dispo.set(p.source_ref, { applied: true, verb: 'create-task(subsumed)', replay: taskReplay });
      }
    }
  } catch (err) {
    flagAll(reasonFrom(err));
    return dispo;
  }

  const target = targetOf(t);
  // Task-scope 'archived' events are not reconstructable in CW1.
  for (const p of t.eventRecords) {
    if (p.eventRow.fields.event_scope === 'task' && p.eventRow.fields.event_type === 'archived' && !dispo.has(p.source_ref)) {
      dispo.set(p.source_ref, { applied: false, reason: 'archived state requires an acked terminal delivery + finished cleanup saga (S4/S3 live path) not reconstructed in the CW1 point-in-time migration' });
    }
  }

  if (!target.wantRun) {
    // A pure queued task. Any leftover run/event records get an explicit reason.
    for (const p of t.records) if (!dispo.has(p.source_ref)) dispo.set(p.source_ref, { applied: false, reason: 'no run/terminal signal for this task; left queued' });
    return dispo;
  }

  // 2. begin-run (generation 1 - CW1 materializes a single generation).
  const gen = 1;
  const primaryRun = t.runRecords.slice().sort((a, b) => (a.source_ref < b.source_ref ? -1 : 1))[0] || null;
  const runKeyRec = primaryRun || owner || t.records[0];
  const beginKey = cmdId('begin-run', runKeyRec.key);
  let running = false;
  try {
    const b = await beginRun(store, {
      taskId: t.taskId, expectedRevision: rev,
      backend: primaryRun && primaryRun.runRow.fields.backend ? primaryRun.runRow.fields.backend : undefined,
      commandId: beginKey
    });
    rev = b.revision;
    ctx.counters.runsBegun += 1;
    if (markVerb(beginKey) === 'replay') ctx.counters.replayed += 1;

    // 3. record-spawn + commit-running with synthesized identity, when a running (or
    // completed, which requires running) state is prescribed.
    if (target.wantRunning) {
      const runInfo = primaryRun ? primaryRun.runRow.fields : {};
      const spawnKey = cmdId('record-spawn', runKeyRec.key);
      const commitKey = cmdId('commit-running', runKeyRec.key);
      const rs = await recordSpawn(store, {
        taskId: t.taskId, generation: gen, expectedRevision: rev, launchMarker: b.launch_marker,
        endpoint: `migrated:${t.taskId}/${gen}`, pane: `%mig`, regFile: b.registration_path, commandId: spawnKey
      }, { captureIdentity: migrationCapture(t.taskId, gen, runInfo) });
      rev = rs.revision;
      const cr = await commitRunning(store, {
        taskId: t.taskId, generation: gen, expectedRevision: rev, commandId: commitKey
      }, { probeIdentity: migrationProbeMatch });
      rev = cr.revision;
      running = true;
    }
  } catch (err) {
    // begin-run/spawn/commit failed: the run records (and any run-scoped events) cannot be
    // materialized. Flag the still-undispositioned run/event records.
    const reason = reasonFrom(err);
    for (const p of [...t.runRecords, ...t.eventRecords]) if (!dispo.has(p.source_ref)) dispo.set(p.source_ref, { applied: false, reason });
    return dispo;
  }

  // 4. run-scoped, non-terminal events in report order (progress/blocked/needs_human/unblocked).
  const seqByProducer = new Map();
  const nextSeq = (producer) => { const n = (seqByProducer.get(producer) || 0) + 1; seqByProducer.set(producer, n); return n; };
  const runEvents = t.eventRecords
    .filter((p) => p.eventRow.fields.event_scope === 'run')
    .sort((a, b) => (a.source_ref < b.source_ref ? -1 : 1));
  let terminalApplied = false;
  for (const p of runEvents) {
    if (dispo.has(p.source_ref)) continue;
    const f = p.eventRow.fields;
    const producer = EVENT_PRODUCERS.has(f.producer_id) ? f.producer_id : 'crewmate';
    if (f.event_type === 'completed' || f.event_type === 'failed') {
      // Terminal events are applied in step 5 (once). Defer.
      continue;
    }
    if (!APPENDABLE.has(f.event_type)) {
      dispo.set(p.source_ref, { applied: false, reason: `event type '${f.event_type}' is not caller-appendable` });
      continue;
    }
    if (!running) { dispo.set(p.source_ref, { applied: false, reason: 'run did not reach a verified running state; run-scoped event not applied' }); continue; }
    const evKey = cmdId('event', p.key);
    try {
      const e = await appendEvent(store, {
        taskId: t.taskId, generation: gen, eventType: f.event_type, producer, seq: nextSeq(producer),
        expectedRevision: rev, payload: f.payload_json && typeof f.payload_json === 'object' ? f.payload_json : {}, commandId: evKey
      });
      rev = e.revision;
      ctx.counters.eventsApplied += 1;
      if (markVerb(evKey) === 'replay') ctx.counters.replayed += 1;
      dispo.set(p.source_ref, { applied: true, verb: 'event', replay: taskReplay });
    } catch (err) {
      dispo.set(p.source_ref, { applied: false, reason: reasonFrom(err) });
    }
  }

  // 5. terminal complete/fail (at most once). Prefer a terminal that a run record or a
  // terminal status event prescribes; drive it and attribute it to the driving record.
  const terminalDrivers = [
    ...t.runRecords.filter((p) => ['completed', 'failed'].includes(p.runRow.fields.status)),
    ...t.eventRecords.filter((p) => p.eventRow.fields.event_scope === 'run' && ['completed', 'failed'].includes(p.eventRow.fields.event_type))
  ].sort((a, b) => (a.source_ref < b.source_ref ? -1 : 1));

  if (target.terminal) {
    const driver = terminalDrivers[0] || primaryRun || owner;
    // The terminal's producer is the crewmate that reported the outcome (the status line
    // author), NOT the coordinator - the coordinator already spent seqs on
    // spawn_intent/spawned/running_verified in this generation, so a coordinator terminal
    // would collide with its own high-water. crewmate shares the sequence with the
    // run-scoped status events applied just above.
    const producer = 'crewmate';
    try {
      if (target.terminal === 'completed') {
        const c = await completeRun(store, {
          taskId: t.taskId, generation: gen, expectedRevision: rev, outcome: 'success', producer,
          seq: nextSeq(producer), evidence: { migrated: true }, commandId: cmdId('complete', driver.key)
        });
        rev = c.revision;
      } else {
        const c = await failRun(store, {
          taskId: t.taskId, generation: gen, expectedRevision: rev, reason: 'migrated: legacy terminal failure',
          producer, seq: nextSeq(producer), artifacts: { migrated: true }, commandId: cmdId('fail', driver.key)
        });
        rev = c.revision;
      }
      terminalApplied = true;
      ctx.counters.terminalsApplied += 1;
      dispo.set(driver.source_ref, { applied: true, verb: target.terminal, replay: taskReplay });
    } catch (err) {
      dispo.set(driver.source_ref, { applied: false, reason: reasonFrom(err) });
    }
  }

  // 6. Disposition the remaining run/terminal records.
  for (const p of t.runRecords) {
    if (dispo.has(p.source_ref)) continue;
    const st = p.runRow.fields.status;
    if ((st === undefined || st === 'open') && running) dispo.set(p.source_ref, { applied: true, verb: 'begin-run+commit-running', replay: taskReplay });
    else if (['completed', 'failed'].includes(st) && terminalApplied) dispo.set(p.source_ref, { applied: true, verb: 'terminal(collapsed)', replay: taskReplay });
    else dispo.set(p.source_ref, { applied: false, reason: 'additional/unapplied run generation not materialized in the CW1 single-generation migration' });
  }
  for (const p of t.eventRecords) {
    if (dispo.has(p.source_ref)) continue;
    const f = p.eventRow.fields;
    if (['completed', 'failed'].includes(f.event_type) && terminalApplied) dispo.set(p.source_ref, { applied: true, verb: 'terminal(subsumed)', replay: taskReplay });
    else dispo.set(p.source_ref, { applied: false, reason: 'run-scoped event could not be attributed to a materialized generation event' });
  }
  return dispo;
}

// ---------------------------------------------------------------------------------
// Verification / coherence
// ---------------------------------------------------------------------------------

async function domainCounts(store) {
  return {
    tasks: await countRows(store, 'tasks'),
    runs: await countRows(store, 'runs'),
    task_events: await countRows(store, 'task_events')
  };
}
async function verbTrace(store) {
  // Every task and run in the store must be attributable to a landed command result.
  // (A raw-SQL insert would leave a task/run with no command_results row.)
  if (!(await tableExists(store, 'tasks'))) return { untracedTasks: 0 };
  const rows = await readOnlyQuery(
    store,
    `SELECT count(*)::int AS n FROM tasks t
       WHERE NOT EXISTS (
         SELECT 1 FROM command_results c
          WHERE c.verb = 'create-task' AND c.result_json->>'task_id' = t.task_id
       )`
  );
  return { untracedTasks: Number(rows[0].n) };
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
function realOf(p) {
  return nodeFs.existsSync(p) ? nodeFs.realpathSync(p) : path.resolve(p);
}

// Finding 2: resolve --out and REFUSE any destination at or under the target store OR the
// report's legacy_home, defeating a symlinked ancestor and a lexical traversal alike.
function resolveContainedOut(outPath, dataDir, legacyHome) {
  const outAbs = path.resolve(outPath);
  const resolvedDir = realDirOf(path.dirname(outAbs));
  const resolvedOut = path.join(resolvedDir, path.basename(outAbs));
  const forbidden = [{ label: 'target store', root: realOf(dataDir) }];
  if (typeof legacyHome === 'string' && legacyHome.length > 0) {
    forbidden.push({ label: 'legacy home', root: realOf(legacyHome) });
  }
  for (const f of forbidden) {
    if (isAtOrUnder(f.root, resolvedDir) || isAtOrUnder(f.root, resolvedOut)) {
      throw new MigrateApplyError(`--out resolves under the ${f.label} (symlink or traversal); refused`, {
        out: resolvedOut, resolved_dir: resolvedDir, root: f.root
      });
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

export async function runMigrateApply({
  reportPath, dataDir, outPath, resume = false, orderSourcePath,
  allowResidualOver = DEFAULT_MAX_RESIDUAL_PCT, env = process.env, hooks = {}
} = {}) {
  if (typeof dataDir !== 'string' || dataDir.length === 0) {
    throw new MigrateApplyError('migrate-apply requires --data-dir <control-plane store path>', { data_dir: dataDir ?? null });
  }
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new MigrateApplyError('migrate-apply requires --out <residual-report-path>', { out: outPath ?? null });
  }
  const report = loadReport(reportPath);
  const resolvedOut = resolveContainedOut(outPath, dataDir, report.legacy_home);
  const tasks = assembleTasks(report);
  const mappedCount = report.records.filter((d) => d.disposition === 'mapped').length;

  const store = PgliteLocalStore.create({ dataDir, env });
  let snapTmp;
  try {
    // Finding 4: reject a dirty target BEFORE any mutation.
    const probe = await probeTarget(store);
    if (!probe.initialized) {
      throw new MigrateApplyError('target store is not initialized; run `cp init --data-dir <path>` first', { data_dir: dataDir });
    }
    if (probe.nonEmpty > 0 && !resume) {
      throw new MigrateApplyError('target store already contains state; refusing to migrate into a non-empty store without --resume', {
        data_dir: dataDir, counts: probe.counts, prior_migration_commands: probe.priorMigrationCommands
      });
    }

    const preexisting = await existingMigrationCommandIds(store);
    const ctx = {
      preexisting,
      counters: { tasksCreated: 0, runsBegun: 0, eventsApplied: 0, terminalsApplied: 0, replayed: 0 }
    };

    // Deterministic task order (stable across resume).
    const orderedTasks = [...tasks.values()].sort((a, b) => (a.taskId < b.taskId ? -1 : 1));
    const dispoBySource = new Map();
    let appliedCount = 0;
    for (const t of orderedTasks) {
      const dispo = await materializeTask(store, t, ctx);
      for (const [ref, v] of dispo) {
        dispoBySource.set(ref, v);
        if (v.applied) appliedCount += 1;
      }
      if (typeof hooks.afterTask === 'function') await hooks.afterTask(ctx.counters.tasksCreated);
    }

    // Build the per-record residual (executor-flagged mapped + echoed report-flagged) and
    // the applied receipt (new vs replay).
    const executorFlagged = [];
    const appliedRecords = [];
    for (const d of report.records) {
      if (d.disposition !== 'mapped') continue;
      const v = dispoBySource.get(d.source_ref) || { applied: false, reason: 'record not reached by the planner' };
      if (v.applied) {
        appliedRecords.push({ source_ref: d.source_ref, store: d.store, verb: v.verb, application: v.replay || 'new' });
      } else {
        executorFlagged.push({
          source_ref: d.source_ref, store: d.store, origin: 'executor', reason: v.reason,
          canonical: d.mapping.canonical, source: d.source ?? null
        });
      }
    }
    const echoedFlagged = report.records
      .filter((d) => d.disposition === 'flagged')
      .map((d) => ({
        source_ref: d.source_ref, store: d.store, origin: 'report',
        reason: `${d.flag.reason}: ${d.flag.detail ?? ''}`.trim(), flag: d.flag, source: d.source ?? null
      }));
    const residual = [...echoedFlagged, ...executorFlagged];

    // Reconciliation.
    const counts = await domainCounts(store);
    const trace = await verbTrace(store);
    let snapshotOk = false;
    let snapshotRevision = null;
    let snapshotError = null;
    try {
      let src = orderSourcePath;
      if (typeof src !== 'string' || src.length === 0) { snapTmp = tempEmptyOrderSource(); src = snapTmp.path; }
      const snap = await createSnapshot(store, { orderSourcePath: src });
      snapshotOk = true;
      snapshotRevision = snap && Number.isInteger(snap.projection_revision) ? snap.projection_revision : null;
    } catch (err) {
      snapshotError = err.message;
    }

    const residualOfMapped = mappedCount === 0 ? 0 : ((mappedCount - appliedCount) / mappedCount) * 100;
    const totalityHolds = appliedCount + executorFlagged.length === mappedCount;
    const appliedNonZero = appliedCount > 0;
    const residualWithinCeiling = residualOfMapped <= allowResidualOver;
    const verbOnly = trace.untracedTasks === 0;
    const countsCoherent =
      counts.tasks === ctx.counters.tasksCreated && counts.runs === ctx.counters.runsBegun;

    const reconciliation = {
      mapped: mappedCount,
      applied: appliedCount,
      executor_flagged: executorFlagged.length,
      echoed_flagged: echoedFlagged.length,
      residual_of_mapped_pct: Math.round(residualOfMapped * 100) / 100,
      allow_residual_over_pct: allowResidualOver,
      totality_holds: totalityHolds,
      applied_nonzero: appliedNonZero,
      residual_within_ceiling: residualWithinCeiling,
      store_counts: counts,
      materialized: ctx.counters,
      counts_coherent: countsCoherent,
      verb_only_writes: verbOnly,
      untraced_tasks: trace.untracedTasks,
      snapshot_ok: snapshotOk,
      snapshot_revision: snapshotRevision,
      snapshot_error: snapshotError,
      ok: totalityHolds && appliedNonZero && residualWithinCeiling && countsCoherent && verbOnly && snapshotOk
    };

    const body = buildResidualReport({ report, reportPath, dataDir, resumed: resume, appliedRecords, residual, reconciliation });
    const content = `${JSON.stringify(body, null, 2)}\n`;
    atomicWriteOwnerOnly(resolvedOut, content);

    if (!reconciliation.ok) {
      throw new MigrateReconcileError('migrate-apply reconciliation failed; see the residual/verification report', {
        out: resolvedOut, reconciliation
      });
    }

    return {
      out: resolvedOut, data_dir: dataDir, source_report: reportPath, resumed: resume,
      mapped: mappedCount, applied: appliedCount, executor_flagged: executorFlagged.length,
      echoed_flagged: echoedFlagged.length, residual: residual.length, reconciliation,
      bytes: Buffer.byteLength(content)
    };
  } finally {
    if (snapTmp) { try { nodeFs.rmSync(snapTmp.dir, { recursive: true, force: true }); } catch { /* best effort */ } }
    await store.close();
  }
}

function buildResidualReport({ report, reportPath, dataDir, resumed, appliedRecords, residual, reconciliation }) {
  const newCount = appliedRecords.filter((r) => r.application === 'new').length;
  const replayCount = appliedRecords.filter((r) => r.application === 'replay').length;
  return {
    schema: RESIDUAL_SCHEMA,
    posture: 'applied mapped proposals via cp verbs only; legacy stores untouched (input is the S8 report file)',
    source_report: reportPath,
    source_report_schema: report.schema,
    legacy_home: report.legacy_home ?? null,
    data_dir: dataDir,
    resumed,
    totals: {
      report_mapped: report.totals.mapped,
      report_flagged: report.totals.flagged,
      applied: appliedRecords.length,
      applied_new: newCount,
      applied_replayed: replayCount,
      residual: residual.length,
      echoed_flagged: residual.filter((r) => r.origin === 'report').length,
      executor_flagged: residual.filter((r) => r.origin === 'executor').length
    },
    reconciliation,
    applied: appliedRecords,
    residual
  };
}
