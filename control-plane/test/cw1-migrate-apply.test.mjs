import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runVerb } from '../lib/coordinator.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { createTask } from '../lib/domain-store.mjs';
import {
  runMigrateApply, loadReport, assembleTasks, planApply, RESIDUAL_SCHEMA
} from '../lib/migrate-apply.mjs';
import { runMigrateReport } from '../lib/migrate-report.mjs';
import { REPORT_SCHEMA } from '../lib/migrate-report.mjs';
import { MigrateApplyError, MigrateReconcileError } from '../lib/errors-cw1.mjs';
import { findViolations } from '../scripts/check-no-direct-pglite.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// CW1 migrate-apply: the MIGRATION EXECUTOR. It turns the S8 migrate-report's `mapped`
// proposals into real control-plane records through the landed cp verbs ONLY, echoes
// everything it does not apply to a residual report (never guessed at), and proves a
// built-in reconciliation (applied + residual === mapped + flagged; store counts match
// the applied proposals; a post-apply snapshot succeeds). This suite proves: verb-only
// writes (a raw-SQL bypass is statically impossible and would leave an untraced task),
// idempotent resume across a REAL child crash mid-apply, refuse-without-resume, totality
// reconciliation, legacy read-only by construction, and correct flagging of the
// run/terminal/non-queued/unassemblable records the create-only path cannot legally reach.
after(cleanupAll);

const HERE = path.dirname(fileURLToPath(import.meta.url));

function digestOf(raw) { return crypto.createHash('sha256').update(raw).digest('hex'); }

// A disposition in exactly the shape lib/migrate-map.mjs emits.
function mappedDisp(store, sourceRef, canonical) {
  return {
    store, source_ref: sourceRef, disposition: 'mapped',
    mapping: { canonical },
    source: { digest: digestOf(sourceRef), raw: sourceRef, value: {} }
  };
}
function flaggedDisp(store, sourceRef, reason, detail) {
  return {
    store, source_ref: sourceRef, disposition: 'flagged',
    flag: { reason, detail },
    source: { digest: digestOf(sourceRef), raw: sourceRef, value: {} }
  };
}
function taskRow(fields) { return { table: 'tasks', key: fields.task_id, fields, provenance: { task_id: 's' }, unresolved: [] }; }
function runRow(taskId) { return { table: 'runs', key: `${taskId}/1`, fields: { task_id: taskId, run_generation: 1, backend: 'tmux', worktree: '/wt' }, provenance: { task_id: 's' }, unresolved: [] }; }
function eventRow(taskId, ref) { return { table: 'task_events', key: ref, fields: { task_id: taskId, event_scope: 'run', run_generation: 1, producer_id: 'crewmate', event_type: 'progress', payload_json: {} }, provenance: { task_id: 's' }, unresolved: [] }; }

// Wrap dispositions into a valid S8 report with correct, reconciling totals.
function makeReport(dispositions, extra = {}) {
  const mapped = dispositions.filter((d) => d.disposition === 'mapped').length;
  const flagged = dispositions.filter((d) => d.disposition === 'flagged').length;
  const discovered = dispositions.length;
  return {
    schema: REPORT_SCHEMA,
    posture: 'read-only shadow read',
    legacy_home: '/fixture/home',
    sources: [],
    stores: [],
    totals: { discovered, mapped, flagged, reconciles: true },
    flags_by_reason: { unmappable: 0, ambiguous: 0, duplicate: 0 },
    records: dispositions,
    human_summary: 'fixture',
    ...extra
  };
}

// A three-record, fully-assemblable, QUEUED, order-linked task: meta (kind), backlog
// (title + queued), order (captain_order link). These three JOIN into one legal
// create-task, and create-task fires exactly once (the other two replay by command-id).
function assemblableQueuedTask(id, orderRef) {
  return [
    mappedDisp('state-meta', `state/${id}.meta`, [taskRow({ task_id: id, kind: 'ship', repo: 'bridge' })]),
    mappedDisp('backlog', `data/backlog.md#${id}`, [taskRow({ task_id: id, title: `Do ${id}`, repo: 'bridge', status: 'queued' })]),
    mappedDisp('authoritative-orders', `orders.jsonl#${id}`, [taskRow({ task_id: id, task_origin: 'captain_order', order_ref: orderRef })])
  ];
}

// The canonical mixed fixture: two assemblable queued tasks + records the create-only
// path cannot legally reach (a run-bearing meta, a non-queued in-flight bullet, a
// run-scoped event) + report-flagged records that must be echoed straight through.
function mixedReport() {
  const dispositions = [
    ...assemblableQueuedTask('alpha-q1', 'ORD-100'),
    ...assemblableQueuedTask('beta-q2', 'ORD-200'),
    // run-bearing meta -> flagged (run unreachable), but still contributes kind to gamma.
    mappedDisp('state-meta', 'state/gamma-r3.meta', [taskRow({ task_id: 'gamma-r3', kind: 'ship' }), runRow('gamma-r3')]),
    // a fully-identified but IN-FLIGHT (non-queued) task: kind (meta) + title/running
    // (backlog) resolve, so ineligibility is decided on the live status, not a missing field.
    mappedDisp('state-meta', 'state/delta-run4.meta', [taskRow({ task_id: 'delta-run4', kind: 'ship' })]),
    mappedDisp('backlog', 'data/backlog.md#delta', [taskRow({ task_id: 'delta-run4', title: 'Live delta', status: 'running' })]),
    // run-scoped event -> flagged (needs an open run generation).
    mappedDisp('state-status', 'state/alpha-q1.status', [eventRow('alpha-q1', 'state/alpha-q1.status#L1')]),
    // report-flagged echoes:
    flaggedDisp('state-turn-ended', 'state/alpha-q1.turn-ended', 'unmappable', 'turn-boundary marker has no canonical target'),
    flaggedDisp('authoritative-orders', 'orders.jsonl#dup', 'duplicate', 'identical order event already seen'),
    flaggedDisp('task-lifecycle', 'state/task-lifecycle.jsonl#L9', 'unmappable', 'malformed JSON')
  ];
  return makeReport(dispositions);
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
async function counts(dataDir) {
  const store = new PgliteLocalStore({ dataDir });
  try {
    return runExclusive(store, async (conn) => {
      const t = Number((await conn.query('SELECT count(*)::int AS n FROM tasks')).rows[0].n);
      const r = Number((await conn.query('SELECT count(*)::int AS n FROM runs')).rows[0].n);
      const e = Number((await conn.query('SELECT count(*)::int AS n FROM task_events')).rows[0].n);
      const cr = Number((await conn.query("SELECT count(*)::int AS n FROM command_results WHERE command_id LIKE 'migrate-apply:%'")).rows[0].n);
      return { tasks: t, runs: r, events: e, migrateCommands: cr };
    });
  } finally {
    await store.close();
  }
}

// =====================================================================================
// Planning (pure)
// =====================================================================================

test('assembleTasks JOINs proposals: an eligible task needs kind + title + queued + order', () => {
  const report = mixedReport();
  const asm = assembleTasks(report);
  assert.equal(asm.get('alpha-q1').eligible, true);
  assert.equal(asm.get('alpha-q1').kind, 'ship');
  assert.equal(asm.get('alpha-q1').title, 'Do alpha-q1');
  assert.equal(asm.get('alpha-q1').orderRef, 'ORD-100');
  // gamma has kind (from the run-bearing meta) but no title/queued/order -> ineligible.
  assert.equal(asm.get('gamma-r3').eligible, false);
  assert.match(asm.get('gamma-r3').reason, /title unresolved/);
  // delta is a live in-flight task -> ineligible on the non-queued status.
  assert.equal(asm.get('delta-run4').eligible, false);
  assert.match(asm.get('delta-run4').reason, /live\/terminal state/);
});

test('planApply dispositions: runs/events/non-queued/unassemblable all flag; only tasks-only+eligible apply', () => {
  const report = mixedReport();
  const plan = planApply(report);
  const appliedRefs = plan.apply.map((a) => a.source_ref).sort();
  assert.deepEqual(appliedRefs, [
    'data/backlog.md#alpha-q1', 'data/backlog.md#beta-q2',
    'orders.jsonl#alpha-q1', 'orders.jsonl#beta-q2',
    'state/alpha-q1.meta', 'state/beta-q2.meta'
  ]);
  const flagReasons = Object.fromEntries(plan.flag.map((f) => [f.source_ref, f.reason]));
  assert.match(flagReasons['state/gamma-r3.meta'], /live endpoint/);
  assert.match(flagReasons['data/backlog.md#delta'], /live\/terminal state/);
  assert.match(flagReasons['state/alpha-q1.status'], /open run generation/);
});

// =====================================================================================
// Report validation
// =====================================================================================

test('loadReport refuses a malformed / non-reconciling / wrong-schema report', () => {
  assert.throws(() => loadReport(writeJson({ nope: true })), (e) => e instanceof MigrateApplyError && /not a control-plane\/migrate-report/.test(e.message));
  const bad = mixedReport(); bad.totals.reconciles = false;
  assert.throws(() => loadReport(writeJson(bad)), (e) => e instanceof MigrateApplyError && /reconciles is not true/.test(e.message));
  const miscount = mixedReport(); miscount.totals.mapped += 1;
  assert.throws(() => loadReport(writeJson(miscount)), (e) => e instanceof MigrateApplyError && /does not reconcile/.test(e.message));
  assert.throws(() => loadReport('/no/such/report.json'), (e) => e instanceof MigrateApplyError && /could not be read/.test(e.message));
});

test('migrate-apply refuses an uninitialized target store', async () => {
  const dataDir = path.join(mkTempDir('cp-cw1-noinit-'), 'pgdata');
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: out, env: {} }),
    (e) => e instanceof MigrateApplyError && /not initialized/.test(e.message)
  );
});

test('migrate-apply refuses an --out that resolves under the target store', async () => {
  const dataDir = await initStore();
  const badOut = path.join(dataDir, 'residual.json');
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: badOut, env: {} }),
    (e) => e instanceof MigrateApplyError && /resolves under the target store/.test(e.message)
  );
});

// =====================================================================================
// Apply + reconciliation
// =====================================================================================

test('apply materializes exactly the eligible queued tasks and reconciles totality + counts + snapshot', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const report = mixedReport();
  const receipt = await runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: out, env: {} });

  // 6 mapped records applied (3 per task), 2 distinct tasks created.
  assert.equal(receipt.applied, 6);
  assert.equal(receipt.applied_tasks, 2);
  // residual = 3 report-flagged + 4 executor-flagged mapped (gamma-meta, delta-meta,
  // delta-backlog, alpha-status) = 7.
  assert.equal(receipt.residual, 7);

  const rec = receipt.reconciliation;
  assert.equal(rec.ok, true);
  assert.equal(rec.totality_holds, true);
  assert.equal(rec.applied_plus_residual, report.totals.mapped + report.totals.flagged);
  assert.deepEqual(rec.store_counts, { tasks: 2, runs: 0, task_events: 2 });
  assert.deepEqual(rec.expected_counts, { tasks: 2, runs: 0, task_events: 2 });
  assert.equal(rec.counts_match, true);
  assert.equal(rec.verb_only_writes, true);
  assert.deepEqual(rec.untraced_tasks, []);
  assert.equal(rec.snapshot_ok, true);
  assert.ok(Number.isInteger(rec.snapshot_revision));

  // Store truly holds exactly the applied proposals, every task carrying a migrate command.
  assert.deepEqual(await counts(dataDir), { tasks: 2, runs: 0, events: 2, migrateCommands: 2 });

  // Residual report: schema, echoed report-flags, executor flags with precise reasons.
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(residual.schema, RESIDUAL_SCHEMA);
  assert.equal(residual.totals.echoed_flagged, 3);
  assert.equal(residual.totals.executor_flagged, 4);
  assert.deepEqual(residual.applied_task_ids, ['alpha-q1', 'beta-q2']);
  const byRef = Object.fromEntries(residual.residual.map((r) => [r.source_ref, r]));
  assert.equal(byRef['state/alpha-q1.turn-ended'].origin, 'report');
  assert.equal(byRef['state/gamma-r3.meta'].origin, 'executor');
  assert.match(byRef['state/gamma-r3.meta'].reason, /live endpoint/);
});

test('the CLI verb path (sanctioned registration) drives the same apply', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const outcome = await runVerb(
    ['migrate-apply', '--report', writeJson(mixedReport()), '--data-dir', dataDir, '--out', out],
    { env: {} }
  );
  assert.equal(outcome.ok, true);
  assert.equal(outcome.result.applied_tasks, 2);
  assert.equal(outcome.result.reconciliation.ok, true);
});

// =====================================================================================
// Idempotent resume
// =====================================================================================

test('a full rerun REFUSES without --resume and is idempotent WITH --resume', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const reportPath = writeJson(mixedReport());

  await runMigrateApply({ reportPath, dataDir, outPath: out, env: {} });
  const first = await counts(dataDir);

  // Second run without --resume: refused (prior migration state present).
  await assert.rejects(
    runMigrateApply({ reportPath, dataDir, outPath: out, env: {} }),
    (e) => e instanceof MigrateApplyError && /already holds applied migration state/.test(e.message)
  );

  // With --resume: every create-task replays by command-id; no new rows.
  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, resume: true, env: {} });
  assert.equal(receipt.resumed, true);
  assert.equal(receipt.reconciliation.ok, true);
  assert.deepEqual(await counts(dataDir), first, 'resume created no duplicate rows');
});

test('resumes idempotently after a REAL child crash mid-apply', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const reportPath = writeJson(mixedReport());
  const worker = path.join(HERE, 'workers', 'crash-migrate-apply-writer.mjs');

  // Child applies exactly ONE task then hard-exits(42) before the run finishes.
  const crashed = spawnSync(process.execPath, [worker], {
    env: { ...process.env, CP_REPORT: reportPath, CP_DATA_DIR: dataDir, CP_OUT: out, CP_CRASH_AFTER: '1' },
    encoding: 'utf8'
  });
  assert.equal(crashed.status, 42, 'child exited via the mid-apply crash');
  assert.equal(fs.existsSync(out), false, 'no residual report was written by the crashed run');
  const mid = await counts(dataDir);
  assert.equal(mid.tasks, 1, 'exactly one task durably committed before the crash');
  assert.equal(mid.migrateCommands, 1);

  // A rerun WITHOUT --resume must refuse (the store already holds applied migration state).
  await assert.rejects(
    runMigrateApply({ reportPath, dataDir, outPath: out, env: {} }),
    (e) => e instanceof MigrateApplyError && /already holds applied migration state/.test(e.message)
  );

  // --resume replays the committed task and finishes the rest, reconciling.
  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, resume: true, env: {} });
  assert.equal(receipt.reconciliation.ok, true);
  assert.deepEqual(await counts(dataDir), { tasks: 2, runs: 0, events: 2, migrateCommands: 2 });
});

test('a duplicate source-pointer / repeated proposal for one task creates it exactly once', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  // Two IDENTICAL extra proposals for alpha (same source_ref) on top of the assemblable set.
  const dup = mappedDisp('backlog', 'data/backlog.md#alpha-q1', [taskRow({ task_id: 'alpha-q1', title: 'Do alpha-q1', repo: 'bridge', status: 'queued' })]);
  const report = makeReport([...assemblableQueuedTask('alpha-q1', 'ORD-100'), dup, dup]);
  const receipt = await runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: out, env: {} });
  assert.equal(receipt.applied, 5, 'all five proposals count as applied');
  assert.equal(receipt.applied_tasks, 1, 'but exactly one task is created');
  assert.deepEqual(await counts(dataDir), { tasks: 1, runs: 0, events: 1, migrateCommands: 1 });
  assert.equal(receipt.reconciliation.ok, true);
});

// =====================================================================================
// Verb-only writes / raw-SQL bypass impossible
// =====================================================================================

test('verb-only writes: owner guard forbids PGlite outside the engine, and no raw domain INSERT exists', () => {
  // Static owner guard covers the whole repo incl. the new CW1 modules.
  assert.deepEqual(findViolations(), []);
  // The executor issues NO raw INSERT into a domain table - writes go through createTask.
  const src = fs.readFileSync(path.join(HERE, '..', 'lib', 'migrate-apply.mjs'), 'utf8');
  assert.doesNotMatch(src, /INSERT\s+INTO\s+(tasks|runs|task_events|command_results)/i);
  assert.match(src, /createTask\(store,/);
});

test('reconciliation fails LOUDLY (and still writes the audit report) when store counts do not match', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  // Pre-seed an out-of-band task the report does NOT account for, so the store's task
  // count (3) will not match the applied proposals (2). This is NOT migration state (a
  // foreign command-id), so the apply still proceeds - and then the built-in count
  // reconciliation catches the discrepancy.
  const store = new PgliteLocalStore({ dataDir });
  try {
    await createTask(store, { taskId: 'foreign-x', kind: 'ship', title: 'Foreign', origin: 'internal', internalReason: 'seed', commandId: 'foreign-cmd-1' });
  } finally {
    await store.close();
  }

  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: out, env: {} }),
    (e) => e instanceof MigrateReconcileError && /reconciliation failed/.test(e.message)
  );
  // The audit report was still written before the loud failure.
  assert.equal(fs.existsSync(out), true);
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(residual.reconciliation.ok, false);
  assert.equal(residual.reconciliation.counts_match, false);
  assert.equal(residual.reconciliation.totality_holds, true, 'totality still holds; only counts mismatched');
});

// =====================================================================================
// Legacy read-only + end-to-end against a REAL migrate-report
// =====================================================================================

function hashTree(root) {
  const h = crypto.createHash('sha256');
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir).sort()) {
      const p = path.join(dir, name);
      const st = fs.statSync(p);
      if (st.isDirectory()) { h.update(`D:${name}\n`); walk(p); }
      else { h.update(`F:${path.relative(root, p)}:${fs.readFileSync(p)}\n`); }
    }
  };
  walk(root);
  return h.digest('hex');
}

test('end-to-end: real migrate-report -> migrate-apply, legacy stores byte-identical across the apply', async () => {
  // A minimal legacy home with one fully-assemblable queued task (eps-q1): a meta (kind,
  // and a worktree so its own record flags on the run), a Queued backlog bullet (title +
  // queued), and an authoritative order event linking it.
  const home = mkTempDir('cp-cw1-legacy-');
  const state = path.join(home, 'state');
  const data = path.join(home, 'data');
  fs.mkdirSync(state, { recursive: true });
  fs.mkdirSync(data, { recursive: true });
  fs.writeFileSync(path.join(state, 'eps-q1.meta'), 'window=fm:fm-eps\nworktree=/wt/eps\nproject=/home/x/fleet/bridge\nharness=codex\nkind=ship\n');
  fs.writeFileSync(path.join(data, 'backlog.md'), ['# backlog', '', '## Queued', '- [ ] eps-q1 - Do epsilon (repo: bridge)', ''].join('\n'));
  const ordersDir = mkTempDir('cp-cw1-orders-');
  const ordersPath = path.join(ordersDir, 'captain-orders.jsonl');
  fs.writeFileSync(ordersPath, JSON.stringify({ schema: 'firstmate/captain-order/v1', order_id: 'ORD-EPS', event: 'complete', status: 'completed', linked_task_ids: ['eps-q1'] }) + '\n');

  const reportPath = path.join(mkTempDir('cp-cw1-rep-'), 'report.json');
  const { report } = runMigrateReport({ home, ordersPath, outPath: reportPath, env: {} });
  assert.equal(report.schema, REPORT_SCHEMA);
  assert.equal(report.totals.reconciles, true);

  const legacyBefore = hashTree(home);
  const ordersBefore = fs.readFileSync(ordersPath);

  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, env: {} });

  // eps-q1 was created; the run-bearing meta record was flagged, backlog+order applied.
  assert.equal(receipt.applied_tasks, 1);
  assert.equal(receipt.reconciliation.ok, true);
  assert.deepEqual(await counts(dataDir), { tasks: 1, runs: 0, events: 1, migrateCommands: 1 });
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.deepEqual(residual.applied_task_ids, ['eps-q1']);
  assert.ok(residual.residual.some((r) => /eps-q1\.meta/.test(r.source_ref) && /live endpoint/.test(r.reason)));

  // Legacy stores are strictly read-only: the executor never opened them.
  assert.equal(hashTree(home), legacyBefore, 'legacy home byte-identical across apply');
  assert.deepEqual(fs.readFileSync(ordersPath), ordersBefore, 'authoritative order ledger byte-identical across apply');
});
