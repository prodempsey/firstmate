import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runVerb } from '../lib/coordinator.mjs';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createTask } from '../lib/domain-store.mjs';
import { reconcilePass } from '../lib/reconciler.mjs';
import {
  runMigrateApply, loadReport, assembleTasks, deriveCurrentState, ordinalOf,
  statusConsistent, recordKey, RESIDUAL_SCHEMA
} from '../lib/migrate-apply.mjs';
import { readOnlyQuery, assertSelectShape } from '../lib/cw1-readonly.mjs';
import { runMigrateReport, REPORT_SCHEMA } from '../lib/migrate-report.mjs';
import { MigrateApplyError, MigrateReconcileError } from '../lib/errors-cw1.mjs';
import { findViolations } from '../scripts/check-no-direct-pglite.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// CW1 migrate-apply (round 3, qa-cw1r2-q83 rework). Proves the four round-2 corrections:
//  (1) truthful counts - archived tasks are residualized not false-applied, and a
//      post-commit verification downgrades any applied record whose prescribed status is
//      not committed;
//  (2) current-state fidelity - numeric chronological ordering, and a task with a
//      historical terminal followed by later activity lands at its later state;
//  (3) per-source-pointer+hash resume identity, including subsumed records (a changed
//      non-owner digest is reprocessed as new, not falsely replayed);
//  (4) honest bindings - a migrated running task lands spawning/unverified and fails
//      cp verify-running rather than asserting a fake bound_verified.
// Plus the retained round-1 hardening (containment, dirty target, read-only seam, loud
// reconciliation, source-bijection) and an end-to-end real migrate-report run.
after(cleanupAll);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const digestOf = (raw) => crypto.createHash('sha256').update(raw).digest('hex');

function md(store, sourceRef, canonical, value = {}) {
  return { store, source_ref: sourceRef, disposition: 'mapped', mapping: { canonical }, source: { digest: digestOf(sourceRef), raw: sourceRef, value } };
}
function fl(store, sourceRef, reason, detail) {
  return { store, source_ref: sourceRef, disposition: 'flagged', flag: { reason, detail }, source: { digest: digestOf(sourceRef), raw: sourceRef, value: {} } };
}
const trow = (fields) => ({ table: 'tasks', key: fields.task_id, fields, provenance: { task_id: 's' }, unresolved: [] });
const rrow = (id, status) => ({ table: 'runs', key: `${id}/1`, fields: { task_id: id, run_generation: 1, backend: 'tmux', worktree: '/wt', harness: 'codex', ...(status ? { status } : {}) }, provenance: { task_id: 's' }, unresolved: [] });
const erow = (id, type) => ({ table: 'task_events', key: `${id}#${type}`, fields: { task_id: id, event_scope: 'run', run_generation: 1, producer_id: 'crewmate', event_type: type, payload_json: {} }, provenance: { task_id: 's' }, unresolved: [] });

function makeReport(dispositions) {
  const mapped = dispositions.filter((d) => d.disposition === 'mapped').length;
  const flagged = dispositions.filter((d) => d.disposition === 'flagged').length;
  return { schema: REPORT_SCHEMA, posture: 'x', legacy_home: '/fixture/legacy', sources: [], stores: [], totals: { discovered: dispositions.length, mapped, flagged, reconciles: true }, flags_by_reason: { unmappable: 0, ambiguous: 0, duplicate: 0 }, records: dispositions, human_summary: 'x' };
}
function writeJson(obj, name = 'report.json') {
  const p = path.join(mkTempDir('cp-cw1-in-'), name);
  fs.writeFileSync(p, `${JSON.stringify(obj, null, 2)}\n`);
  return p;
}
async function initStore() {
  const dataDir = path.join(mkTempDir('cp-cw1-store-'), 'pgdata');
  await runVerb(['init', '--data-dir', dataDir], { env: {} });
  return dataDir;
}
async function q(dataDir, sql, params) {
  const store = new PgliteLocalStore({ dataDir });
  try { return await readOnlyQuery(store, sql, params); } finally { await store.close(); }
}
async function taskStatus(dataDir, id) {
  const rows = await q(dataDir, 'SELECT status FROM tasks WHERE task_id = $1', [id]);
  return rows.length ? rows[0].status : null;
}
async function counts(dataDir) {
  const store = new PgliteLocalStore({ dataDir });
  try {
    const present = async (t) => (await readOnlyQuery(store, "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name=$1", [t])).length > 0;
    const num = async (t) => (await present(t)) ? Number((await readOnlyQuery(store, `SELECT count(*)::int n FROM ${t}`))[0].n) : 0;
    return { tasks: await num('tasks'), runs: await num('runs'), events: await num('task_events'), receipts: await num('migration_receipts') };
  } finally { await store.close(); }
}

// A mixed report exercising every current-state class.
function mixedReport() {
  return makeReport([
    // in-flight (running) with a HISTORICAL done line at L2 then later working at L10.
    md('state-meta', 'state/live.meta', [trow({ task_id: 'live', kind: 'ship' }), rrow('live')], { kind: 'ship', worktree: '/wt' }),
    md('backlog', 'bk#live', [trow({ task_id: 'live', title: 'Live', status: 'running' })], { line: '- [ ] live - Live (kind: ship)', section: 'In flight' }),
    md('state-status', 'state/live.status#L2', [erow('live', 'completed')], { line: 'done: earlier' }),
    md('state-status', 'state/live.status#L10', [erow('live', 'progress')], { line: 'working: later' }),
    // completed
    md('state-meta', 'state/done.meta', [trow({ task_id: 'done', kind: 'ship' }), rrow('done')], { kind: 'ship' }),
    md('backlog', 'bk#done', [trow({ task_id: 'done', title: 'Done', status: 'completed' })], { line: '- [x] done - Done (kind: ship)', section: 'Done' }),
    // failed
    md('task-runs', 'trn#fail', [rrow('fail', 'failed')], { task: 'fail', kind: 'scout' }),
    // queued (kind harvested from the backlog line)
    md('backlog', 'bk#q', [trow({ task_id: 'q', title: 'Q', status: 'queued' })], { line: '- [ ] q - Q (kind: ship)', section: 'Queued' }),
    // archived -> residual, never created
    md('done-archive', 'arch#old', [trow({ task_id: 'old', title: 'Old', status: 'archived' })], { line: '- [x] old - Old (kind: ship)', section: 'Archived' }),
    fl('state-turn-ended', 'state/x.turn-ended', 'unmappable', 'turn marker')
  ]);
}

// =====================================================================================
// Finding 2: chronology + current state
// =====================================================================================

test('ordinalOf reads the numeric #L line number, not the lexical ref', () => {
  assert.equal(ordinalOf({ source_ref: 'state/a.status#L2', source: { value: {} } }), 2);
  assert.equal(ordinalOf({ source_ref: 'state/a.status#L10', source: { value: {} } }), 10);
  assert.equal(ordinalOf({ source_ref: 'x#L10', source: {} }) > ordinalOf({ source_ref: 'x#L2', source: {} }), true, 'L10 orders AFTER L2 (numeric, not lexical)');
});

test('deriveCurrentState uses the authoritative current signal; LIVE backlog WINS over archive', () => {
  const tasks = assembleTasks(mixedReport());
  assert.equal(deriveCurrentState(tasks.get('live')), 'running');   // In flight despite a historical done line
  assert.equal(deriveCurrentState(tasks.get('done')), 'completed');
  assert.equal(deriveCurrentState(tasks.get('fail')), 'failed');
  assert.equal(deriveCurrentState(tasks.get('q')), 'queued');
  assert.equal(deriveCurrentState(tasks.get('old')), 'archived');
  // F2: a task on the live backlog AND in done-archive is current, not archived.
  const react = assembleTasks(makeReport([
    md('done-archive', 'arch#r', [trow({ task_id: 'r', title: 'R', status: 'archived' })], { line: '- [x] r - R (kind: ship)', section: 'Archived' }),
    md('backlog', 'bk#r', [trow({ task_id: 'r', title: 'R', status: 'queued' })], { line: '- [ ] r - R (kind: ship)', section: 'Queued' })
  ])).get('r');
  assert.equal(deriveCurrentState(react), 'queued');
});

test('a historical terminal followed by later activity lands at the LATER state, terminal residualized', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  await runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: out, allowResidualOver: 60, env: {} });
  // live is currently in-flight -> lands queued (NOT completed from its historical done line).
  assert.equal(await taskStatus(dataDir, 'live'), 'queued');
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  const byRef = Object.fromEntries(residual.residual.map((r) => [r.source_ref, r]));
  assert.ok(/superseded|CW2/.test(byRef['state/live.status#L2'].reason));
});

// =====================================================================================
// Finding 4 / ruling Q1b: no fabricated runs for current work
// =====================================================================================

test('a migrated in-flight task materializes QUEUED with NO run row (not a reconcile candidate)', async () => {
  const dataDir = await initStore();
  await runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: path.join(mkTempDir('o-'), 'r.json'), allowResidualOver: 60, env: {} });
  assert.equal(await taskStatus(dataDir, 'live'), 'queued');
  // The in-flight task has NO run, so nothing for the reconciler to time out.
  const liveRuns = Number((await q(dataDir, "SELECT count(*)::int n FROM runs r JOIN tasks t ON t.task_id=r.task_id WHERE t.task_id='live'"))[0].n);
  assert.equal(liveRuns, 0);
  // No migrated run is ever bound_verified/open.
  const bad = Number((await q(dataDir, "SELECT count(*)::int n FROM runs WHERE binding_state='bound_verified' AND status='open'"))[0].n);
  assert.equal(bad, 0);
});

test('F1 regression: a real cp reconcile after the launch window elapsed causes ZERO migrated-current terminal failures', async () => {
  const dataDir = await initStore();
  // Many in-flight tasks (each would have terminal-failed via an expired spawning deadline
  // under the old run-fabricating path) plus a completed and a failed task.
  const dispositions = [];
  for (let i = 0; i < 8; i += 1) dispositions.push(md('backlog', `bk#f${i}`, [trow({ task_id: `f${i}`, title: `F${i}`, status: 'running' })], { line: `- [ ] f${i} - F (kind: ship)`, section: 'In flight' }));
  dispositions.push(md('backlog', 'bk#dn', [trow({ task_id: 'dn', title: 'D', status: 'completed' })], { line: '- [x] dn - D (kind: ship)', section: 'Done' }));
  dispositions.push(md('task-runs', 'trn#fl', [rrow('fl', 'failed')], { task: 'fl', kind: 'scout' }));
  await runMigrateApply({ reportPath: writeJson(makeReport(dispositions)), dataDir, outPath: path.join(mkTempDir('o-'), 'r.json'), allowResidualOver: 95, env: {} });

  const before = await q(dataDir, "SELECT count(*)::int n FROM tasks WHERE status='failed'");
  const store = new PgliteLocalStore({ dataDir });
  try {
    // A REAL reconcile pass with the deadline clock far past the launch window; injected
    // probes stand in for the (absent) live endpoints a production reconcile would also miss.
    await reconcilePass(store, {
      now: '2099-01-01T00:00:00.000Z', deadlineNow: '2099-01-01T00:00:00.000Z', nonce: 'cw1-f1-regression',
      probeIdentity: () => ({ matches: false, failingClause: 'migrated', anomalyClass: 'identity_mismatch' }),
      cleanupProbe: () => ({ present: false, matches: false, reason: 'absent' })
    });
  } finally { await store.close(); }
  const after = await q(dataDir, "SELECT count(*)::int n FROM tasks WHERE status='failed'");
  assert.equal(Number(after[0].n) - Number(before[0].n), 0, 'reconcile fabricated ZERO terminal failures on migrated current work');
  // The eight in-flight tasks are still queued, untouched by the reconciler.
  for (let i = 0; i < 8; i += 1) assert.equal(await taskStatus(dataDir, `f${i}`), 'queued');
});

// =====================================================================================
// Finding 1: truthful counts (archive residualized; post-commit verification)
// =====================================================================================

test('archived tasks are RESIDUALIZED, never created and never counted applied', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  await runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: out, allowResidualOver: 60, env: {} });
  assert.equal(await taskStatus(dataDir, 'old'), null, 'archived task not created');
  const archivedTasks = Number((await q(dataDir, "SELECT count(*)::int n FROM tasks WHERE status = 'archived'"))[0].n);
  assert.equal(archivedTasks, 0);
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  const arch = residual.residual.find((r) => r.source_ref === 'arch#old');
  assert.equal(arch.origin, 'executor');
  assert.match(arch.reason, /archived\/finished task/);
  assert.equal(residual.applied.some((a) => a.source_ref === 'arch#old'), false, 'archive record is NOT in applied');
});

test('F2: a task on the live backlog AND in done-archive is materialized (live wins), not residualized as archived', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  const report = makeReport([
    md('done-archive', 'arch#react', [trow({ task_id: 'react', title: 'R', status: 'archived' })], { line: '- [x] react - R (kind: ship)', section: 'Archived' }),
    md('backlog', 'bk#react', [trow({ task_id: 'react', title: 'R', status: 'queued' })], { line: '- [ ] react - R (kind: ship)', section: 'Queued' })
  ]);
  const receipt = await runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: out, allowResidualOver: 90, env: {} });
  assert.equal(await taskStatus(dataDir, 'react'), 'queued', 'reactivated task is current, not archived');
  assert.equal(receipt.reconciliation.live_surface_complete, true);
  // The live backlog record is applied; the historical archive duplicate is a superseded residual.
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(residual.applied.some((a) => a.source_ref === 'bk#react'), true);
});

test('F2 completeness GATE: a live In flight/Queued backlog task that ends fully residual is a HARD failure', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  // `nokind` is on the live In-flight backlog but has no resolvable kind -> fully residual ->
  // the live-surface gate must fail the whole run (same class as totality/ceiling).
  const report = makeReport([
    md('backlog', 'bk#nokind', [trow({ task_id: 'nokind', title: 'NK', status: 'running' })], { line: '- [ ] nokind - NK', section: 'In flight' }),
    md('state-meta', 'state/ok.meta', [trow({ task_id: 'ok', kind: 'ship' })], { kind: 'ship' }),
    md('backlog', 'bk#ok', [trow({ task_id: 'ok', title: 'OK', status: 'queued' })], { line: '- [ ] ok - OK (kind: ship)', section: 'Queued' })
  ]);
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: out, allowResidualOver: 95, env: {} }),
    (e) => e instanceof MigrateReconcileError
  );
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(residual.reconciliation.live_surface_complete, false);
  assert.deepEqual(residual.reconciliation.live_surface_violations, ['nokind']);
});

test('statusConsistent: a migrated in-flight (running) task lands queued; archived/terminal mismatch caught', () => {
  assert.equal(statusConsistent('running', 'queued'), true);   // F1: in-flight -> queued
  assert.equal(statusConsistent('running', 'spawning'), true);
  assert.equal(statusConsistent('completed', 'completed'), true);
  assert.equal(statusConsistent('archived', 'queued'), false);
  assert.equal(statusConsistent('completed', 'queued'), false);
  assert.equal(statusConsistent(undefined, 'queued'), true);
});

test('post-commit verification DOWNGRADES a record whose prescribed status is not committed', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  // Conflicting backlog rows: an In flight (running) bullet AND a Done (completed) bullet
  // for the same task. Current state is running -> the task lands queued, so the
  // completed-prescribing record must be downgraded to residual by verification.
  const report = makeReport([
    md('state-meta', 'state/z.meta', [trow({ task_id: 'z', kind: 'ship' }), rrow('z')], { kind: 'ship', worktree: '/wt' }),
    md('backlog', 'bk#z-flight', [trow({ task_id: 'z', title: 'Z', status: 'running' })], { line: '- [ ] z - Z (kind: ship)', section: 'In flight' }),
    md('backlog', 'bk#z-done', [trow({ task_id: 'z', title: 'Z', status: 'completed' })], { line: '- [x] z - Z (kind: ship)', section: 'Done' })
  ]);
  const receipt = await runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: out, allowResidualOver: 90, env: {} });
  assert.equal(await taskStatus(dataDir, 'z'), 'queued');
  assert.equal(receipt.reconciliation.downgraded_by_verification >= 1, true);
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  const downgraded = residual.residual.find((r) => r.source_ref === 'bk#z-done');
  assert.match(downgraded.reason, /prescribed status 'completed' not committed/);
});

// =====================================================================================
// Loud reconciliation
// =====================================================================================

test('reconciliation FAILS loudly when applied is zero (all archived/kind-less)', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  const report = makeReport([md('done-archive', 'arch#a', [trow({ task_id: 'a', title: 'A', status: 'archived' })], { line: '- [x] a - A (kind: ship)' })]);
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: out, allowResidualOver: 100, env: {} }),
    (e) => e instanceof MigrateReconcileError
  );
  assert.equal(JSON.parse(fs.readFileSync(out, 'utf8')).reconciliation.applied_nonzero, false);
});

test('reconciliation FAILS over the ceiling and PASSES when --allow-residual-over raises it', async () => {
  const dispositions = [
    md('state-meta', 'state/live.meta', [trow({ task_id: 'live', kind: 'ship' })], { kind: 'ship' }),
    md('backlog', 'bk#live', [trow({ task_id: 'live', title: 'L', status: 'queued' })], { line: '- [ ] live - L (kind: ship)', section: 'Queued' })
  ];
  for (const id of ['h1', 'h2', 'h3', 'h4']) dispositions.push(md('done-archive', `arch#${id}`, [trow({ task_id: id, title: id, status: 'archived' })], { line: `- [x] ${id} - ${id} (kind: ship)` }));
  const reportPath = writeJson(makeReport(dispositions));
  await assert.rejects(runMigrateApply({ reportPath, dataDir: await initStore(), outPath: path.join(mkTempDir('o-'), 'r.json'), allowResidualOver: 35, env: {} }), (e) => e instanceof MigrateReconcileError);
  const ok = await runMigrateApply({ reportPath, dataDir: await initStore(), outPath: path.join(mkTempDir('o-'), 'r.json'), allowResidualOver: 90, env: {} });
  assert.equal(ok.reconciliation.ok, true);
});

// =====================================================================================
// Finding 3: per-source-pointer+hash resume identity, incl. subsumed records
// =====================================================================================

test('loadReport enforces a strict source_ref bijection and a present source.digest', () => {
  const dup = mixedReport(); dup.records.push({ ...dup.records[0] }); dup.totals.discovered += 1; dup.totals.mapped += 1;
  assert.throws(() => loadReport(writeJson(dup)), (e) => e instanceof MigrateApplyError && /duplicate source_ref/.test(e.message));
  const noDigest = makeReport([{ store: 's', source_ref: 'r1', disposition: 'mapped', mapping: { canonical: [trow({ task_id: 't', kind: 'ship' })] }, source: { raw: 'r1' } }]);
  assert.throws(() => loadReport(writeJson(noDigest)), (e) => e instanceof MigrateApplyError && /missing source\.digest/.test(e.message));
});

test('a changed digest on a SUBSUMED (non-owner) record is reprocessed as NEW on resume, not falsely replayed', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  // Three task-proposal records for one queued task; the order record is a subsumed
  // non-owner (the meta owns create-task by smallest source_ref).
  const build = (orderDigest) => makeReport([
    md('state-meta', 'aaa.meta', [trow({ task_id: 'k2', kind: 'ship' })], { kind: 'ship' }),
    md('backlog', 'bbb#k2', [trow({ task_id: 'k2', title: 'K2', status: 'queued' })], { line: '- [ ] k2 - K2 (kind: ship)', section: 'Queued' }),
    { store: 'authoritative-orders', source_ref: 'ccc#k2', disposition: 'mapped', mapping: { canonical: [trow({ task_id: 'k2', task_origin: 'captain_order', order_ref: 'ORD-1' })] }, source: { digest: orderDigest, raw: 'ccc#k2', value: {} } }
  ]);
  await runMigrateApply({ reportPath: writeJson(build('digest-A')), dataDir, outPath: out, allowResidualOver: 50, env: {} });
  assert.equal((await counts(dataDir)).receipts, 3, 'every source record has its own receipt');

  // Resume with the SAME report: all three replay, nothing new.
  const same = await runMigrateApply({ reportPath: writeJson(build('digest-A')), dataDir, outPath: out, resume: true, allowResidualOver: 50, env: {} });
  assert.equal(same.reconciliation.applied_new, 0, 'unchanged resume applies nothing new');
  assert.equal(same.reconciliation.applied_replayed, 3);

  // Resume with the order record's digest CHANGED: its recordKey changes, so it is NOT in
  // the receipt ledger and is honestly reprocessed as new; the other two still replay.
  const changed = await runMigrateApply({ reportPath: writeJson(build('digest-B')), dataDir, outPath: out, resume: true, allowResidualOver: 50, env: {} });
  assert.equal(changed.reconciliation.applied_new, 1, 'the changed non-owner record is reprocessed as new');
  assert.equal(changed.reconciliation.applied_replayed, 2);
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  const rec = residual.applied.find((a) => a.source_ref === 'ccc#k2');
  assert.equal(rec.application, 'new');
});

test('a full rerun REFUSES without --resume and replays idempotently WITH --resume', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  const reportPath = writeJson(mixedReport());
  await runMigrateApply({ reportPath, dataDir, outPath: out, allowResidualOver: 60, env: {} });
  const first = await counts(dataDir);
  await assert.rejects(runMigrateApply({ reportPath, dataDir, outPath: out, allowResidualOver: 60, env: {} }), (e) => e instanceof MigrateApplyError && /already contains state/.test(e.message));
  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, resume: true, allowResidualOver: 60, env: {} });
  assert.equal(receipt.reconciliation.ok, true);
  assert.equal(receipt.reconciliation.applied_new, 0);
  assert.deepEqual(await counts(dataDir), first, 'resume created no new rows');
});

test('resumes idempotently after a REAL child crash mid-apply', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  const reportPath = writeJson(mixedReport());
  const worker = path.join(HERE, 'workers', 'crash-migrate-apply-writer.mjs');
  const crashed = spawnSync(process.execPath, [worker], { env: { ...process.env, CP_REPORT: reportPath, CP_DATA_DIR: dataDir, CP_OUT: out, CP_CRASH_AFTER: '1', CP_ALLOW: '60' }, encoding: 'utf8' });
  assert.equal(crashed.status, 42, 'child exited via the mid-apply crash');
  assert.equal(fs.existsSync(out), false, 'no residual written by the crashed run');
  assert.equal((await counts(dataDir)).tasks >= 1, true);
  await assert.rejects(runMigrateApply({ reportPath, dataDir, outPath: out, allowResidualOver: 60, env: {} }), (e) => e instanceof MigrateApplyError && /already contains state/.test(e.message));
  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, resume: true, allowResidualOver: 60, env: {} });
  assert.equal(receipt.reconciliation.ok, true);
  assert.equal(await taskStatus(dataDir, 'done'), 'completed');
});

// =====================================================================================
// Retained round-1 hardening
// =====================================================================================

test('a pre-populated target is REJECTED before any mutation, leaving it unchanged', async () => {
  const dataDir = await initStore();
  const store = new PgliteLocalStore({ dataDir });
  try { await createTask(store, { taskId: 'foreign-x', kind: 'ship', title: 'F', origin: 'internal', internalReason: 'seed', commandId: 'foreign-1' }); } finally { await store.close(); }
  const out = path.join(mkTempDir('o-'), 'r.json');
  await assert.rejects(runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: out, allowResidualOver: 100, env: {} }), (e) => e instanceof MigrateApplyError && /non-empty store without --resume/.test(e.message));
  assert.equal((await counts(dataDir)).tasks, 1, 'target unchanged');
  assert.equal(fs.existsSync(out), false, 'no report written on pre-mutation refusal');
});

test('--out is refused under the target store and under the report legacy_home (incl. symlinked ancestor)', async () => {
  const dataDir = await initStore();
  await assert.rejects(runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: path.join(dataDir, 'x.json'), env: {} }), (e) => e instanceof MigrateApplyError && /under the target store/.test(e.message));
  const legacy = mkTempDir('cp-cw1-legacy-');
  const report = mixedReport(); report.legacy_home = legacy;
  await assert.rejects(runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: path.join(legacy, 'ILLEGAL.json'), env: {} }), (e) => e instanceof MigrateApplyError && /under the legacy home/.test(e.message));
  const alias = path.join(mkTempDir('cp-cw1-alias-'), 'link');
  fs.symlinkSync(legacy, alias);
  await assert.rejects(runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: path.join(alias, 'ILLEGAL.json'), env: {} }), (e) => e instanceof MigrateApplyError && /under the legacy home/.test(e.message));
});

test('the read seam rejects non-SELECT shapes and blocks any mutation at the database', async () => {
  assert.throws(() => assertSelectShape('UPDATE tasks SET x = 1'), /only SELECT/);
  const dataDir = await initStore();
  const store = new PgliteLocalStore({ dataDir });
  try {
    await assert.rejects(readOnlyQuery(store, 'UPDATE coordinator_state SET domain_revision = 999'), /only SELECT/);
    await assert.rejects(readOnlyQuery(store, "WITH x AS (UPDATE coordinator_state SET domain_revision = 1 RETURNING 1) SELECT * FROM x"), /read-only transaction/);
    assert.equal(Number((await readOnlyQuery(store, 'SELECT count(*)::int AS n FROM coordinator_state'))[0].n), 1);
  } finally { await store.close(); }
});

test('verb-only writes: owner guard clean; executor imports no raw connection seam and no raw domain INSERT', () => {
  assert.deepEqual(findViolations(), []);
  const src = fs.readFileSync(path.join(HERE, '..', 'lib', 'migrate-apply.mjs'), 'utf8');
  assert.doesNotMatch(src, /INSERT\s+INTO\s+(tasks|runs|task_events|command_results)/i);
  assert.doesNotMatch(src, /from '\.\/internal-runtime\.mjs'/, 'executor reaches reads only through the SELECT-only seam');
});

// =====================================================================================
// End-to-end against a REAL migrate-report; legacy stores byte-identical
// =====================================================================================

function hashTree(root) {
  const h = crypto.createHash('sha256');
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir).sort()) {
      const p = path.join(dir, name); const st = fs.statSync(p);
      if (st.isDirectory()) { h.update(`D:${name}\n`); walk(p); } else { h.update(`F:${path.relative(root, p)}:${fs.readFileSync(p)}\n`); }
    }
  };
  walk(root);
  return h.digest('hex');
}

test('end-to-end: real migrate-report -> migrate-apply; live task lands queued; legacy untouched', async () => {
  const home = mkTempDir('cp-cw1-legacy-');
  const state = path.join(home, 'state'); const data = path.join(home, 'data');
  fs.mkdirSync(state, { recursive: true }); fs.mkdirSync(data, { recursive: true });
  fs.writeFileSync(path.join(state, 'eps.meta'), 'window=fm:fm-eps\nworktree=/wt/eps\nproject=/home/x/fleet/bridge\nharness=codex\nkind=ship\n');
  fs.writeFileSync(path.join(state, 'eps.status'), 'working: started\npaused: waiting on review\n');
  fs.writeFileSync(path.join(data, 'backlog.md'), ['# backlog', '', '## In flight', '- [ ] eps - Do epsilon (repo: bridge) (kind: ship)', ''].join('\n'));
  const ordersPath = path.join(mkTempDir('cp-cw1-orders-'), 'captain-orders.jsonl');
  fs.writeFileSync(ordersPath, `${JSON.stringify({ schema: 'firstmate/captain-order/v1', order_id: 'ORD-EPS', event: 'link', status: 'received', linked_task_ids: ['eps'] })}\n`);
  const reportPath = path.join(mkTempDir('cp-cw1-rep-'), 'report.json');
  const { report } = runMigrateReport({ home, ordersPath, outPath: reportPath, env: {} });
  assert.equal(report.totals.reconciles, true);
  const legacyBefore = hashTree(home);
  const dataDir = await initStore();
  const out = path.join(mkTempDir('o-'), 'r.json');
  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, allowResidualOver: 70, env: {} });
  assert.equal(receipt.reconciliation.ok, true);
  // eps is in-flight -> lands queued with no run (not a fake terminal, not a reconcile candidate).
  assert.equal(await taskStatus(dataDir, 'eps'), 'queued');
  assert.equal(hashTree(home), legacyBefore, 'legacy home byte-identical across apply');
});
