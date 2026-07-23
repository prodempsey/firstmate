import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { runVerb } from '../lib/coordinator.mjs';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { failRun } from '../lib/domain-store-s2.mjs';
import { recordAnnotation, loadAnnotations } from '../lib/cw2-annotations.mjs';
import { readOnlyQuery } from '../lib/cw1-readonly.mjs';
import { REPORT_SCHEMA } from '../lib/migrate-report.mjs';
import { expectedFromReport, diffAgainstStore } from '../lib/shadow-diff.mjs';
import {
  runShadowReconcile, reconcileTerminal, loadReconcileTerminals, computeLedgerDigest,
  loadLedger, RECONCILE_LEDGER_SCHEMA, RECONCILE_RECEIPT_SCHEMA, ReconcileError
} from '../lib/shadow-reconcile.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// CW2+ shadow-window RECONCILE (shadow-reconcile). Proves the narrow administrative path that
// reconciles documented pre-shadow-enable divergence: a legacy-derived `completed` expectation
// against a store row wrongly `failed` (after the reconciler's spawn-timeout close of a
// synthetic gen-1 run). Covers the gate refusals (captain-approval, ledger validity, task-not-
// in-ledger, shadow window closed, already-matches, --out containment, evidence), idempotency,
// preserved gen-1 run history, the ledger-digest audit trail, and that a reconciled row is
// counted as MATCHING by shadow-diff.
after(cleanupAll);

const NOW = '2026-07-22T00:00:00.000Z';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const SAMPLE_LEDGER = path.join(HERE, 'fixtures', 'shadow-reconcile-ledger.sample.json');

async function initStore() {
  const dataDir = path.join(mkTempDir('cp-recon-'), 'pgdata');
  await runVerb(['init', '--data-dir', dataDir], { env: {} });
  return dataDir;
}
async function withStore(dataDir, fn) {
  const store = new PgliteLocalStore({ dataDir });
  try { return await fn(store); } finally { await store.close(); }
}

// Reproduce the production scenario for a task: created -> begin-run (spawning) -> fail (the
// reconciler's spawn-timeout close), leaving the TASK `failed` with a closed `failed` gen-1
// run and a `failed` terminal event.
async function seedFailedTask(store, taskId) {
  await createTask(store, {
    taskId, kind: 'ship', title: taskId, origin: 'internal',
    internalReason: 'test seed', commandId: `seed:create:${taskId}`
  }, { now: NOW });
  await beginRun(store, {
    taskId, expectedRevision: 1, backend: 'tmux', commandId: `seed:begin:${taskId}`
  }, { now: NOW });
  await failRun(store, {
    taskId, generation: 1, expectedRevision: 2, producer: 'reconciler', seq: 1,
    reason: 'spawn timeout (synthetic run)', commandId: `seed:fail:${taskId}`
  }, { now: NOW });
}

// Open the shadow window on a store: record one shadow annotation so the shadow_annotations
// table exists (the shadow writer would have done this in a real shadow run).
async function openShadowWindow(store, taskId = 'seed') {
  await recordAnnotation(store, {
    commandId: `seed:annot:${taskId}`, taskId, action: 'dispatched', detail: null,
    source: 'cp-shadow', now: NOW
  });
}

function getTask(store, id) {
  return readOnlyQuery(store, 'SELECT task_id, status, revision FROM tasks WHERE task_id = $1', [id])
    .then((r) => r[0] || null);
}
function getRuns(store, id) {
  return readOnlyQuery(store, 'SELECT run_generation, status, closed_at FROM runs WHERE task_id = $1 ORDER BY run_generation', [id]);
}
function getTerminalEvents(store, id) {
  return readOnlyQuery(store, "SELECT event_type, run_generation, is_terminal FROM task_events WHERE task_id = $1 AND is_terminal", [id]);
}

const entry = (task_id, expected_status = 'completed', refs = [`legacy/ref/${task_id}`]) =>
  ({ task_id, expected_status, evidence: { source_refs: refs, note: 't' } });

function writeLedger(entries, { schema = RECONCILE_LEDGER_SCHEMA, reason = 'test ledger', name = 'ledger.json' } = {}) {
  const p = path.join(mkTempDir('cp-recon-in-'), name);
  fs.writeFileSync(p, `${JSON.stringify({ schema, reason, entries }, null, 2)}\n`);
  return p;
}
function writeRaw(text, name = 'ledger.json') {
  const p = path.join(mkTempDir('cp-recon-in-'), name);
  fs.writeFileSync(p, text);
  return p;
}
function outPath() {
  return path.join(mkTempDir('cp-recon-out-'), 'receipt.json');
}
const readReceipt = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));

// ---------------------------------------------------------------------------------
// Happy path
// ---------------------------------------------------------------------------------

test('reconciles a wrongly-failed task to completed, preserving gen-1 run history', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => {
    await seedFailedTask(s, 'q87');
    await seedFailedTask(s, 'q88');
    await openShadowWindow(s);
  });

  const ledger = writeLedger([entry('q87'), entry('q88')]);
  const out = outPath();
  const digest = computeLedgerDigest(loadLedger(ledger).doc);

  const result = await runShadowReconcile({
    ledgerPath: ledger, dataDir, outPath: out, captainApproved: true, now: NOW
  });
  assert.equal(result.ok, true);
  assert.equal(result.totals.reconciled, 2);
  assert.equal(result.ledger_digest, digest);

  await withStore(dataDir, async (s) => {
    // Task terminal status is now `completed`.
    assert.equal((await getTask(s, 'q87')).status, 'completed');
    assert.equal((await getTask(s, 'q88')).status, 'completed');

    // The junk gen-1 run history is PRESERVED, not deleted: still one closed `failed` run and
    // its `failed` terminal event.
    const runs = await getRuns(s, 'q87');
    assert.equal(runs.length, 1);
    assert.equal(runs[0].status, 'failed');
    assert.notEqual(runs[0].closed_at, null);
    const terms = await getTerminalEvents(s, 'q87');
    assert.equal(terms.length, 1);
    assert.equal(terms[0].event_type, 'failed', 'the original failed terminal event is untouched');

    // The reconcile is "recorded as such": a marker row per task with producer reconciler and
    // the ledger digest, plus an audit annotation per task carrying the ledger digest.
    const markers = await loadReconcileTerminals(s);
    const m87 = markers.find((m) => m.task_id === 'q87');
    assert.ok(m87);
    assert.equal(m87.disposition, 'reconciled');
    assert.equal(m87.producer, 'reconciler');
    assert.equal(m87.from_status, 'failed');
    assert.equal(m87.to_status, 'completed');
    assert.equal(m87.ledger_digest, digest);

    const annots = await loadAnnotations(s);
    const a87 = annots.filter((a) => a.task_id === 'q87' && a.action === 'reconcile-terminal');
    assert.equal(a87.length, 1);
    assert.equal(a87[0].detail.ledger_digest, digest);
    assert.equal(a87[0].source, 'cp-reconcile');
  });

  // The receipt file records both entries.
  const receipt = readReceipt(out);
  assert.equal(receipt.schema, RECONCILE_RECEIPT_SCHEMA);
  assert.equal(receipt.captain_approved, true);
  assert.equal(receipt.shadow_window_open, true);
  assert.equal(receipt.entries.length, 2);
  assert.ok(receipt.entries.every((e) => e.disposition === 'reconciled'));
});

test('a reconciled row is counted as MATCHING by shadow-diff (was mismatched before)', async () => {
  const digestOf = (raw) => crypto.createHash('sha256').update(raw).digest('hex');
  const md = (store, sourceRef, canonical, value = {}) =>
    ({ store, source_ref: sourceRef, disposition: 'mapped', mapping: { canonical }, source: { digest: digestOf(sourceRef), raw: sourceRef, value } });
  const trow = (fields) => ({ table: 'tasks', key: fields.task_id, fields, provenance: { task_id: 's' }, unresolved: [] });
  const rrow = (id) => ({ table: 'runs', key: `${id}/1`, fields: { task_id: id, run_generation: 1, backend: 'tmux', worktree: '/wt', harness: 'codex' }, provenance: { task_id: 's' }, unresolved: [] });
  const makeReport = (dispositions) => ({
    schema: REPORT_SCHEMA, posture: 'x', legacy_home: '/fixture/legacy', sources: [], stores: [],
    totals: { discovered: dispositions.length, mapped: dispositions.length, flagged: 0, reconciles: true },
    flags_by_reason: { unmappable: 0, ambiguous: 0, duplicate: 0 }, records: dispositions, human_summary: 'x'
  });
  const report = makeReport([
    md('state-meta', 'state/recon-x.meta', [trow({ task_id: 'recon-x', kind: 'ship' }), rrow('recon-x')], { kind: 'ship' }),
    md('backlog', 'bk#recon-x', [trow({ task_id: 'recon-x', title: 'X', status: 'completed' })], { line: '- [x] recon-x - X (kind: ship)', section: 'Done' })
  ]);
  // The CW1 classification derives this task `completed`.
  assert.equal(expectedFromReport(report).live.get('recon-x').expected_status, 'completed');

  const dataDir = await initStore();
  await withStore(dataDir, async (s) => {
    await seedFailedTask(s, 'recon-x');
    await openShadowWindow(s);
  });

  // Before reconcile: store `failed` vs expected `completed` => mismatched.
  let core = await withStore(dataDir, (s) => diffAgainstStore(report, s));
  assert.equal(core.totals.mismatched, 1);
  assert.equal(core.divergence.mismatched[0].task_id, 'recon-x');
  assert.equal(core.ok, false);

  await runShadowReconcile({
    ledgerPath: writeLedger([entry('recon-x')]), dataDir, outPath: outPath(), captainApproved: true, now: NOW
  });

  // After reconcile: the row matches, zero divergence.
  core = await withStore(dataDir, (s) => diffAgainstStore(report, s));
  assert.equal(core.totals.missing, 0);
  assert.equal(core.totals.mismatched, 0);
  assert.equal(core.totals.extra, 0);
  assert.equal(core.ok, true);
});

// ---------------------------------------------------------------------------------
// Gates
// ---------------------------------------------------------------------------------

test('GATE: refuses without --captain-approved, writing nothing to the store', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await openShadowWindow(s); });
  const ledger = writeLedger([entry('q87')]);

  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: ledger, dataDir, outPath: outPath(), captainApproved: false, now: NOW }),
    (e) => e instanceof ReconcileError && /captain-approved/.test(e.message)
  );
  await withStore(dataDir, async (s) => {
    assert.equal((await getTask(s, 'q87')).status, 'failed', 'store untouched by a refused reconcile');
  });
});

test('GATE: a missing --captain-approved value (not a bare flag) still refuses via the coordinator', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await openShadowWindow(s); });
  const ledger = writeLedger([entry('q87')]);
  // `--captain-approved somevalue` binds a string, not the required bare-flag true => refuse.
  await assert.rejects(
    () => runVerb(['shadow-reconcile', '--ledger', ledger, '--data-dir', dataDir, '--out', outPath(), '--captain-approved', 'yes'], { env: {} }),
    (e) => e instanceof ReconcileError && /captain-approved/.test(e.message)
  );
});

test('GATE: missing / invalid / wrong-schema / empty ledger all refuse', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, (s) => openShadowWindow(s));
  const out = () => outPath();

  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: '/no/such/ledger.json', dataDir, outPath: out(), captainApproved: true, now: NOW }),
    (e) => e instanceof ReconcileError && /could not be read/.test(e.message)
  );
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeRaw('{ not json', 'bad.json'), dataDir, outPath: out(), captainApproved: true, now: NOW }),
    (e) => e instanceof ReconcileError && /not valid JSON/.test(e.message)
  );
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { schema: 'wrong/schema' }), dataDir, outPath: out(), captainApproved: true, now: NOW }),
    (e) => e instanceof ReconcileError && /is not a control-plane\/shadow-reconcile\/ledger\/v1/.test(e.message)
  );
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([]), dataDir, outPath: out(), captainApproved: true, now: NOW }),
    (e) => e instanceof ReconcileError && /no entries/.test(e.message)
  );
});

test('GATE: a non-terminal expected_status and missing evidence are refused at load', () => {
  assert.throws(
    () => loadLedger(writeLedger([entry('q87', 'queued')])),
    (e) => e instanceof ReconcileError && /expected_status must be one of/.test(e.message)
  );
  assert.throws(
    () => loadLedger(writeLedger([{ task_id: 'q87', expected_status: 'completed' }])),
    (e) => e instanceof ReconcileError && /source_refs/.test(e.message)
  );
  assert.throws(
    () => loadLedger(writeLedger([{ task_id: 'q87', expected_status: 'completed', evidence: { source_refs: [] } }])),
    (e) => e instanceof ReconcileError && /source_refs/.test(e.message)
  );
});

test('GATE: a --task not named in the ledger is refused', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await openShadowWindow(s); });
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')]), dataDir, outPath: outPath(), captainApproved: true, taskFilter: 'not-in-ledger', now: NOW }),
    (e) => e instanceof ReconcileError && /not named in the ledger/.test(e.message)
  );
});

test('GATE: refuses when the shadow window is not open (no shadow_annotations)', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, (s) => seedFailedTask(s, 'q87')); // NO shadow window opened
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')]), dataDir, outPath: outPath(), captainApproved: true, now: NOW }),
    (e) => e instanceof ReconcileError && /shadow window is not open/.test(e.message)
  );
  await withStore(dataDir, async (s) => {
    assert.equal((await getTask(s, 'q87')).status, 'failed', 'store untouched when the window gate refuses');
  });
});

test('GATE: refuses if the store row already matches the expected terminal', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await openShadowWindow(s); });

  // First reconcile flips failed -> completed.
  await runShadowReconcile({ ledgerPath: writeLedger([entry('q87')]), dataDir, outPath: outPath(), captainApproved: true, now: NOW });
  const revAfter = await withStore(dataDir, async (s) => (await getTask(s, 'q87')).revision);

  // A DIFFERENT ledger (different evidence -> different digest -> different command-id, no
  // receipt) targeting the now-`completed` row is recorded already_matched, not re-applied.
  const out = outPath();
  const result = await runShadowReconcile({
    ledgerPath: writeLedger([entry('q87', 'completed', ['other/ref'])]), dataDir, outPath: out, captainApproved: true, now: NOW
  });
  assert.equal(result.totals.already_matched, 1);
  assert.equal(result.totals.reconciled, 0);
  assert.equal(readReceipt(out).entries[0].disposition, 'already_matched');

  await withStore(dataDir, async (s) => {
    assert.equal((await getTask(s, 'q87')).revision, revAfter, 'no revision bump for an already-matching row');
    const markers = await loadReconcileTerminals(s);
    assert.equal(markers.filter((m) => m.task_id === 'q87' && m.disposition === 'already_matched').length, 1);
  });
});

test('GATE: --out resolving under the store data-dir is refused', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await openShadowWindow(s); });
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')]), dataDir, outPath: path.join(dataDir, 'receipt.json'), captainApproved: true, now: NOW }),
    (e) => e instanceof ReconcileError && /--out resolves under the store data-dir/.test(e.message)
  );
});

// ---------------------------------------------------------------------------------
// Idempotency + error surfacing
// ---------------------------------------------------------------------------------

test('IDEMPOTENT: re-running the same approved ledger replays and changes nothing', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await seedFailedTask(s, 'q88'); await openShadowWindow(s); });
  const ledger = writeLedger([entry('q87'), entry('q88')]);

  const first = await runShadowReconcile({ ledgerPath: ledger, dataDir, outPath: outPath(), captainApproved: true, now: NOW });
  assert.equal(first.totals.reconciled, 2);
  const snap1 = await withStore(dataDir, async (s) => ({
    t87: await getTask(s, 'q87'), t88: await getTask(s, 'q88'),
    markers: (await loadReconcileTerminals(s)).length,
    annots: (await loadAnnotations(s)).filter((a) => a.action === 'reconcile-terminal').length
  }));

  const out2 = outPath();
  const second = await runShadowReconcile({ ledgerPath: ledger, dataDir, outPath: out2, captainApproved: true, now: NOW });
  assert.equal(second.totals.replayed, 2, 'a re-run replays every entry');
  assert.equal(second.totals.reconciled, 0);
  assert.ok(readReceipt(out2).entries.every((e) => e.disposition === 'replayed'));

  const snap2 = await withStore(dataDir, async (s) => ({
    t87: await getTask(s, 'q87'), t88: await getTask(s, 'q88'),
    markers: (await loadReconcileTerminals(s)).length,
    annots: (await loadAnnotations(s)).filter((a) => a.action === 'reconcile-terminal').length
  }));
  assert.deepEqual(snap2, snap1, 'a replay applies nothing new: task revisions, markers, and annotations are unchanged');
});

test('a ledger entry naming a task absent from the store is an error; receipt is still written', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await openShadowWindow(s); });
  const out = outPath();
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87'), entry('ghost')]), dataDir, outPath: out, captainApproved: true, now: NOW }),
    (e) => e instanceof ReconcileError && /per-entry errors/.test(e.message)
  );
  const receipt = readReceipt(out);
  assert.equal(receipt.ok, false);
  assert.equal(receipt.totals.reconciled, 1);
  assert.equal(receipt.totals.error, 1);
  const ghost = receipt.entries.find((e) => e.task_id === 'ghost');
  assert.equal(ghost.disposition, 'error');
  assert.match(ghost.error, /unknown task/);
  await withStore(dataDir, async (s) => {
    assert.equal((await getTask(s, 'q87')).status, 'completed', 'the reconcilable row still landed');
  });
});

// ---------------------------------------------------------------------------------
// Coordinator registration + sample fixture
// ---------------------------------------------------------------------------------

test('reachable through the coordinator (cp shadow-reconcile), with surface validation', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await openShadowWindow(s); });
  const ledger = writeLedger([entry('q87')]);

  const outcome = await runVerb(
    ['shadow-reconcile', '--ledger', ledger, '--data-dir', dataDir, '--out', outPath(), '--captain-approved'],
    { env: {} }
  );
  assert.equal(outcome.ok, true);
  assert.equal(outcome.result.totals.reconciled, 1);

  // Surface validation: unknown positional, missing required flags.
  await assert.rejects(() => runVerb(['shadow-reconcile', 'stray', '--ledger', ledger, '--data-dir', dataDir, '--out', outPath()], { env: {} }), /no positional/);
  await assert.rejects(() => runVerb(['shadow-reconcile', '--data-dir', dataDir, '--out', outPath()], { env: {} }), /requires --ledger/);
  await assert.rejects(() => runVerb(['shadow-reconcile', '--ledger', ledger, '--out', outPath()], { env: {} }), /requires --data-dir/);
  await assert.rejects(() => runVerb(['shadow-reconcile', '--ledger', ledger, '--data-dir', dataDir], { env: {} }), /requires --out/);
});

test('the committed sample ledger fixture is a valid v1 ledger', () => {
  const { doc, digest } = loadLedger(SAMPLE_LEDGER);
  assert.equal(doc.schema, RECONCILE_LEDGER_SCHEMA);
  assert.ok(doc.entries.length >= 2);
  assert.ok(doc.entries.every((e) => e.expected_status === 'completed' && e.evidence.source_refs.length > 0));
  assert.match(digest, /^[0-9a-f]{64}$/);
});

test('reconcileTerminal (domain) is idempotent by command-id when called directly', async () => {
  const dataDir = await initStore();
  await withStore(dataDir, async (s) => {
    await seedFailedTask(s, 'q87');
    const cmd = 'cp-reconcile:deadbeefdeadbeef:q87';
    const a = await reconcileTerminal(s, { taskId: 'q87', expectedStatus: 'completed', ledgerDigest: 'd', evidence: null, commandId: cmd }, { now: NOW });
    assert.equal(a.disposition, 'reconciled');
    assert.equal(a.revision, 4);
    const b = await reconcileTerminal(s, { taskId: 'q87', expectedStatus: 'completed', ledgerDigest: 'd', evidence: null, commandId: cmd }, { now: NOW });
    assert.equal(b.revision, 4, 'a replay returns the same committed revision without re-applying');
    assert.equal((await getTask(s, 'q87')).revision, 4);
  });
});
