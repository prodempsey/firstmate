import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { runVerb } from '../lib/coordinator.mjs';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { readOnlyQuery } from '../lib/cw1-readonly.mjs';
import { runMigrateApply, RESIDUAL_SCHEMA } from '../lib/migrate-apply.mjs';
import { REPORT_SCHEMA } from '../lib/migrate-report.mjs';
import {
  runMigrateBackfill, classifyRecordClass, classifyRecord, buildHistoryEntry, loadResidual, BACKFILL_RESIDUAL_SCHEMA
} from '../lib/migrate-backfill.mjs';
import { loadArchivedHistory } from '../lib/cw2-archived-history.mjs';
import { createSnapshot, getSnapshot } from '../lib/domain-store-s6.mjs';
import { BackfillError } from '../lib/errors-cw2.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// CW2 Part B(2) - the ARCHIVED-HISTORY BACK-FILL (migrate-backfill). Proves:
//  * totality vs the CW1 residual - every archived-history record is imported OR flagged;
//  * the documented decision that live-path synthesis is forbidden is realized - the import
//    writes ONLY the distinct audit-only archived_history table and NEVER a task/run/event/
//    outbox/consumer row (no faked live-path events, no fabricated runs);
//  * read-only legacy discipline - the input is the residual FILE; no legacy store is read;
//  * idempotency - a second run replays and never duplicates.
after(cleanupAll);

const digestOf = (raw) => crypto.createHash('sha256').update(raw).digest('hex');

const DONE_ARCHIVE_REASON = 'archived/finished task with no live-backlog membership: the terminal-delivery + ack + cleanup + archive chain is deferred to the named CW2 archive back-fill stage; not materialized into the live control plane in CW1';
const MULTI_GEN_REASON = 'historical/additional run generation superseded by the current state (single-generation collapse); retained for CW2 history back-fill';
const ARCHIVE_EVENT_REASON = 'task-scope archived event needs the acked-terminal + cleanup archive chain (S4/S3 live path) not reconstructed in CW1';
const IN_FLIGHT_REDISPATCH_REASON = 'migrated in-flight backlog task materialized queued (no live endpoint captured); its run/event history is not replayed as a live run in CW1 - retained for CW2 re-dispatch/back-fill';

function residualRecord({ sourceRef, store, reason, canonical, value = {} }) {
  return { source_ref: sourceRef, store, origin: 'executor', reason, canonical: canonical ?? [], source: { digest: digestOf(sourceRef), raw: sourceRef, value } };
}

function residualDoc(records, { legacyHome = '/fixture/legacy' } = {}) {
  return {
    schema: RESIDUAL_SCHEMA,
    posture: 'x',
    source_report: '/fixture/s8.json',
    source_report_schema: REPORT_SCHEMA,
    legacy_home: legacyHome,
    data_dir: '/fixture/store',
    resumed: false,
    totals: {},
    reconciliation: {},
    applied: [],
    residual: records
  };
}

function writeResidual(doc) {
  const p = path.join(mkTempDir('cp-cw2-bfin-'), 'residual.json');
  fs.writeFileSync(p, `${JSON.stringify(doc, null, 2)}\n`);
  return p;
}
async function initStore() {
  const dataDir = path.join(mkTempDir('cp-cw2-bf-'), 'pgdata');
  await runVerb(['init', '--data-dir', dataDir], { env: {} });
  return dataDir;
}
async function q(dataDir, sql, params) {
  const store = new PgliteLocalStore({ dataDir });
  try { return await readOnlyQuery(store, sql, params); } finally { await store.close(); }
}
async function tablePresent(dataDir, t) {
  return (await q(dataDir, "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name=$1", [t])).length > 0;
}

// A fixture residual covering all three archived-history classes plus records the predicate
// must EXCLUDE (an in-flight re-dispatch record, and an unrelated flag).
function mixedResidual() {
  return residualDoc([
    residualRecord({
      sourceRef: 'state/finished-a.status#L1', store: 'state-status', reason: DONE_ARCHIVE_REASON,
      canonical: [{ table: 'task_events', key: 'state/finished-a.status#L1', fields: { task_id: 'finished-a', event_scope: 'run', run_generation: 1, event_type: 'progress' } }],
      value: { line: 'working: x' }
    }),
    residualRecord({
      sourceRef: 'state/gen-b.meta', store: 'state-meta', reason: MULTI_GEN_REASON,
      canonical: [
        { table: 'tasks', key: 'gen-b', fields: { task_id: 'gen-b', kind: 'ship', repo: 'fleet-bridge' } },
        { table: 'runs', key: 'gen-b/1', fields: { task_id: 'gen-b', run_generation: 1, backend: 'tmux', harness: 'codex' } }
      ],
      value: { harness: 'codex' }
    }),
    residualRecord({
      sourceRef: 'state/task-lifecycle.jsonl#L3', store: 'task-lifecycle', reason: ARCHIVE_EVENT_REASON,
      canonical: [{ table: 'task_events', key: 'evt-c', fields: { task_id: 'closed-c', event_scope: 'task', event_type: 'archived', producer_id: 'firstmate', event_id: 'evt-c' } }],
      value: { id: 'closed-c', event: 'closed', closed_at: '2026-07-13T00:20:31.364Z', outcome: 'landed' }
    }),
    // EXCLUDED: an in-flight re-dispatch record (live work, not archived history).
    residualRecord({ sourceRef: 'state/inflight-d.meta', store: 'state-meta', reason: IN_FLIGHT_REDISPATCH_REASON, canonical: [{ table: 'tasks', key: 'inflight-d', fields: { task_id: 'inflight-d' } }], value: {} }),
    // EXCLUDED: an unrelated flag.
    residualRecord({ sourceRef: 'state/x.turn-ended', store: 'state-turn-ended', reason: 'unmappable: turn-boundary marker has no canonical target', canonical: [], value: { marker: true } })
  ]);
}

// =====================================================================================
// Pure classification + extraction
// =====================================================================================

test('classifyRecordClass matches only the three archived-history reasons', () => {
  assert.equal(classifyRecordClass(DONE_ARCHIVE_REASON), 'done_archive');
  assert.equal(classifyRecordClass(MULTI_GEN_REASON), 'multi_gen');
  assert.equal(classifyRecordClass(ARCHIVE_EVENT_REASON), 'archive_event');
  assert.equal(classifyRecordClass(IN_FLIGHT_REDISPATCH_REASON), null, 'in-flight re-dispatch is NOT archived history');
  assert.equal(classifyRecordClass('unmappable: turn-boundary marker'), null);
  assert.equal(classifyRecordClass(undefined), null);
});

test('classifyRecord is shape-aware: done-archive STORE and task-scope archived EVENTS are captured regardless of reason (finding 3)', () => {
  // A done-archive LEDGER row whose reason is NOT the accepted no-live-membership string is
  // still archived history (this is exactly the 84 QA found silently dropped).
  assert.equal(classifyRecord({ store: 'done-archive', reason: 'kind un-prescribed (no state-meta/lifecycle/ledger record supplies a kind)', canonical: [{ table: 'tasks', fields: { task_id: 't' } }] }), 'done_archive');
  assert.equal(classifyRecord({ store: 'done-archive', reason: "prescribed status 'archived' not committed (store status 'queued')", canonical: [{ table: 'tasks', fields: { task_id: 't' } }] }), 'done_archive');
  // A task-scope archived lifecycle event, by canonical SHAPE, even without the reason string.
  assert.equal(classifyRecord({ store: 'task-lifecycle', reason: 'some other reason', canonical: [{ fields: { event_scope: 'task', event_type: 'archived', task_id: 't' } }] }), 'archive_event');
  // An in-flight re-dispatch record is NOT archived history.
  assert.equal(classifyRecord({ store: 'state-meta', reason: IN_FLIGHT_REDISPATCH_REASON, canonical: [{ table: 'tasks', fields: { task_id: 't' } }] }), null);
  // The three reason-based classes still hold.
  assert.equal(classifyRecord({ store: 'state-status', reason: DONE_ARCHIVE_REASON, canonical: [] }), 'done_archive');
  assert.equal(classifyRecord({ store: 'state-meta', reason: MULTI_GEN_REASON, canonical: [] }), 'multi_gen');
});

test('buildHistoryEntry extracts task_id, run_generation, and terminal_outcome; flags when no task_id', () => {
  const doc = mixedResidual();
  const g = buildHistoryEntry(doc.residual[1], 'multi_gen');
  assert.equal(g.entry.task_id, 'gen-b');
  assert.equal(g.entry.run_generation, 1);
  const c = buildHistoryEntry(doc.residual[2], 'archive_event');
  assert.equal(c.entry.task_id, 'closed-c');
  assert.equal(c.entry.terminal_outcome, 'archived');
  assert.equal(c.entry.archived_at, '2026-07-13T00:20:31.364Z');
  // A record whose canonical carries no task_id is flagged, not silently dropped.
  const noId = { source_ref: 'x#L1', store: 's', reason: DONE_ARCHIVE_REASON, canonical: [{ table: 'task_events', key: 'k', fields: { event_type: 'progress' } }], source: { digest: digestOf('x#L1'), value: {} } };
  const f = buildHistoryEntry(noId, 'done_archive');
  assert.ok(f.flagged);
  assert.match(f.flagged.reason, /no recoverable task_id/);
});

// =====================================================================================
// Executor: totality, no live-path writes, idempotency
// =====================================================================================

test('back-fill imports every archived-history record and reconciles by FULL-SET totality (finding 3)', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw2-bfout-'), 'bf.json');
  const receipt = await runMigrateBackfill({ residualPath: writeResidual(mixedResidual()), dataDir, outPath: out, env: {} });

  assert.equal(receipt.ok, true);
  assert.equal(receipt.totals.residual_scanned, 5);
  assert.equal(receipt.totals.archived_history_matched, 3, 'the 3 archived-history records match');
  assert.equal(receipt.totals.imported, 3);
  assert.equal(receipt.totals.flagged, 0);
  assert.equal(receipt.totals.out_of_scope, 2, 'the 2 non-archived records are explicitly out-of-scope, not silently dropped');
  assert.deepEqual(receipt.totals.by_class, { done_archive: 1, multi_gen: 1, archive_event: 1 });
  assert.equal(receipt.reconciliation.full_totality_holds, true);
  assert.equal(receipt.reconciliation.matched_totality_holds, true);
  // Nothing lost: every scanned record is in exactly one bucket.
  assert.equal(
    receipt.totals.imported + receipt.totals.flagged + receipt.totals.out_of_scope,
    receipt.totals.residual_scanned
  );

  const report = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(report.schema, BACKFILL_RESIDUAL_SCHEMA);
  assert.match(report.decision, /FORBIDDEN/);
  // The out-of-scope records are enumerated with an auditable reason.
  assert.equal(report.out_of_scope.length, 2);
  assert.ok(report.out_of_scope.every((o) => typeof o.reason === 'string' && o.source_ref));
  const rows = await loadArchivedHistory(new PgliteLocalStore({ dataDir }));
  assert.deepEqual(rows.map((r) => r.task_id).sort(), ['closed-c', 'finished-a', 'gen-b']);
});

test('a done-archive LEDGER row with a non-accepted reason is captured, not dropped (finding 3 regression)', async () => {
  const dataDir = await initStore();
  const doc = residualDoc([
    // done-archive store, reason is NOT the accepted no-live-membership string (the class QA
    // proved was silently omitted). It MUST be imported as archived history.
    residualRecord({ sourceRef: 'data/done-archive.md#L1190', store: 'done-archive', reason: "prescribed status 'archived' not committed (store status 'queued')", canonical: [{ table: 'tasks', key: 'reactivated-x', fields: { task_id: 'reactivated-x', title: 'X', status: 'archived' } }], value: { line: '- [x] reactivated-x' } }),
    residualRecord({ sourceRef: 'data/done-archive.md#L1302', store: 'done-archive', reason: 'kind un-prescribed (no state-meta/lifecycle/ledger record supplies a kind)', canonical: [{ table: 'tasks', key: 'nokind-y', fields: { task_id: 'nokind-y', title: 'Y', status: 'archived' } }], value: { line: '- [x] nokind-y' } })
  ]);
  const receipt = await runMigrateBackfill({ residualPath: writeResidual(doc), dataDir, outPath: path.join(mkTempDir('o-'), 'bf.json'), env: {} });
  assert.equal(receipt.totals.imported, 2, 'both done-archive ledger rows captured despite non-accepted reasons');
  assert.equal(receipt.totals.out_of_scope, 0);
  const rows = await loadArchivedHistory(new PgliteLocalStore({ dataDir }));
  assert.deepEqual(rows.map((r) => r.task_id).sort(), ['nokind-y', 'reactivated-x']);
});

test('back-fill writes ONLY the audit table - NO task/run/event/outbox/consumer rows (no faked live path)', async () => {
  const dataDir = await initStore();
  const out = path.join(mkTempDir('cp-cw2-bfout-'), 'bf.json');
  await runMigrateBackfill({ residualPath: writeResidual(mixedResidual()), dataDir, outPath: out, env: {} });

  // The live-path tables are never even CREATED by the back-fill (their lazy schema is only
  // applied by a real domain command), the strongest proof no live-path event was faked.
  for (const t of ['tasks', 'runs', 'task_events', 'outbox', 'consumer_receipts']) {
    assert.equal(await tablePresent(dataDir, t), false, `${t} must not be created by the back-fill`);
  }
  assert.equal(await tablePresent(dataDir, 'archived_history'), true);
  assert.equal(Number((await q(dataDir, 'SELECT count(*)::int n FROM archived_history'))[0].n), 3);
});

test('the back-filled history is carried by cp snapshot (finding 4)', async () => {
  const dataDir = await initStore();
  await runMigrateBackfill({ residualPath: writeResidual(mixedResidual()), dataDir, outPath: path.join(mkTempDir('o-'), 'bf.json'), env: {} });

  const orderSrc = path.join(mkTempDir('cp-cw2-ord-'), 'orders.jsonl');
  fs.writeFileSync(orderSrc, '');
  const store = new PgliteLocalStore({ dataDir });
  let snapRev;
  try {
    const snap = await createSnapshot(store, { orderSourcePath: orderSrc });
    snapRev = snap.projection_revision;
    // The canonical snapshot payload includes the archived-history projection.
    const got = await getSnapshot(store, { revision: snapRev });
    assert.ok(Array.isArray(got.payload.archived_history), 'snapshot payload carries archived_history');
    assert.equal(got.payload.archived_history.length, 3);
    assert.deepEqual(got.payload.archived_history.map((r) => r.task_id).sort(), ['closed-c', 'finished-a', 'gen-b']);
    // A rebuild over unchanged state dedups to the SAME snapshot (deterministic checksum).
    const again = await createSnapshot(store, { orderSourcePath: orderSrc });
    assert.equal(again.projection_revision, snapRev, 'deterministic: history section dedups, no new snapshot');
  } finally {
    await store.close();
  }
});

test('a store that never ran the back-fill has NO archived_history key (S6 payload unchanged)', async () => {
  const dataDir = await initStore();
  // Create a task so there is domain state to snapshot, but never back-fill.
  const store = new PgliteLocalStore({ dataDir });
  try {
    const { createTask } = await import('../lib/domain-store.mjs');
    await createTask(store, { taskId: 'plain-1', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c:plain-1' });
    const orderSrc = path.join(mkTempDir('cp-cw2-ord2-'), 'orders.jsonl');
    fs.writeFileSync(orderSrc, '');
    const snap = await createSnapshot(store, { orderSourcePath: orderSrc });
    const got = await getSnapshot(store, { revision: snap.projection_revision });
    assert.equal('archived_history' in got.payload, false, 'no archived_history key when the table has no rows - existing payload byte-identical');
  } finally {
    await store.close();
  }
});

test('back-fill is idempotent: a second run replays and never duplicates', async () => {
  const dataDir = await initStore();
  const residual = writeResidual(mixedResidual());
  const r1 = await runMigrateBackfill({ residualPath: residual, dataDir, outPath: path.join(mkTempDir('o1-'), 'bf.json'), env: {} });
  assert.equal(r1.totals.imported_new, 3);
  assert.equal(r1.totals.imported_replayed, 0);
  const r2 = await runMigrateBackfill({ residualPath: residual, dataDir, outPath: path.join(mkTempDir('o2-'), 'bf.json'), resume: true, env: {} });
  assert.equal(r2.totals.imported_new, 0);
  assert.equal(r2.totals.imported_replayed, 3);
  assert.equal(r2.reconciliation.store_archived_history_count, 3, 'no duplicate rows on replay');
  assert.equal(r2.ok, true);
});

test('read-only legacy discipline: a bogus legacy_home in the residual is never read', async () => {
  const dataDir = await initStore();
  const doc = residualDoc(mixedResidual().residual, { legacyHome: '/this/path/does/not/exist/legacy' });
  const out = path.join(mkTempDir('cp-cw2-bfro-'), 'bf.json');
  // The back-fill's input is the residual FILE only; it must succeed without ever touching
  // the (nonexistent) legacy home.
  const receipt = await runMigrateBackfill({ residualPath: writeResidual(doc), dataDir, outPath: out, env: {} });
  assert.equal(receipt.ok, true);
  assert.equal(receipt.totals.imported, 3);
});

// =====================================================================================
// Surface guards + real CW1 residual shape
// =====================================================================================

test('--out under the store data-dir is refused', async () => {
  const dataDir = await initStore();
  await assert.rejects(
    runMigrateBackfill({ residualPath: writeResidual(mixedResidual()), dataDir, outPath: path.join(dataDir, 'bf.json'), env: {} }),
    (err) => err instanceof BackfillError && /resolves under the store data-dir/.test(err.message)
  );
});

test('loadResidual rejects a non-CW1-residual document', () => {
  const p = path.join(mkTempDir('cp-cw2-bad-'), 'x.json');
  fs.writeFileSync(p, JSON.stringify({ schema: 'something/else' }));
  assert.throws(() => loadResidual(p), (err) => err instanceof BackfillError && /is not a .*residual.*document/.test(err.message));
});

test('consumes a residual produced by a REAL migrate-apply run (archived task deferral)', async () => {
  // Materialize a report with an archived task through CW1, producing a real residual, then
  // back-fill it - proving the executor consumes the genuine CW1 output shape.
  const applyStore = path.join(mkTempDir('cp-cw2-apply-'), 'pgdata');
  await runVerb(['init', '--data-dir', applyStore], { env: {} });
  const report = {
    schema: REPORT_SCHEMA, posture: 'x', legacy_home: '/fixture/legacy', sources: [], stores: [],
    totals: { discovered: 3, mapped: 3, flagged: 0, reconciles: true },
    flags_by_reason: { unmappable: 0, ambiguous: 0, duplicate: 0 },
    records: [
      { store: 'backlog', source_ref: 'bk#q', disposition: 'mapped', mapping: { canonical: [{ table: 'tasks', key: 'q', fields: { task_id: 'q', title: 'Q', status: 'queued' }, provenance: {}, unresolved: [] }] }, source: { digest: digestOf('bk#q'), raw: 'bk#q', value: { line: '- [ ] q (kind: ship)', section: 'Queued' } } },
      { store: 'done-archive', source_ref: 'arch#old', disposition: 'mapped', mapping: { canonical: [{ table: 'tasks', key: 'old', fields: { task_id: 'old', title: 'Old', status: 'archived' }, provenance: {}, unresolved: [] }] }, source: { digest: digestOf('arch#old'), raw: 'arch#old', value: { line: '- [x] old (kind: ship)', section: 'Archived' } } },
      { store: 'task-lifecycle', source_ref: 'state/task-lifecycle.jsonl#L1', disposition: 'mapped', mapping: { canonical: [{ table: 'task_events', key: 'evt-old', fields: { task_id: 'old', event_scope: 'task', event_type: 'archived', producer_id: 'firstmate', event_id: 'evt-old' }, provenance: {}, unresolved: [] }] }, source: { digest: digestOf('L1'), raw: 'L1', value: { id: 'old', event: 'closed' } } }
    ],
    human_summary: 'x'
  };
  const reportPath = path.join(mkTempDir('cp-cw2-rep-'), 'report.json');
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  const residualOut = path.join(mkTempDir('cp-cw2-realres-'), 'residual.json');
  await runMigrateApply({ reportPath, dataDir: applyStore, outPath: residualOut, allowResidualOver: 90, env: {} });

  // Back-fill into a SEPARATE fresh store.
  const bfStore = await initStore();
  const receipt = await runMigrateBackfill({ residualPath: residualOut, dataDir: bfStore, outPath: path.join(mkTempDir('bfo-'), 'bf.json'), env: {} });
  assert.equal(receipt.ok, true);
  assert.ok(receipt.totals.archived_history_matched >= 2, 'the archived task + its task-scope archived event are back-filled');
  const rows = await loadArchivedHistory(new PgliteLocalStore({ dataDir: bfStore }));
  assert.ok(rows.some((r) => r.task_id === 'old'));
});
