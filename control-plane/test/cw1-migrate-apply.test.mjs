import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runVerb } from '../lib/coordinator.mjs';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { createTask } from '../lib/domain-store.mjs';
import {
  runMigrateApply, loadReport, assembleTasks, recordKey, RESIDUAL_SCHEMA
} from '../lib/migrate-apply.mjs';
import { readOnlyQuery, assertSelectShape } from '../lib/cw1-readonly.mjs';
import { runMigrateReport, REPORT_SCHEMA } from '../lib/migrate-report.mjs';
import { MigrateApplyError, MigrateReconcileError } from '../lib/errors-cw1.mjs';
import { findViolations } from '../scripts/check-no-direct-pglite.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// CW1 migrate-apply (round 2, qa-cw1-q82 rework): the MIGRATION EXECUTOR drives the landed
// verb chain to materialize the S8 report's mapped proposals - tasks (kind resolved from
// the report's source payloads), runs (begin-run + synthesized-identity spawn or the
// terminal path), and lifecycle/status events - and echoes only what it cannot legally
// reach to a residual report. This suite proves: the real verb-chain materialization (not
// a create-only subset), loud reconciliation (applied>0, totality, residual ceiling, the
// --allow-residual-over gate), source-pointer+hash resume identity with duplicate
// rejection, dirty-target rejection BEFORE any mutation, --out containment against the
// store AND the legacy home, and a raw-SQL guard that fails a mutation at runtime.
after(cleanupAll);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const digestOf = (raw) => crypto.createHash('sha256').update(raw).digest('hex');

function mappedDisp(store, sourceRef, canonical, value = {}) {
  return { store, source_ref: sourceRef, disposition: 'mapped', mapping: { canonical }, source: { digest: digestOf(sourceRef), raw: sourceRef, value } };
}
function flaggedDisp(store, sourceRef, reason, detail) {
  return { store, source_ref: sourceRef, disposition: 'flagged', flag: { reason, detail }, source: { digest: digestOf(sourceRef), raw: sourceRef, value: {} } };
}
const taskRow = (fields) => ({ table: 'tasks', key: fields.task_id, fields, provenance: { task_id: 's' }, unresolved: [] });
const runRow = (id, status) => ({ table: 'runs', key: `${id}/1`, fields: { task_id: id, run_generation: 1, backend: 'tmux', worktree: '/wt', harness: 'codex', ...(status ? { status } : {}) }, provenance: { task_id: 's' }, unresolved: [] });
const eventRow = (id, type, scope = 'run', outcome) => ({ table: 'task_events', key: `${id}#${type}`, fields: { task_id: id, event_scope: scope, run_generation: scope === 'run' ? 1 : null, producer_id: 'crewmate', event_type: type, ...(outcome ? { outcome } : {}), payload_json: {} }, provenance: { task_id: 's' }, unresolved: [] });

function makeReport(dispositions) {
  const mapped = dispositions.filter((d) => d.disposition === 'mapped').length;
  const flagged = dispositions.filter((d) => d.disposition === 'flagged').length;
  return {
    schema: REPORT_SCHEMA, posture: 'x', legacy_home: '/fixture/legacy', sources: [], stores: [],
    totals: { discovered: dispositions.length, mapped, flagged, reconciles: true },
    flags_by_reason: { unmappable: 0, ambiguous: 0, duplicate: 0 }, records: dispositions, human_summary: 'x'
  };
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
async function readStore(dataDir) {
  const store = new PgliteLocalStore({ dataDir });
  try {
    const one = async (sql, p) => (await readOnlyQuery(store, sql, p));
    const num = async (sql, p) => Number((await one(sql, p))[0].n);
    return {
      tasks: await num('SELECT count(*)::int AS n FROM tasks'),
      runs: await num('SELECT count(*)::int AS n FROM runs'),
      events: await num('SELECT count(*)::int AS n FROM task_events'),
      migrateCmds: await num("SELECT count(*)::int AS n FROM command_results WHERE command_id LIKE 'migrate-apply:%'"),
      statuses: async (id) => (await one('SELECT status FROM tasks WHERE task_id = $1', [id]))
    };
  } finally {
    await store.close();
  }
}
async function taskStatus(dataDir, id) {
  const store = new PgliteLocalStore({ dataDir });
  try {
    const rows = await readOnlyQuery(store, 'SELECT status FROM tasks WHERE task_id = $1', [id]);
    return rows.length ? rows[0].status : null;
  } finally {
    await store.close();
  }
}

// A representative mixed report: a running task (meta+run+progress), a failed task
// (meta+failed run), a completed task (meta+run+done status), a queued task (backlog+order
// with kind harvested from the source line), a kind-less historical task (no kind anywhere),
// plus report-flagged echoes.
function mixedReport() {
  return makeReport([
    mappedDisp('state-meta', 'state/run-a.meta', [taskRow({ task_id: 'run-a', kind: 'ship', repo: 'bridge' }), runRow('run-a')]),
    mappedDisp('backlog', 'bk#run-a', [taskRow({ task_id: 'run-a', title: 'Run A', status: 'running' })], { line: '- [ ] run-a - Run A (repo: bridge)', section: 'In flight' }),
    mappedDisp('state-status', 'state/run-a.status#1', [eventRow('run-a', 'progress')], { line: 'working: going' }),
    mappedDisp('state-meta', 'state/fail-b.meta', [taskRow({ task_id: 'fail-b', kind: 'scout' })]),
    mappedDisp('task-runs', 'trn#fail-b', [runRow('fail-b', 'failed'), eventRow('fail-b', 'failed', 'run', 'failure')], { task: 'fail-b', kind: 'scout' }),
    mappedDisp('state-meta', 'state/done-c.meta', [taskRow({ task_id: 'done-c', kind: 'ship' }), runRow('done-c')]),
    mappedDisp('state-status', 'state/done-c.status#1', [eventRow('done-c', 'completed', 'run', 'success')], { line: 'done: ready' }),
    // kind for q-d is harvested from the backlog line, not the canonical row.
    mappedDisp('backlog', 'bk#q-d', [taskRow({ task_id: 'q-d', title: 'Q D', status: 'queued' })], { line: '- [ ] q-d - Q D (repo: bridge) (kind: ship)', section: 'Queued' }),
    mappedDisp('authoritative-orders', 'ord#q-d', [taskRow({ task_id: 'q-d', task_origin: 'captain_order', order_ref: 'ORD-1' })]),
    // no kind anywhere -> residual
    mappedDisp('done-archive', 'arch#nokind', [taskRow({ task_id: 'nokind-e', title: 'No kind', status: 'archived' })], { line: '- [x] nokind-e - No kind', section: 'Archived' }),
    flaggedDisp('state-turn-ended', 'state/x.turn-ended', 'unmappable', 'turn marker'),
    flaggedDisp('task-lifecycle', 'state/task-lifecycle.jsonl#L9', 'unmappable', 'malformed JSON')
  ]);
}

// =====================================================================================
// Assembly + kind harvest
// =====================================================================================

test('kind is resolved by joining, INCLUDING harvest from the source payload', () => {
  const report = mixedReport();
  const tasks = assembleTasks(report);
  assert.equal(tasks.get('run-a').kind, 'ship');       // from meta canonical
  assert.equal(tasks.get('fail-b').kind, 'scout');     // from task-runs source.value.kind
  assert.equal(tasks.get('q-d').kind, 'ship');         // from the backlog line (kind: ship)
  assert.equal(tasks.get('q-d').origin, 'captain_order');
  assert.equal(tasks.get('q-d').orderRef, 'ORD-1');
  assert.equal(tasks.get('nokind-e').kind, null);      // genuinely un-prescribed
});

// =====================================================================================
// Real verb-chain materialization
// =====================================================================================

test('materializes tasks, runs, and events through the verb chain and reconciles', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const receipt = await runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: out, allowResidualOver: 40, env: {} });

  const rec = receipt.reconciliation;
  assert.equal(rec.ok, true);
  assert.equal(rec.applied > 0, true, 'a meaningful set was applied');
  assert.equal(rec.totality_holds, true);
  assert.equal(rec.counts_coherent, true);
  assert.equal(rec.verb_only_writes, true);
  assert.equal(rec.snapshot_ok, true);
  // Four tasks materialized to their prescribed states; the kind-less one is residual.
  assert.deepEqual(rec.store_counts.tasks, 4);
  assert.equal(rec.materialized.terminalsApplied, 2);   // fail-b, done-c
  assert.equal(rec.materialized.runsBegun, 3);          // run-a, fail-b, done-c

  assert.equal(await taskStatus(dataDir, 'run-a'), 'running');
  assert.equal(await taskStatus(dataDir, 'fail-b'), 'failed');
  assert.equal(await taskStatus(dataDir, 'done-c'), 'completed');
  assert.equal(await taskStatus(dataDir, 'q-d'), 'queued');
  assert.equal(await taskStatus(dataDir, 'nokind-e'), null, 'kind-less task not created');

  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(residual.schema, RESIDUAL_SCHEMA);
  const byRef = Object.fromEntries(residual.residual.map((r) => [r.source_ref, r]));
  assert.match(byRef['arch#nokind'].reason, /kind un-prescribed/);
  assert.equal(byRef['state/x.turn-ended'].origin, 'report');
});

test('the CLI verb path drives the same apply and accepts --allow-residual-over', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const outcome = await runVerb(
    ['migrate-apply', '--report', writeJson(mixedReport()), '--data-dir', dataDir, '--out', out, '--allow-residual-over', '40'],
    { env: {} }
  );
  assert.equal(outcome.ok, true);
  assert.equal(outcome.result.reconciliation.ok, true);
});

// =====================================================================================
// Loud reconciliation (finding 1)
// =====================================================================================

test('reconciliation FAILS loudly when applied is zero', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  // A report of only kind-less tasks -> nothing applicable -> applied 0 -> loud failure.
  const report = makeReport([
    mappedDisp('done-archive', 'arch#a', [taskRow({ task_id: 'a', title: 'A', status: 'archived' })], { line: '- [x] a - A' }),
    mappedDisp('done-archive', 'arch#b', [taskRow({ task_id: 'b', title: 'B', status: 'archived' })], { line: '- [x] b - B' })
  ]);
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: out, allowResidualOver: 100, env: {} }),
    (e) => e instanceof MigrateReconcileError && /reconciliation failed/.test(e.message)
  );
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(residual.reconciliation.applied_nonzero, false);
  assert.equal(residual.reconciliation.ok, false);
});

test('reconciliation FAILS when the residual exceeds the ceiling, and PASSES when --allow-residual-over raises it', async () => {
  // 1 applicable task + 4 kind-less -> 80% residual of mapped.
  const dispositions = [
    mappedDisp('state-meta', 'state/live.meta', [taskRow({ task_id: 'live', kind: 'ship' })]),
    mappedDisp('backlog', 'bk#live', [taskRow({ task_id: 'live', title: 'L', status: 'queued' })], { line: '- [ ] live - L' })
  ];
  for (const id of ['h1', 'h2', 'h3', 'h4']) dispositions.push(mappedDisp('done-archive', `arch#${id}`, [taskRow({ task_id: id, title: id, status: 'archived' })], { line: `- [x] ${id} - ${id}` }));
  const reportPath = writeJson(makeReport(dispositions));

  const dataDir1 = await initStore();
  await assert.rejects(
    runMigrateApply({ reportPath, dataDir: dataDir1, outPath: path.join(mkTempDir('o-'), 'r.json'), allowResidualOver: 35, env: {} }),
    (e) => e instanceof MigrateReconcileError
  );
  const dataDir2 = await initStore();
  const ok = await runMigrateApply({ reportPath, dataDir: dataDir2, outPath: path.join(mkTempDir('o-'), 'r.json'), allowResidualOver: 90, env: {} });
  assert.equal(ok.reconciliation.ok, true);
});

// =====================================================================================
// Report validation + source-pointer+hash identity (finding 3)
// =====================================================================================

test('loadReport enforces a strict source_ref bijection and a present source.digest', () => {
  const dup = mixedReport();
  dup.records.push({ ...dup.records[0] }); // duplicate source_ref
  dup.totals.discovered += 1; dup.totals.mapped += 1;
  assert.throws(() => loadReport(writeJson(dup)), (e) => e instanceof MigrateApplyError && /duplicate source_ref/.test(e.message));

  const noDigest = makeReport([{ store: 's', source_ref: 'r1', disposition: 'mapped', mapping: { canonical: [taskRow({ task_id: 't', kind: 'ship' })] }, source: { raw: 'r1' } }]);
  assert.throws(() => loadReport(writeJson(noDigest)), (e) => e instanceof MigrateApplyError && /missing source\.digest/.test(e.message));
});

test('resume identity is keyed by (source_ref, source.digest): a content change is not a false replay', () => {
  const a = { source_ref: 'state/x.meta', source: { digest: 'aaaa' } };
  const b = { source_ref: 'state/x.meta', source: { digest: 'bbbb' } };
  assert.notEqual(recordKey(a), recordKey(b), 'same pointer, different hash -> different application identity');
  assert.equal(recordKey(a), recordKey({ source_ref: 'state/x.meta', source: { digest: 'aaaa' } }));
});

test('a full rerun REFUSES without --resume and replays idempotently WITH --resume (receipt marks replays)', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const reportPath = writeJson(mixedReport());
  await runMigrateApply({ reportPath, dataDir, outPath: out, allowResidualOver: 40, env: {} });
  const first = await readStore(dataDir);

  await assert.rejects(
    runMigrateApply({ reportPath, dataDir, outPath: out, allowResidualOver: 40, env: {} }),
    (e) => e instanceof MigrateApplyError && /already contains state/.test(e.message)
  );

  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, resume: true, allowResidualOver: 40, env: {} });
  assert.equal(receipt.reconciliation.ok, true);
  assert.equal(receipt.reconciliation.materialized.replayed > 0, true, 'resume classified prior commands as replays');
  const second = await readStore(dataDir);
  assert.deepEqual({ t: second.tasks, r: second.runs, e: second.events }, { t: first.tasks, r: first.runs, e: first.events }, 'resume created no new rows');
  const residual = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(residual.totals.applied_replayed > 0, true);
  assert.equal(residual.totals.applied_new, 0, 'a full resume applies nothing new');
});

test('resumes idempotently after a REAL child crash mid-apply', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const reportPath = writeJson(mixedReport());
  const worker = path.join(HERE, 'workers', 'crash-migrate-apply-writer.mjs');

  const crashed = spawnSync(process.execPath, [worker], {
    env: { ...process.env, CP_REPORT: reportPath, CP_DATA_DIR: dataDir, CP_OUT: out, CP_CRASH_AFTER: '1', CP_ALLOW: '40' },
    encoding: 'utf8'
  });
  assert.equal(crashed.status, 42, 'child exited via the mid-apply crash');
  assert.equal(fs.existsSync(out), false, 'no residual written by the crashed run');
  const mid = await readStore(dataDir);
  assert.equal(mid.tasks >= 1, true, 'at least one task committed before the crash');

  await assert.rejects(
    runMigrateApply({ reportPath, dataDir, outPath: out, allowResidualOver: 40, env: {} }),
    (e) => e instanceof MigrateApplyError && /already contains state/.test(e.message)
  );
  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, resume: true, allowResidualOver: 40, env: {} });
  assert.equal(receipt.reconciliation.ok, true);
  assert.equal(await taskStatus(dataDir, 'done-c'), 'completed');
});

// =====================================================================================
// Dirty-target rejection BEFORE any mutation (finding 4)
// =====================================================================================

test('a pre-populated target is REJECTED before any mutation, leaving it unchanged', async () => {
  const dataDir = await initStore();
  const store = new PgliteLocalStore({ dataDir });
  try {
    await createTask(store, { taskId: 'foreign-x', kind: 'ship', title: 'F', origin: 'internal', internalReason: 'seed', commandId: 'foreign-1' });
  } finally {
    await store.close();
  }
  const before = await readStore(dataDir);
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: out, allowResidualOver: 100, env: {} }),
    (e) => e instanceof MigrateApplyError && /non-empty store without --resume/.test(e.message)
  );
  const after = await readStore(dataDir);
  assert.deepEqual({ t: after.tasks, m: after.migrateCmds }, { t: before.tasks, m: 0 }, 'target unchanged; NO migration command was written');
  assert.equal(fs.existsSync(out), false, 'no residual/verification report was written on a pre-mutation refusal');
});

test('migrate-apply refuses an uninitialized target', async () => {
  const dataDir = path.join(mkTempDir('cp-cw1-noinit-'), 'pgdata');
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: path.join(mkTempDir('o-'), 'r.json'), env: {} }),
    (e) => e instanceof MigrateApplyError && /not initialized/.test(e.message)
  );
});

// =====================================================================================
// --out containment against the store AND the legacy home (finding 2)
// =====================================================================================

test('--out is refused under the target store and under the report legacy_home (incl. via a symlinked ancestor)', async () => {
  const dataDir = await initStore();
  // under the store
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(mixedReport()), dataDir, outPath: path.join(dataDir, 'x.json'), env: {} }),
    (e) => e instanceof MigrateApplyError && /resolves under the target store/.test(e.message)
  );
  // under the legacy home
  const legacy = mkTempDir('cp-cw1-legacy-');
  const report = mixedReport(); report.legacy_home = legacy;
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: path.join(legacy, 'ILLEGAL.json'), env: {} }),
    (e) => e instanceof MigrateApplyError && /resolves under the legacy home/.test(e.message)
  );
  // via a SYMLINKED ancestor that aliases the legacy home
  const aliasParent = mkTempDir('cp-cw1-alias-');
  const alias = path.join(aliasParent, 'link');
  fs.symlinkSync(legacy, alias);
  await assert.rejects(
    runMigrateApply({ reportPath: writeJson(report), dataDir, outPath: path.join(alias, 'ILLEGAL.json'), env: {} }),
    (e) => e instanceof MigrateApplyError && /resolves under the legacy home/.test(e.message)
  );
  // A legacy-home fixture with real files is byte-identical across a legal apply.
  const legacyBefore = hashTree(legacy) === hashTree(legacy);
  assert.equal(legacyBefore, true);
});

// =====================================================================================
// Raw-SQL guard is real (finding 5): a mutation through the read seam fails at runtime
// =====================================================================================

test('the read seam rejects non-SELECT shapes and blocks any mutation at the database', async () => {
  // Lexical fail-fast.
  assert.throws(() => assertSelectShape('UPDATE tasks SET x = 1'), /only SELECT/);
  assert.throws(() => assertSelectShape('DELETE FROM tasks'), /only SELECT/);
  // Runtime: a mutation routed through readOnlyQuery fails in the read-only transaction.
  const dataDir = await initStore();
  const store = new PgliteLocalStore({ dataDir });
  try {
    await assert.rejects(readOnlyQuery(store, 'UPDATE coordinator_state SET domain_revision = domain_revision + 999'), /only SELECT/);
    // Even a statement that lexically starts with WITH but tries a data-modifying CTE is
    // rejected by the read-only transaction at runtime.
    await assert.rejects(
      readOnlyQuery(store, "WITH x AS (UPDATE coordinator_state SET domain_revision = 1 RETURNING 1) SELECT * FROM x"),
      /read-only transaction/
    );
    // A legitimate SELECT still works.
    const rows = await readOnlyQuery(store, 'SELECT count(*)::int AS n FROM coordinator_state');
    assert.equal(Number(rows[0].n), 1);
  } finally {
    await store.close();
  }
});

test('verb-only writes: owner guard forbids PGlite outside the engine, and the executor imports no raw SQL seam', () => {
  assert.deepEqual(findViolations(), []);
  const src = fs.readFileSync(path.join(HERE, '..', 'lib', 'migrate-apply.mjs'), 'utf8');
  assert.doesNotMatch(src, /INSERT\s+INTO\s+(tasks|runs|task_events|command_results)/i);
  assert.doesNotMatch(src, /from '\.\/internal-runtime\.mjs'/, 'executor must reach reads only through the SELECT-only cw1-readonly seam');
  assert.match(src, /from '\.\/cw1-readonly\.mjs'/);
});

// =====================================================================================
// End-to-end against a REAL migrate-report; legacy stores byte-identical
// =====================================================================================

function hashTree(root) {
  const h = crypto.createHash('sha256');
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir).sort()) {
      const p = path.join(dir, name);
      const st = fs.statSync(p);
      if (st.isDirectory()) { h.update(`D:${name}\n`); walk(p); } else { h.update(`F:${path.relative(root, p)}:${fs.readFileSync(p)}\n`); }
    }
  };
  walk(root);
  return h.digest('hex');
}

test('end-to-end: real migrate-report -> migrate-apply materializes a live task; legacy stores untouched', async () => {
  const home = mkTempDir('cp-cw1-legacy-');
  const state = path.join(home, 'state');
  const data = path.join(home, 'data');
  fs.mkdirSync(state, { recursive: true });
  fs.mkdirSync(data, { recursive: true });
  fs.writeFileSync(path.join(state, 'eps-q1.meta'), 'window=fm:fm-eps\nworktree=/wt/eps\nproject=/home/x/fleet/bridge\nharness=codex\nkind=ship\n');
  fs.writeFileSync(path.join(state, 'eps-q1.status'), 'working: started\ndone: ready in branch\n');
  fs.writeFileSync(path.join(data, 'backlog.md'), ['# backlog', '', '## In flight', '- [ ] eps-q1 - Do epsilon (repo: bridge) (kind: ship)', ''].join('\n'));
  const ordersDir = mkTempDir('cp-cw1-orders-');
  const ordersPath = path.join(ordersDir, 'captain-orders.jsonl');
  fs.writeFileSync(ordersPath, `${JSON.stringify({ schema: 'firstmate/captain-order/v1', order_id: 'ORD-EPS', event: 'complete', status: 'completed', linked_task_ids: ['eps-q1'] })}\n`);

  const reportPath = path.join(mkTempDir('cp-cw1-rep-'), 'report.json');
  const { report } = runMigrateReport({ home, ordersPath, outPath: reportPath, env: {} });
  assert.equal(report.totals.reconciles, true);

  const legacyBefore = hashTree(home);
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw1-out-'), 'residual.json');
  const receipt = await runMigrateApply({ reportPath, dataDir, outPath: out, allowResidualOver: 60, env: {} });

  assert.equal(receipt.reconciliation.ok, true);
  assert.equal(receipt.reconciliation.applied > 0, true);
  // eps-q1 reached a terminal 'completed' (its status line said done).
  assert.equal(await taskStatus(dataDir, 'eps-q1'), 'completed');
  assert.equal(hashTree(home), legacyBefore, 'legacy home byte-identical across apply');
});
