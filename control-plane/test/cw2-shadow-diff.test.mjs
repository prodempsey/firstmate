import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { runVerb } from '../lib/coordinator.mjs';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runMigrateApply } from '../lib/migrate-apply.mjs';
import { runMigrateBackfill } from '../lib/migrate-backfill.mjs';
import { REPORT_SCHEMA } from '../lib/migrate-report.mjs';
import { expectedFromReport, diffAgainstStore } from '../lib/shadow-diff.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// CW2 Part B(1) - the DIVERGENCE MONITOR (shadow-diff). Proves the diff engine's
// correctness on fixtures: it translates a regenerated mapper report through the ratified
// CW1 classification and reports missing / mismatched / extra live tasks plus archived
// history that is deferred vs back-filled, reading the store ONLY (no writes). The engine is
// exercised against a REAL store materialized by the CW1 executor, so the "legacy truth" it
// expects and the store's actual materialization are produced by the same landed code.
after(cleanupAll);

const digestOf = (raw) => crypto.createHash('sha256').update(raw).digest('hex');
function md(store, sourceRef, canonical, value = {}) {
  return { store, source_ref: sourceRef, disposition: 'mapped', mapping: { canonical }, source: { digest: digestOf(sourceRef), raw: sourceRef, value } };
}
const trow = (fields) => ({ table: 'tasks', key: fields.task_id, fields, provenance: { task_id: 's' }, unresolved: [] });
const rrow = (id, status) => ({ table: 'runs', key: `${id}/1`, fields: { task_id: id, run_generation: 1, backend: 'tmux', worktree: '/wt', harness: 'codex', ...(status ? { status } : {}) }, provenance: { task_id: 's' }, unresolved: [] });
function makeReport(dispositions) {
  const mapped = dispositions.filter((d) => d.disposition === 'mapped').length;
  const flagged = dispositions.filter((d) => d.disposition === 'flagged').length;
  return { schema: REPORT_SCHEMA, posture: 'x', legacy_home: '/fixture/legacy', sources: [], stores: [], totals: { discovered: dispositions.length, mapped, flagged, reconciles: true }, flags_by_reason: { unmappable: 0, ambiguous: 0, duplicate: 0 }, records: dispositions, human_summary: 'x' };
}
function writeJson(obj, name = 'report.json') {
  const p = path.join(mkTempDir('cp-cw2-in-'), name);
  fs.writeFileSync(p, `${JSON.stringify(obj, null, 2)}\n`);
  return p;
}
async function initStore() {
  const dataDir = path.join(mkTempDir('cp-cw2-diff-'), 'pgdata');
  await runVerb(['init', '--data-dir', dataDir], { env: {} });
  return dataDir;
}
async function withStore(dataDir, fn) {
  const store = new PgliteLocalStore({ dataDir });
  try { return await fn(store); } finally { await store.close(); }
}

// A report with a queued task, a completed task, and an archived (done-archive) task.
function baseReport() {
  return makeReport([
    md('backlog', 'bk#q', [trow({ task_id: 'q', title: 'Q', status: 'queued' })], { line: '- [ ] q - Q (kind: ship)', section: 'Queued' }),
    md('state-meta', 'state/done.meta', [trow({ task_id: 'done', kind: 'ship' }), rrow('done')], { kind: 'ship' }),
    md('backlog', 'bk#done', [trow({ task_id: 'done', title: 'Done', status: 'completed' })], { line: '- [x] done - Done (kind: ship)', section: 'Done' }),
    md('done-archive', 'arch#old', [trow({ task_id: 'old', title: 'Old', status: 'archived' })], { line: '- [x] old - Old (kind: ship)', section: 'Archived' })
  ]);
}

test('expectedFromReport classifies live (running->queued) vs archived history per CW1', () => {
  const report = makeReport([
    md('backlog', 'bk#q', [trow({ task_id: 'q', title: 'Q', status: 'queued' })], { line: '- [ ] q - Q (kind: ship)', section: 'Queued' }),
    md('state-meta', 'state/live.meta', [trow({ task_id: 'live', kind: 'ship' }), rrow('live')], { kind: 'ship', worktree: '/wt' }),
    md('backlog', 'bk#live', [trow({ task_id: 'live', title: 'Live', status: 'running' })], { line: '- [ ] live (kind: ship)', section: 'In flight' }),
    md('done-archive', 'arch#old', [trow({ task_id: 'old', title: 'Old', status: 'archived' })], { line: '- [x] old (kind: ship)', section: 'Archived' })
  ]);
  const { live, archived } = expectedFromReport(report);
  assert.equal(live.get('q').expected_status, 'queued');
  assert.equal(live.get('live').expected_status, 'queued', 'a running task expects the CW1 queued materialization');
  assert.equal(live.get('live').derived, 'running');
  assert.equal(archived.has('old'), true);
  assert.equal(live.has('old'), false);
});

test('a store materialized from the SAME report has zero live divergence; archived is deferred then back-filled', async () => {
  const dataDir = await initStore();
  const residualOut = path.join(mkTempDir('cp-cw2-res-'), 'residual.json');
  await runMigrateApply({ reportPath: writeJson(baseReport()), dataDir, outPath: residualOut, allowResidualOver: 90, env: {} });

  // Before back-fill: live surface matches, archived history deferred.
  let core = await withStore(dataDir, (s) => diffAgainstStore(baseReport(), s));
  assert.equal(core.totals.missing, 0);
  assert.equal(core.totals.mismatched, 0);
  assert.equal(core.totals.extra, 0);
  assert.equal(core.totals.archived_deferred, 1, 'the archived task is deferred (not yet back-filled)');
  assert.equal(core.totals.archived_backfilled, 0);
  assert.equal(core.ok, true, 'live surface OK even with archived history deferred');
  assert.equal(core.divergence.archived_deferred[0].task_id, 'old');

  // Back-fill the archived history, then it moves from deferred to back-filled.
  const bfOut = path.join(mkTempDir('cp-cw2-bf-'), 'bf.json');
  await runMigrateBackfill({ residualPath: residualOut, dataDir, outPath: bfOut, env: {} });
  core = await withStore(dataDir, (s) => diffAgainstStore(baseReport(), s));
  assert.equal(core.totals.archived_deferred, 0);
  assert.equal(core.totals.archived_backfilled, 1);
  assert.equal(core.divergence.archived_backfilled[0].task_id, 'old');
  assert.equal(core.ok, true);
});

test('MISSING: a live task the report expects but the store lacks is reported missing', async () => {
  const dataDir = await initStore();
  const residualOut = path.join(mkTempDir('cp-cw2-res-'), 'residual.json');
  // Materialize the base report (no task 'extra-q').
  await runMigrateApply({ reportPath: writeJson(baseReport()), dataDir, outPath: residualOut, allowResidualOver: 90, env: {} });
  // Diff a report that additionally expects a queued task 'extra-q'.
  const withExtra = makeReport([
    ...baseReport().records,
    md('backlog', 'bk#extra-q', [trow({ task_id: 'extra-q', title: 'Extra', status: 'queued' })], { line: '- [ ] extra-q (kind: ship)', section: 'Queued' })
  ]);
  withExtra.totals = { discovered: withExtra.records.length, mapped: withExtra.records.length, flagged: 0, reconciles: true };
  const core = await withStore(dataDir, (s) => diffAgainstStore(withExtra, s));
  assert.equal(core.totals.missing, 1);
  assert.equal(core.divergence.missing[0].task_id, 'extra-q');
  assert.equal(core.divergence.missing[0].expected_status, 'queued');
  assert.equal(core.ok, false);
});

test('MISMATCHED: a store status differing from the expected status is reported mismatched', async () => {
  const dataDir = await initStore();
  const residualOut = path.join(mkTempDir('cp-cw2-res-'), 'residual.json');
  // Materialize 'done' as completed.
  await runMigrateApply({ reportPath: writeJson(baseReport()), dataDir, outPath: residualOut, allowResidualOver: 90, env: {} });
  // Diff a report where 'done' is instead a currently-queued backlog task.
  const requeued = makeReport([
    md('backlog', 'bk#q', [trow({ task_id: 'q', title: 'Q', status: 'queued' })], { line: '- [ ] q (kind: ship)', section: 'Queued' }),
    md('backlog', 'bk#done', [trow({ task_id: 'done', title: 'Done', status: 'queued' })], { line: '- [ ] done (kind: ship)', section: 'Queued' })
  ]);
  const core = await withStore(dataDir, (s) => diffAgainstStore(requeued, s));
  const m = core.divergence.mismatched.find((x) => x.task_id === 'done');
  assert.ok(m, 'done is mismatched');
  assert.equal(m.expected_status, 'queued');
  assert.equal(m.actual_status, 'completed');
  assert.equal(core.ok, false);
});

test('EXTRA: a live store task the report does not classify live is reported extra', async () => {
  const dataDir = await initStore();
  const residualOut = path.join(mkTempDir('cp-cw2-res-'), 'residual.json');
  await runMigrateApply({ reportPath: writeJson(baseReport()), dataDir, outPath: residualOut, allowResidualOver: 90, env: {} });
  // Diff a report WITHOUT task 'q'.
  const withoutQ = makeReport([
    md('state-meta', 'state/done.meta', [trow({ task_id: 'done', kind: 'ship' }), rrow('done')], { kind: 'ship' }),
    md('backlog', 'bk#done', [trow({ task_id: 'done', title: 'Done', status: 'completed' })], { line: '- [x] done (kind: ship)', section: 'Done' })
  ]);
  const core = await withStore(dataDir, (s) => diffAgainstStore(withoutQ, s));
  const e = core.divergence.extra.find((x) => x.task_id === 'q');
  assert.ok(e, 'q is extra (present in store, not classified live by the report)');
  assert.equal(e.actual_status, 'queued');
});

test('shadow-diff writes nothing to the store (read-only)', async () => {
  const dataDir = await initStore();
  const residualOut = path.join(mkTempDir('cp-cw2-res-'), 'residual.json');
  await runMigrateApply({ reportPath: writeJson(baseReport()), dataDir, outPath: residualOut, allowResidualOver: 90, env: {} });
  const before = await withStore(dataDir, async (s) => (await diffAgainstStore(baseReport(), s)).store);
  const after = await withStore(dataDir, async (s) => (await diffAgainstStore(baseReport(), s)).store);
  assert.deepEqual(after, before, 'store counts are unchanged by running the diff twice');
});
