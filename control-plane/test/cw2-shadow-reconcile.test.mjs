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
// synthetic gen-1 run). Covers the gate refusals and the QA-round-1 hardening:
//   * shadow window must be CURRENTLY open+closable (CP_SHADOW=1), not inferred from a
//     persistent historical table (finding 1);
//   * an already-matching row is REFUSED before any store write, while an exact re-run replays
//     (finding 2);
//   * approval is bound to the canonical target store, home_uuid, and full ledger identity
//     (finding 3);
//   * evidence refs must resolve beneath the declared legacy home (finding 4);
//   * status + marker + annotation + receipt + counters commit or roll back together, proven
//     by a crash-cut (finding 5).
after(cleanupAll);

const NOW = '2026-07-22T00:00:00.000Z';
const SHADOW = { CP_SHADOW: '1' };
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

// A temp legacy home with durable, resolvable evidence files (backlog Done rows + a
// done-archive) containing each task id as an anchor.
function mkLegacyHome(taskIds) {
  const home = mkTempDir('cp-recon-legacy-');
  fs.mkdirSync(path.join(home, 'data'), { recursive: true });
  const lines = taskIds.map((t) => `- [x] ${t} - ${t} done - local main (merged 2026-07-20)`).join('\n');
  fs.writeFileSync(path.join(home, 'data', 'backlog.md'), `## Done\n${lines}\n`);
  fs.writeFileSync(path.join(home, 'data', 'done-archive.md'), `## Archived\n${lines}\n`);
  return home;
}

// Full happy-path scenario: an initialized store with `taskIds` seeded failed and the shadow
// window open, plus a legacy home whose evidence resolves for `evidenceTaskIds` (defaults to
// the seeded set).
async function scenario(taskIds = ['q87'], evidenceTaskIds = taskIds) {
  const dataDir = await initStore();
  const legacyHome = mkLegacyHome(evidenceTaskIds);
  await withStore(dataDir, async (s) => {
    for (const t of taskIds) await seedFailedTask(s, t);
    await openShadowWindow(s);
  });
  return { dataDir, legacyHome };
}

function getTask(store, id) {
  return readOnlyQuery(store, 'SELECT task_id, status, revision FROM tasks WHERE task_id = $1', [id]).then((r) => r[0] || null);
}
function getRuns(store, id) {
  return readOnlyQuery(store, 'SELECT run_generation, status, closed_at FROM runs WHERE task_id = $1 ORDER BY run_generation', [id]);
}
function getTerminalEvents(store, id) {
  return readOnlyQuery(store, 'SELECT event_type, run_generation, is_terminal FROM task_events WHERE task_id = $1 AND is_terminal', [id]);
}
function getCoordState(store) {
  return readOnlyQuery(store, 'SELECT commit_sequence, domain_revision FROM coordinator_state WHERE id = 1').then((r) => r[0]);
}
function getHomeUuid(store) {
  return readOnlyQuery(store, "SELECT value FROM schema_meta WHERE key = 'home_uuid'").then((r) => r[0].value);
}
function reconcileAnnots(store) {
  return loadAnnotations(store).then((a) => a.filter((x) => x.action === 'reconcile-terminal'));
}

const entry = (task_id, expected_status = 'completed', refs = [`data/backlog.md#${task_id}`]) =>
  ({ task_id, expected_status, evidence: { source_refs: refs, note: 't' } });

function writeLedger(entries, { legacyHome, targetDataDir, schema = RECONCILE_LEDGER_SCHEMA, extra = {}, name = 'ledger.json' } = {}) {
  const doc = { schema, reason: 'test ledger', legacy_home: legacyHome, target_data_dir: targetDataDir, ...extra, entries };
  const p = path.join(mkTempDir('cp-recon-in-'), name);
  fs.writeFileSync(p, `${JSON.stringify(doc, null, 2)}\n`);
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
  const { dataDir, legacyHome } = await scenario(['q87', 'q88']);
  const ledger = writeLedger([entry('q87'), entry('q88')], { legacyHome, targetDataDir: dataDir });
  const out = outPath();
  const digest = loadLedger(ledger).digest;

  const result = await runShadowReconcile({ ledgerPath: ledger, dataDir, outPath: out, captainApproved: true, env: SHADOW, now: NOW });
  assert.equal(result.ok, true);
  assert.equal(result.totals.reconciled, 2);
  assert.equal(result.ledger_digest, digest);

  await withStore(dataDir, async (s) => {
    assert.equal((await getTask(s, 'q87')).status, 'completed');
    assert.equal((await getTask(s, 'q88')).status, 'completed');

    // The junk gen-1 run history is PRESERVED, not deleted.
    const runs = await getRuns(s, 'q87');
    assert.equal(runs.length, 1);
    assert.equal(runs[0].status, 'failed');
    assert.notEqual(runs[0].closed_at, null);
    const terms = await getTerminalEvents(s, 'q87');
    assert.equal(terms.length, 1);
    assert.equal(terms[0].event_type, 'failed', 'the original failed terminal event is untouched');

    // Recorded "as such": a marker row (producer reconciler, ledger digest) and an atomic
    // audit annotation carrying the ledger digest.
    const markers = await loadReconcileTerminals(s);
    const m87 = markers.find((m) => m.task_id === 'q87');
    assert.ok(m87);
    assert.equal(m87.disposition, 'reconciled');
    assert.equal(m87.producer, 'reconciler');
    assert.equal(m87.from_status, 'failed');
    assert.equal(m87.to_status, 'completed');
    assert.equal(m87.ledger_digest, digest);

    const a87 = (await reconcileAnnots(s)).filter((a) => a.task_id === 'q87');
    assert.equal(a87.length, 1);
    assert.equal(a87[0].detail.ledger_digest, digest);
    assert.equal(a87[0].source, 'cp-reconcile');
  });

  const receipt = readReceipt(out);
  assert.equal(receipt.schema, RECONCILE_RECEIPT_SCHEMA);
  assert.equal(receipt.captain_approved, true);
  assert.equal(receipt.shadow_window_open, true);
  assert.equal(receipt.target_data_dir, dataDir);
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
  assert.equal(expectedFromReport(report).live.get('recon-x').expected_status, 'completed');

  const { dataDir, legacyHome } = await scenario(['recon-x']);

  // Before reconcile: store `failed` vs expected `completed` => mismatched.
  let core = await withStore(dataDir, (s) => diffAgainstStore(report, s));
  assert.equal(core.totals.mismatched, 1);
  assert.equal(core.divergence.mismatched[0].task_id, 'recon-x');
  assert.equal(core.ok, false);

  await runShadowReconcile({
    ledgerPath: writeLedger([entry('recon-x')], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW
  });

  // After reconcile: zero divergence.
  core = await withStore(dataDir, (s) => diffAgainstStore(report, s));
  assert.equal(core.totals.missing, 0);
  assert.equal(core.totals.mismatched, 0);
  assert.equal(core.totals.extra, 0);
  assert.equal(core.ok, true);
});

// ---------------------------------------------------------------------------------
// Gates: approval + ledger validity
// ---------------------------------------------------------------------------------

test('GATE: refuses without --captain-approved, writing nothing to the store', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: false, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /captain-approved/.test(e.message)
  );
  await withStore(dataDir, async (s) => assert.equal((await getTask(s, 'q87')).status, 'failed'));
});

test('GATE: a missing --captain-approved value (not a bare flag) still refuses via the coordinator', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  const ledger = writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir });
  await assert.rejects(
    () => runVerb(['shadow-reconcile', '--ledger', ledger, '--data-dir', dataDir, '--out', outPath(), '--captain-approved', 'yes'], { env: SHADOW }),
    (e) => e instanceof ReconcileError && /captain-approved/.test(e.message)
  );
});

test('GATE: missing / invalid / wrong-schema / no-target / no-legacy / empty ledger all refuse', async () => {
  const dataDir = await initStore();
  const legacyHome = mkLegacyHome(['q87']);
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: '/no/such/ledger.json', dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /could not be read/.test(e.message)
  );
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeRaw('{ not json', 'bad.json'), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /not valid JSON/.test(e.message)
  );
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir, schema: 'wrong/schema' }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /is not a control-plane\/shadow-reconcile\/ledger\/v1/.test(e.message)
  );
  // no target_data_dir
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeRaw(JSON.stringify({ schema: RECONCILE_LEDGER_SCHEMA, legacy_home: legacyHome, entries: [entry('q87')] }), 'noT.json'), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /must declare target_data_dir/.test(e.message)
  );
  // no legacy_home
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeRaw(JSON.stringify({ schema: RECONCILE_LEDGER_SCHEMA, target_data_dir: dataDir, entries: [entry('q87')] }), 'noL.json'), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /must declare legacy_home/.test(e.message)
  );
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /no entries/.test(e.message)
  );
});

test('GATE: a non-terminal expected_status and missing evidence are refused at load', () => {
  const legacyHome = '/x';
  assert.throws(
    () => loadLedger(writeLedger([entry('q87', 'queued')], { legacyHome, targetDataDir: '/d' })),
    (e) => e instanceof ReconcileError && /expected_status must be one of/.test(e.message)
  );
  assert.throws(
    () => loadLedger(writeLedger([{ task_id: 'q87', expected_status: 'completed' }], { legacyHome, targetDataDir: '/d' })),
    (e) => e instanceof ReconcileError && /source_refs/.test(e.message)
  );
  assert.throws(
    () => loadLedger(writeLedger([{ task_id: 'q87', expected_status: 'completed', evidence: { source_refs: [] } }], { legacyHome, targetDataDir: '/d' })),
    (e) => e instanceof ReconcileError && /source_refs/.test(e.message)
  );
});

test('GATE: a --task not named in the ledger is refused', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, taskFilter: 'not-in-ledger', env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /not named in the ledger/.test(e.message)
  );
});

// ---------------------------------------------------------------------------------
// Finding 1: closable shadow-window gate
// ---------------------------------------------------------------------------------

test('GATE (finding 1): refuses when CP_SHADOW is not enabled, even with historical annotations present', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']); // shadow_annotations table already present
  for (const env of [{ CP_SHADOW: '0' }, {}]) {
    await assert.rejects(
      () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, env, now: NOW }),
      (e) => e instanceof ReconcileError && /CP_SHADOW is not enabled/.test(e.message)
    );
  }
  await withStore(dataDir, async (s) => assert.equal((await getTask(s, 'q87')).status, 'failed', 'a closed window leaves the store untouched'));
});

test('GATE: refuses when the store shows no shadow-mode activity even with CP_SHADOW=1', async () => {
  const dataDir = await initStore();
  const legacyHome = mkLegacyHome(['q87']);
  await withStore(dataDir, (s) => seedFailedTask(s, 'q87')); // NO shadow window opened
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /no shadow-mode activity/.test(e.message)
  );
});

// ---------------------------------------------------------------------------------
// Finding 2: already-matching row is refused with no writes; exact re-run replays
// ---------------------------------------------------------------------------------

test('GATE (finding 2): a new ledger targeting an already-matching row is REFUSED with NO store write', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  await runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW });

  const before = await withStore(dataDir, async (s) => ({
    cs: await getCoordState(s), markers: (await loadReconcileTerminals(s)).length,
    annots: (await loadAnnotations(s)).length, task: await getTask(s, 'q87')
  }));

  // A DIFFERENT ledger (different evidence -> different digest -> new command-id, no receipt).
  const out = outPath();
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87', 'completed', ['data/done-archive.md#q87'])], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: out, captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /refusals or errors/.test(e.message)
  );
  const receipt = readReceipt(out);
  assert.equal(receipt.totals.refused, 1);
  assert.equal(receipt.totals.reconciled, 0);
  assert.equal(receipt.entries[0].disposition, 'refused');

  const afterState = await withStore(dataDir, async (s) => ({
    cs: await getCoordState(s), markers: (await loadReconcileTerminals(s)).length,
    annots: (await loadAnnotations(s)).length, task: await getTask(s, 'q87')
  }));
  assert.deepEqual(afterState, before, 'a refused already-matching row writes NOTHING (no counter bump, marker, or annotation)');
});

test('IDEMPOTENT: re-running the SAME approved ledger replays and changes nothing', async () => {
  const { dataDir, legacyHome } = await scenario(['q87', 'q88']);
  const ledger = writeLedger([entry('q87'), entry('q88')], { legacyHome, targetDataDir: dataDir });

  const first = await runShadowReconcile({ ledgerPath: ledger, dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW });
  assert.equal(first.totals.reconciled, 2);
  const snap = (s) => Promise.all([getTask(s, 'q87'), getTask(s, 'q88'), loadReconcileTerminals(s), loadAnnotations(s), getCoordState(s)])
    .then(([t87, t88, m, a, cs]) => ({ t87, t88, markers: m.length, annots: a.length, cs }));
  const snap1 = await withStore(dataDir, snap);

  const out2 = outPath();
  const second = await runShadowReconcile({ ledgerPath: ledger, dataDir, outPath: out2, captainApproved: true, env: SHADOW, now: NOW });
  assert.equal(second.totals.replayed, 2, 'a re-run replays every entry');
  assert.equal(second.totals.reconciled, 0);
  assert.ok(readReceipt(out2).entries.every((e) => e.disposition === 'replayed'));

  const snap2 = await withStore(dataDir, snap);
  assert.deepEqual(snap2, snap1, 'a replay applies nothing new: revisions, markers, annotations, and counters are unchanged');
});

// ---------------------------------------------------------------------------------
// Finding 3: approval bound to target store + full ledger identity
// ---------------------------------------------------------------------------------

test('SECURITY (finding 3): ledger digest covers the target store and legacy root', () => {
  const base = { schema: RECONCILE_LEDGER_SCHEMA, legacy_home: '/h/a', target_data_dir: '/d/a', entries: [entry('t')] };
  assert.notEqual(computeLedgerDigest(base), computeLedgerDigest({ ...base, target_data_dir: '/d/b' }), 'changing the target changes the digest');
  assert.notEqual(computeLedgerDigest(base), computeLedgerDigest({ ...base, legacy_home: '/h/b' }), 'changing the legacy root changes the digest');
  assert.notEqual(computeLedgerDigest(base), computeLedgerDigest({ ...base, target_home_uuid: 'uuid' }), 'pinning a home_uuid changes the digest');
  assert.equal(computeLedgerDigest(base), computeLedgerDigest({ ...base, reason: 'a different human note' }), 'a documentation-only reason change does not');
});

test('GATE (finding 3): refuses when --data-dir does not match the approved target_data_dir', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  const otherDir = path.join(mkTempDir('cp-recon-other-'), 'pgdata');
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: otherDir }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /does not match the approved ledger target_data_dir/.test(e.message)
  );
  await withStore(dataDir, async (s) => assert.equal((await getTask(s, 'q87')).status, 'failed'));
});

test('GATE (finding 3): binds to store home_uuid when the ledger pins target_home_uuid', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  const realUuid = await withStore(dataDir, getHomeUuid);
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir, extra: { target_home_uuid: 'wrong-uuid' } }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /home_uuid does not match/.test(e.message)
  );
  const ok = await runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir, extra: { target_home_uuid: realUuid } }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW });
  assert.equal(ok.totals.reconciled, 1);
});

// ---------------------------------------------------------------------------------
// Finding 4: evidence must resolve beneath the declared legacy home
// ---------------------------------------------------------------------------------

test('GATE (finding 4): an evidence ref that does not resolve beneath the legacy home is refused', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87', 'completed', ['state/q87.meta'])], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /does not resolve to an existing file/.test(e.message)
  );
});

test('GATE (finding 4): an evidence ref escaping the legacy home, or a wrong anchor, is refused', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87', 'completed', ['../escape.md'])], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /resolves outside the declared legacy home/.test(e.message)
  );
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87', 'completed', ['data/backlog.md#not-present'])], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: outPath(), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /anchor 'not-present' not found/.test(e.message)
  );
});

// ---------------------------------------------------------------------------------
// Finding 5: atomicity (crash cut)
// ---------------------------------------------------------------------------------

test('ATOMIC (finding 5): a crash after the mutation rolls the whole reconcile back', async () => {
  const { dataDir } = await scenario(['q87']);
  await withStore(dataDir, async (s) => {
    await assert.rejects(
      () => reconcileTerminal(s, {
        taskId: 'q87', expectedStatus: 'completed', ledgerDigest: 'deadbeefdeadbeef',
        evidence: { source_refs: ['x'] }, commandId: 'cp-reconcile:crashtest:q87'
      }, { now: NOW, fault: () => { throw new Error('crash after mutate, before receipt'); } }),
      /crash after mutate/
    );
    // Nothing committed: task still failed, no marker, no reconcile annotation, no receipt.
    assert.equal((await getTask(s, 'q87')).status, 'failed');
    assert.equal((await loadReconcileTerminals(s)).length, 0);
    assert.equal((await reconcileAnnots(s)).length, 0);
    const rec = await readOnlyQuery(s, "SELECT 1 FROM command_results WHERE command_id = 'cp-reconcile:crashtest:q87'");
    assert.equal(rec.length, 0, 'no command receipt for a rolled-back reconcile');
  });
});

// ---------------------------------------------------------------------------------
// Out containment + error surfacing
// ---------------------------------------------------------------------------------

test('GATE: --out resolving under the store data-dir is refused', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: path.join(dataDir, 'receipt.json'), captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /--out resolves under the store data-dir/.test(e.message)
  );
});

test('a ledger entry naming a task absent from the store is a per-entry error; receipt is still written', async () => {
  // Evidence resolves for both tasks, but only q87 exists in the store.
  const dataDir = await initStore();
  const legacyHome = mkLegacyHome(['q87', 'ghost']);
  await withStore(dataDir, async (s) => { await seedFailedTask(s, 'q87'); await openShadowWindow(s); });
  const out = outPath();
  await assert.rejects(
    () => runShadowReconcile({ ledgerPath: writeLedger([entry('q87'), entry('ghost')], { legacyHome, targetDataDir: dataDir }), dataDir, outPath: out, captainApproved: true, env: SHADOW, now: NOW }),
    (e) => e instanceof ReconcileError && /refusals or errors/.test(e.message)
  );
  const receipt = readReceipt(out);
  assert.equal(receipt.ok, false);
  assert.equal(receipt.totals.reconciled, 1);
  assert.equal(receipt.totals.error, 1);
  const ghost = receipt.entries.find((e) => e.task_id === 'ghost');
  assert.equal(ghost.disposition, 'error');
  assert.match(ghost.error, /unknown task/);
  await withStore(dataDir, async (s) => assert.equal((await getTask(s, 'q87')).status, 'completed', 'the reconcilable row still landed'));
});

// ---------------------------------------------------------------------------------
// Coordinator registration + sample fixture + domain idempotency
// ---------------------------------------------------------------------------------

test('reachable through the coordinator (cp shadow-reconcile), with surface validation', async () => {
  const { dataDir, legacyHome } = await scenario(['q87']);
  const ledger = writeLedger([entry('q87')], { legacyHome, targetDataDir: dataDir });

  const outcome = await runVerb(
    ['shadow-reconcile', '--ledger', ledger, '--data-dir', dataDir, '--out', outPath(), '--captain-approved'],
    { env: SHADOW }
  );
  assert.equal(outcome.ok, true);
  assert.equal(outcome.result.totals.reconciled, 1);

  await assert.rejects(() => runVerb(['shadow-reconcile', 'stray', '--ledger', ledger, '--data-dir', dataDir, '--out', outPath()], { env: SHADOW }), /no positional/);
  await assert.rejects(() => runVerb(['shadow-reconcile', '--data-dir', dataDir, '--out', outPath()], { env: SHADOW }), /requires --ledger/);
  await assert.rejects(() => runVerb(['shadow-reconcile', '--ledger', ledger, '--out', outPath()], { env: SHADOW }), /requires --data-dir/);
  await assert.rejects(() => runVerb(['shadow-reconcile', '--ledger', ledger, '--data-dir', dataDir], { env: SHADOW }), /requires --out/);
});

test('the committed sample ledger fixture is a valid v1 ledger (syntax)', () => {
  const { doc, digest } = loadLedger(SAMPLE_LEDGER);
  assert.equal(doc.schema, RECONCILE_LEDGER_SCHEMA);
  assert.ok(typeof doc.target_data_dir === 'string' && doc.target_data_dir.length > 0);
  assert.ok(typeof doc.legacy_home === 'string' && doc.legacy_home.length > 0);
  assert.ok(doc.entries.length >= 2);
  assert.ok(doc.entries.every((e) => e.expected_status === 'completed' && e.evidence.source_refs.length > 0));
  assert.match(digest, /^[0-9a-f]{64}$/);
});

test('reconcileTerminal (domain) is idempotent by command-id when called directly', async () => {
  const { dataDir } = await scenario(['q87']);
  await withStore(dataDir, async (s) => {
    const cmd = 'cp-reconcile:deadbeefdeadbeef:q87';
    const a = await reconcileTerminal(s, { taskId: 'q87', expectedStatus: 'completed', ledgerDigest: 'deadbeefdeadbeef', evidence: null, commandId: cmd }, { now: NOW });
    assert.equal(a.disposition, 'reconciled');
    assert.equal(a.revision, 4);
    const b = await reconcileTerminal(s, { taskId: 'q87', expectedStatus: 'completed', ledgerDigest: 'deadbeefdeadbeef', evidence: null, commandId: cmd }, { now: NOW });
    assert.equal(b.revision, 4, 'a replay returns the same committed revision without re-applying');
    assert.equal((await getTask(s, 'q87')).revision, 4);
  });
});
