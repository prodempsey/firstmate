import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun, failRun } from '../lib/domain-store-s2.mjs';
import { recordSpawn, commitRunning, cleanupIntent, cleanupFinish } from '../lib/domain-store-s3.mjs';
import { sha256hex } from '../lib/domain-store.mjs';
import { resolveAnomaly, listAnomalies, recordReconcilerAnomaly } from '../lib/domain-store-s5.mjs';
import { AnomalyResolutionError } from '../lib/errors-s5.mjs';
import { reconcilePass } from '../lib/reconciler.mjs';
import { backendReachable, scanIsolatedSocket, probeIdentityTransientAware } from '../lib/backend-scan-s5.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// S5 owns the reconciler pass, anomaly authorship + resolve-anomaly, and the S3-deferred
// binding transitions (lost/bound_unverified) and identity_lost event. Every reconciled
// domain change is an ordinary envelope mutation (+1 tasks.revision / +1 domain / +1
// commit); every anomaly observation is an audit (+1 domain/commit, no task revision);
// projection_revision stays 0 throughout (projections are S6); and the reconciler NEVER
// kills, deletes, or adopts. No test here uses a table or verb owned by a later slice.
after(cleanupAll);

const IDENTITY = {
  endpointId: '@0', paneId: '%0', bootId: 'boot-xyz',
  paneLeaderPid: 4242, paneStartTicks: 111111,
  agentPid: 4243, agentStartTicks: 222222, agentExe: '/usr/bin/node',
  agentArgvHash: 'argvhash-abc', agentPpid: 4242, agentPty: 'pts/7',
  worktree: '/tmp/wt', harness: 'claude'
};
const captureOk = () => ({ ok: true, identity: { ...IDENTITY } });
const probeMatch = () => ({ matches: true, failingClause: null, anomalyClass: null });
const probeGone = (clause = 'agent_pid', anomalyClass = 'missing_pane') =>
  () => ({ matches: false, failingClause: clause, anomalyClass });
const probeTransient = () =>
  ({ matches: false, transient: true, failingClause: 'boot_id', anomalyClass: 'running_without_verification' });
const FAR_FUTURE = '2999-01-01T00:00:00.000Z';

async function freshStore() {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'test' });
  return { store, fmHome };
}

async function rows(store, sql, params) {
  return runExclusive(store, async (conn) => (await conn.query(sql, params)).rows);
}
async function counters(store) {
  const r = await rows(
    store, 'SELECT domain_revision, projection_revision, commit_sequence FROM coordinator_state WHERE id = 1'
  );
  return { domain: Number(r[0].domain_revision), projection: Number(r[0].projection_revision), commit: Number(r[0].commit_sequence) };
}
async function runRow(store, taskId, generation = 1) {
  const r = await rows(
    store,
    `SELECT status, binding_state, cleanup_state, closed_at, endpoint_id, verified_at FROM runs WHERE task_id = $1 AND run_generation = $2`,
    [taskId, generation]
  );
  return r[0];
}
async function taskRow(store, taskId) {
  const r = await rows(store, 'SELECT status, revision FROM tasks WHERE task_id = $1', [taskId]);
  return r[0];
}
async function events(store, taskId) {
  return rows(
    store,
    'SELECT event_type, producer_id, producer_seq FROM task_events WHERE task_id = $1 ORDER BY created_at, producer_seq',
    [taskId]
  );
}
async function eventCount(store, taskId, type) {
  const r = await rows(store, 'SELECT count(*)::int AS n FROM task_events WHERE task_id = $1 AND event_type = $2', [taskId, type]);
  return Number(r[0].n);
}
async function anomalyRows(store, cls) {
  return runExclusive(store, async (conn) => {
    const reg = await conn.query("SELECT to_regclass('public.anomalies') AS reg");
    if (reg.rows[0].reg === null) return [];
    const r = await conn.query(
      'SELECT fingerprint, anomaly_class, task_id, run_generation, occurrence_count, status, resolution_kind FROM anomalies WHERE anomaly_class = $1',
      [cls]
    );
    return r.rows;
  });
}
async function runCount(store) {
  return Number((await rows(store, 'SELECT count(*)::int AS n FROM runs'))[0].n);
}

// ---- lifecycle builders ----
async function beganTask(store, taskId = 't1') {
  await createTask(store, { taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  return { revision: beg.revision, launchMarker: beg.launch_marker };
}
async function spawnedTask(store, taskId = 't1') {
  const { revision, launchMarker } = await beganTask(store, taskId);
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: revision, launchMarker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: `c-spawn-${taskId}`
  }, { captureIdentity: captureOk });
  return rs.revision;
}
async function runningTask(store, taskId = 't1') {
  const rev = await spawnedTask(store, taskId);
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rev, commandId: `c-run-${taskId}` }, { probeIdentity: probeMatch });
  return cr.revision;
}
async function cleanupPendingTask(store, taskId = 't1') {
  const rev = await runningTask(store, taskId);
  const done = await completeRun(store, { taskId, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${taskId}` });
  return done.revision;
}

test('t_reconcile_promotes_verified_spawning_idempotently', async () => {
  const { store } = await freshStore();
  const rev = await spawnedTask(store, 't1'); // spawning, endpoint recorded
  const before = await counters(store);

  const r1 = await reconcilePass(store, { nonce: 'pass-A', probeIdentity: probeMatch });
  assert.equal(r1.committed.length, 1);
  assert.equal(r1.committed[0].kind, 'promote');

  const task = await taskRow(store, 't1');
  assert.equal(task.status, 'running', 'the reconciler promoted the verified spawning generation');
  assert.equal(Number(task.revision), rev + 1);
  const run = await runRow(store, 't1');
  assert.equal(run.status, 'open');
  assert.equal(run.binding_state, 'bound_verified');
  assert.notEqual(run.verified_at, null);

  // The running_verified is attributed to the RECONCILER, not the coordinator (ruling Q2).
  const ev = await events(store, 't1');
  const rv = ev.filter((e) => e.event_type === 'running_verified');
  assert.equal(rv.length, 1);
  assert.equal(rv[0].producer_id, 'reconciler', 'the promotion is attributed to producer reconciler');
  assert.deepEqual(await counters(store), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });

  // Rerun is idempotent: the promoted generation is no longer a spawning promote
  // candidate, so exactly one promotion survives, no second running_verified, and no
  // counter movement - regardless of nonce.
  const afterFirst = await counters(store);
  const r2 = await reconcilePass(store, { nonce: 'pass-A', probeIdentity: probeMatch });
  assert.equal(r2.committed.length, 0, 'the already-promoted generation is not re-promoted');
  assert.equal(await eventCount(store, 't1', 'running_verified'), 1, 'no second running_verified on the rerun');
  assert.deepEqual(await counters(store), afterFirst, 'a rerun over a settled promotion bumps nothing');
});

test('t_reconcile_fails_only_deadline_expired_unmatched', async () => {
  const { store } = await freshStore();
  const rev = await spawnedTask(store, 't1'); // spawning, endpoint recorded
  const before = await counters(store);

  // Unmatched but still WITHIN the launch window: the reconciler leaves it spawning and
  // commits nothing. deadlineNow defaults to now, and launch_deadline_at is now + window.
  const inWindow = await reconcilePass(store, { nonce: 'p1', probeIdentity: probeGone() });
  assert.equal(inWindow.committed.length, 0, 'no fail while still inside the launch window');
  assert.equal((await runRow(store, 't1')).status, 'spawning');
  assert.equal((await taskRow(store, 't1')).status, 'spawning');
  assert.deepEqual(await counters(store), before, 'an in-window unmatched spawning run is left untouched');

  // Past the launch deadline AND unmatched: partial-launch fail via the S2 fail path.
  const past = await reconcilePass(store, { nonce: 'p2', probeIdentity: probeGone(), deadlineNow: FAR_FUTURE });
  assert.equal(past.committed.length, 1);
  assert.equal(past.committed[0].kind, 'fail');
  const run = await runRow(store, 't1');
  assert.equal(run.status, 'failed', 'a partial launch past its deadline is failed');
  assert.notEqual(run.closed_at, null);
  const task = await taskRow(store, 't1');
  assert.equal(task.status, 'failed');
  assert.equal(Number(task.revision), rev + 1);
  // The terminal is a `failed`/`failure`, authored by the reconciler.
  const failed = await rows(store, "SELECT producer_id, outcome FROM task_events WHERE task_id = 't1' AND event_type = 'failed'");
  assert.equal(failed.length, 1);
  assert.equal(failed[0].producer_id, 'reconciler');
  assert.equal(failed[0].outcome, 'failure');
});

test('t_reconcile_never_fails_a_matched_spawning_run_even_past_deadline', async () => {
  const { store } = await freshStore();
  const rev = await spawnedTask(store, 't1');
  // Past the deadline but the identity IS live: the reconciler promotes (a late success),
  // it does NOT fail. Deadline gates the FAIL, not the promotion.
  const r = await reconcilePass(store, { nonce: 'p', probeIdentity: probeMatch, deadlineNow: FAR_FUTURE });
  assert.equal(r.committed[0].kind, 'promote');
  assert.equal((await taskRow(store, 't1')).status, 'running');
  assert.equal(Number((await taskRow(store, 't1')).revision), rev + 1);
});

test('t_reconcile_marks_bound_unverified_on_transient', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1'); // open, bound_verified
  const before = await counters(store);

  const r = await reconcilePass(store, { nonce: 'p1', probeIdentity: probeTransient });
  // A transient demotion authors running_without_verification (the "why") AND demotes the
  // binding - finding 5. Two commits, anomaly first.
  assert.deepEqual(r.committed.map((c) => c.kind), ['running_without_verification', 'mark_unverified']);
  const run = await runRow(store, 't1');
  assert.equal(run.binding_state, 'bound_unverified', 'a transient probe failure demotes the binding, not loses it');
  assert.equal(run.status, 'open', 'the run stays open on a transient demotion');
  assert.equal(await eventCount(store, 't1', 'identity_lost'), 0, 'a transient demotion emits no identity_lost');
  assert.equal((await anomalyRows(store, 'running_without_verification')).length, 1, 'the transient demotion is explained by a running_without_verification anomaly');
  assert.equal(Number((await taskRow(store, 't1')).revision), rev + 1);
  // Anomaly audit (+1) + binding demotion (+1) = +2 domain/commit, +1 task revision.
  assert.deepEqual(await counters(store), { domain: before.domain + 2, projection: 0, commit: before.commit + 2 });

  // Re-running while it is already bound_unverified is a no-op: no counter noise.
  const afterDemote = await counters(store);
  const r2 = await reconcilePass(store, { nonce: 'p2', probeIdentity: probeTransient });
  assert.equal(r2.committed.length, 0, 'an already-unverified binding is left untouched');
  assert.deepEqual(await counters(store), afterDemote);

  // Recovery: a live match re-verifies the binding back to bound_verified (reconciler).
  const r3 = await reconcilePass(store, { nonce: 'p3', probeIdentity: probeMatch });
  assert.equal(r3.committed[0].kind, 'reverify');
  assert.equal((await runRow(store, 't1')).binding_state, 'bound_verified', 'a live match re-verifies a transiently-demoted binding');
  const rv = await rows(store, "SELECT producer_id FROM task_events WHERE task_id = 't1' AND event_type = 'running_verified' ORDER BY created_at");
  assert.equal(rv[rv.length - 1].producer_id, 'reconciler', 'the re-verification is attributed to the reconciler');
});

test('t_reconcile_marks_lost_and_emits_identity_lost', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1'); // open, bound_verified
  const before = await counters(store);

  const r = await reconcilePass(store, { nonce: 'p1', probeIdentity: probeGone('agent_pid', 'missing_pane') });
  const kinds = r.committed.map((c) => c.kind);
  // A provably-dead open generation is handled in ONE pass (finding 6, spec 491): audit the
  // specific identity failure, audit binding_lost_under_active, then emit identity_lost
  // (binding -> lost) AND terminally fail through the S2 path - never left open/lost.
  assert.deepEqual(kinds, ['missing_pane', 'binding_lost_under_active', 'fail_lost']);

  const run = await runRow(store, 't1');
  assert.equal(run.status, 'failed', 'the provably-dead generation is terminally failed in the same pass');
  assert.notEqual(run.closed_at, null, 'the failed generation is closed');
  assert.equal(await eventCount(store, 't1', 'identity_lost'), 1, 'exactly one identity_lost event (the loss audit) precedes the terminal');
  const il = await rows(store, "SELECT producer_id, payload_json FROM task_events WHERE task_id = 't1' AND event_type = 'identity_lost'");
  assert.equal(il[0].producer_id, 'reconciler');
  const payload = typeof il[0].payload_json === 'string' ? JSON.parse(il[0].payload_json) : il[0].payload_json;
  assert.equal(payload.failing_clause, 'agent_pid');
  // The failed terminal is authored by the reconciler with outcome 'failure'.
  const failed = await rows(store, "SELECT producer_id, outcome FROM task_events WHERE task_id = 't1' AND event_type = 'failed'");
  assert.equal(failed.length, 1);
  assert.equal(failed[0].producer_id, 'reconciler');
  assert.equal(failed[0].outcome, 'failure');
  assert.equal((await taskRow(store, 't1')).status, 'failed');

  assert.equal((await anomalyRows(store, 'missing_pane')).length, 1);
  assert.equal((await anomalyRows(store, 'binding_lost_under_active')).length, 1);
  // missing_pane audit (+1) + binding_lost_under_active audit (+1) + identity_lost transition
  // (+1) + terminal fail (+1) = +4 domain/commit; the task revision advances twice (lost, fail).
  assert.deepEqual(await counters(store), { domain: before.domain + 4, projection: 0, commit: before.commit + 4 });
  assert.equal(Number((await taskRow(store, 't1')).revision), rev + 2, 'identity_lost then terminal fail advance the revision twice');

  // The generation is now terminal, so a rerun finds nothing to do - no duplicate terminal.
  const r2 = await reconcilePass(store, { nonce: 'p2', probeIdentity: probeGone('agent_pid', 'missing_pane') });
  assert.equal(r2.committed.length, 0, 'a rerun over the settled terminal does nothing');
  assert.equal(await eventCount(store, 't1', 'failed'), 1, 'still exactly one terminal - no duplicate');
});

test('t_reconcile_recovers_stranded_lost_binding_on_live_match', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1'); // open, bound_verified
  // Simulate a binding that momentarily read 'lost' (e.g. an interrupted loss pass or a
  // transient failure misclassified). Force the run to open/lost directly.
  await runExclusive(store, (conn) => conn.query("UPDATE runs SET binding_state = 'lost' WHERE task_id = 't1' AND run_generation = 1"));
  const before = await counters(store);

  // The EXACT stored identity reappears live: the reconciler re-verifies the stranded lost
  // binding back to bound_verified rather than leaving open/lost as a stable state (finding 6).
  const r = await reconcilePass(store, { nonce: 'rec', probeIdentity: probeMatch });
  assert.deepEqual(r.committed.map((c) => c.kind), ['reverify']);
  const run = await runRow(store, 't1');
  assert.equal(run.binding_state, 'bound_verified', 'a live match recovers a stranded lost binding');
  assert.equal(run.status, 'open');
  const rv = await rows(store, "SELECT producer_id FROM task_events WHERE task_id = 't1' AND event_type = 'running_verified' ORDER BY created_at");
  assert.equal(rv[rv.length - 1].producer_id, 'reconciler');
  assert.deepEqual(await counters(store), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });
  assert.equal(Number((await taskRow(store, 't1')).revision), rev + 1);
});

test('t_anomaly_fingerprint_matches_spec_concatenation', async () => {
  // Finding 7: the persisted fingerprint MUST equal the ratified spec-819-825 formula -
  // sha256 of the DIRECT concatenation (no delimiter) of the nine positional fields, a
  // null field contributing the empty string - matching launchMarkerFor's convention.
  const { store } = await freshStore();
  await runningTask(store, 't1');
  await reconcilePass(store, {
    nonce: 'fp', datadirSize: () => 9_999_999, datadirLimitBytes: 1
  });
  const homeUuid = (await rows(store, "SELECT value FROM schema_meta WHERE key = 'home_uuid'"))[0].value;
  const row = (await rows(store, "SELECT fingerprint, anomaly_class, terminal_fingerprint FROM anomalies WHERE anomaly_class = 'datadir_size_tripwire'"))[0];
  // datadir_size_tripwire carries only home_uuid, class, and terminal_fingerprint='datadir';
  // every other positional field is null -> empty string.
  const expected = sha256hex(`${homeUuid}${'datadir_size_tripwire'}${''}${''}${''}${''}${''}${''}${'datadir'}`);
  assert.equal(row.fingerprint, expected, 'the datadir tripwire fingerprint is the exact spec-819-825 direct concatenation');
  // Prove sensitivity: a NUL-delimited join (the pre-fix formula) would differ.
  const nulJoined = sha256hex([homeUuid, 'datadir_size_tripwire', '', '', '', '', '', '', 'datadir'].join('\u0000'));
  assert.notEqual(row.fingerprint, nulJoined, 'and is NOT the old NUL-delimited digest');
});

test('t_reconcile_never_kills_or_adopts_markerless', async () => {
  const { store } = await freshStore();
  await runningTask(store, 't1'); // one legitimate running run with its own marker/endpoint
  const t1Marker = (await rows(store, "SELECT launch_marker FROM runs WHERE task_id = 't1'"))[0].launch_marker;
  const runsBefore = await runCount(store);
  const before = await counters(store);

  // The isolated cp socket scan surfaces a MARKERLESS pane and an UNKNOWN-marker pane:
  // both are orphans. The legitimate run's own marker-bearing pane is present in the scan
  // (so it is neither orphan nor missing). The reconciler records an anomaly for each
  // orphan and does NOT adopt them into a run or kill them (it has no kill/adopt path).
  const scan = () => ([
    { endpointId: '@0', paneId: '%0', marker: t1Marker },
    { endpointId: '@9', paneId: '%9', marker: null },
    { endpointId: '@8', paneId: '%8', marker: 'some-unknown-marker' }
  ]);
  const r = await reconcilePass(store, { nonce: 'orph', probeIdentity: probeMatch, scanMarkers: scan });
  const orphanKinds = r.committed.filter((c) => c.kind === 'orphan_pane');
  assert.equal(orphanKinds.length, 2, 'both the markerless and unknown-marker panes are recorded as orphans');

  const orphans = await anomalyRows(store, 'orphan_pane');
  assert.equal(orphans.length, 2, 'exactly two orphan_pane anomalies persisted');
  for (const o of orphans) assert.equal(o.status, 'active');

  // NOTHING was adopted or killed: no new run row, and the one legitimate run is untouched.
  assert.equal(await runCount(store), runsBefore, 'no run was adopted for an orphan pane');
  assert.equal((await runRow(store, 't1')).status, 'open', 'the legitimate run was not disturbed');
  // Two orphan audits = +2 domain/commit, no task revision moved.
  assert.deepEqual(await counters(store), { domain: before.domain + 2, projection: 0, commit: before.commit + 2 });
});

test('t_anomaly_fingerprint_and_coalesce', async () => {
  const { store } = await freshStore();
  await runningTask(store, 't1');
  const t1Marker = (await rows(store, "SELECT launch_marker FROM runs WHERE task_id = 't1'"))[0].launch_marker;
  const scan = () => ([{ endpointId: '@0', paneId: '%0', marker: t1Marker }, { endpointId: '@7', paneId: '%7', marker: null }]);

  // Two passes with DIFFERENT nonces re-observe the SAME orphan: one row, occurrence_count
  // climbs to 2, and each observation is its own +1 domain/commit audit.
  const p1 = await reconcilePass(store, { nonce: 'n1', probeIdentity: probeMatch, scanMarkers: scan });
  const afterP1 = await counters(store);
  const p2 = await reconcilePass(store, { nonce: 'n2', probeIdentity: probeMatch, scanMarkers: scan });

  const orphans = await anomalyRows(store, 'orphan_pane');
  assert.equal(orphans.length, 1, 'the reobservation coalesces onto the same fingerprint, not a new row');
  assert.equal(Number(orphans[0].occurrence_count), 2, 'reobservation increments occurrence_count (spec 827)');
  assert.equal(p1.committed.length, 1);
  assert.equal(p2.committed.length, 1);
  assert.deepEqual(await counters(store), { domain: afterP1.domain + 1, projection: 0, commit: afterP1.commit + 1 }, 'the second observation is one more audit');
});

test('t_datadir_size_tripwire', async () => {
  const { store } = await freshStore();
  const before = await counters(store);

  // Under the limit: no tripwire.
  const under = await reconcilePass(store, { nonce: 'd1', datadirSize: () => 10, datadirLimitBytes: 1000 });
  assert.equal(under.committed.filter((c) => c.kind === 'datadir_size_tripwire').length, 0);
  assert.equal((await anomalyRows(store, 'datadir_size_tripwire')).length, 0);
  assert.deepEqual(await counters(store), before, 'a datadir under the limit trips nothing');

  // Over the limit: one datadir_size_tripwire anomaly.
  const over = await reconcilePass(store, { nonce: 'd2', datadirSize: () => 5000, datadirLimitBytes: 1000 });
  assert.equal(over.committed.filter((c) => c.kind === 'datadir_size_tripwire').length, 1);
  const trip = await anomalyRows(store, 'datadir_size_tripwire');
  assert.equal(trip.length, 1);
  assert.equal(trip[0].task_id, null, 'the tripwire is a fleet-scope anomaly, not tied to a task');
  assert.deepEqual(await counters(store), { domain: before.domain + 1, projection: 0, commit: before.commit + 1 });

  // A --task-scoped pass never runs the fleet-wide datadir check.
  await runningTask(store, 't1');
  const scoped = await reconcilePass(store, { nonce: 'd3', taskId: 't1', probeIdentity: probeMatch, datadirSize: () => 5000, datadirLimitBytes: 1000 });
  assert.equal(scoped.committed.filter((c) => c.kind === 'datadir_size_tripwire').length, 0, 'a task-scoped pass skips the fleet-wide tripwire');
});

test('t_reconcile_pass_idempotent_no_counter_noise', async () => {
  const { store } = await freshStore();
  await runningTask(store, 't1'); // healthy, bound_verified
  const settled = await counters(store);

  // A settled fleet with a live match has nothing to reconcile: zero commits, zero counter
  // movement, no matter how many times it runs.
  for (const nonce of ['s1', 's2', 's3']) {
    const r = await reconcilePass(store, { nonce, probeIdentity: probeMatch });
    assert.equal(r.committed.length, 0, `settled pass ${nonce} commits nothing`);
  }
  assert.deepEqual(await counters(store), settled, 'a settled fleet is perfectly quiet across repeated passes');
});

test('t_resolve_anomaly_predicates_enforced_row_preserved', async () => {
  const { store } = await freshStore();
  await runningTask(store, 't1');
  const t1Marker = (await rows(store, "SELECT launch_marker FROM runs WHERE task_id = 't1'"))[0].launch_marker;
  // Author an orphan_pane (captain-routed) and a datadir_size_tripwire (agent-level).
  await reconcilePass(store, {
    nonce: 'auth', probeIdentity: probeMatch,
    scanMarkers: () => ([{ endpointId: '@0', paneId: '%0', marker: t1Marker }, { endpointId: '@5', paneId: '%5', marker: null }]),
    datadirSize: () => 9999, datadirLimitBytes: 10
  });
  const orphanFp = (await anomalyRows(store, 'orphan_pane'))[0].fingerprint;
  const datadirFp = (await anomalyRows(store, 'datadir_size_tripwire'))[0].fingerprint;

  // Ruling Q4: an orphan_pane may NOT be resolved on agent authority.
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: orphanFp, reason: 'looked ok', resolutionKind: 'agent_verified', commandId: 'rq-1' }),
    (e) => e instanceof AnomalyResolutionError && /captain-routed/.test(e.message),
    'orphan_pane rejects an agent-level resolution'
  );
  // The refused resolution persisted nothing: the row is still active.
  assert.equal((await anomalyRows(store, 'orphan_pane'))[0].status, 'active');

  // human_approved resolves the orphan; the row is PRESERVED (still present), status flips.
  const resolved = await resolveAnomaly(store, { fingerprint: orphanFp, reason: 'captain dismissed', resolutionKind: 'human_approved', commandId: 'rq-2' });
  assert.equal(resolved.status, 'resolved');
  const orphanAfter = await anomalyRows(store, 'orphan_pane');
  assert.equal(orphanAfter.length, 1, 'the resolved anomaly row is preserved, never deleted (spec 597/828)');
  assert.equal(orphanAfter[0].status, 'resolved');
  assert.equal(orphanAfter[0].resolution_kind, 'human_approved');

  // A non-orphan class resolves on agent authority.
  const dd = await resolveAnomaly(store, { fingerprint: datadirFp, reason: 'pruned datadir', resolutionKind: 'agent_verified', commandId: 'rq-3' });
  assert.equal(dd.status, 'resolved');

  // Re-resolving an already-resolved row with a DIFFERENT command is refused (rows are not
  // re-resolved); the same command-id would replay the stored result instead.
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: datadirFp, reason: 'again', resolutionKind: 'benign', commandId: 'rq-4' }),
    (e) => e instanceof AnomalyResolutionError && /already resolved/.test(e.message)
  );
  // An unknown fingerprint and an invalid resolution-kind both reject loudly.
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: 'nope', reason: 'x', resolutionKind: 'benign', commandId: 'rq-5' }),
    (e) => e instanceof AnomalyResolutionError && /unknown anomaly fingerprint/.test(e.message)
  );
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: datadirFp, reason: 'x', resolutionKind: 'not-a-kind', commandId: 'rq-6' }),
    (e) => e instanceof AnomalyResolutionError && /resolution-kind must be one of/.test(e.message)
  );

  // The idempotent replay of a resolution returns the stored result, no error, no change.
  const replay = await resolveAnomaly(store, { fingerprint: orphanFp, reason: 'captain dismissed', resolutionKind: 'human_approved', commandId: 'rq-2' });
  assert.equal(replay.status, 'resolved');

  // listAnomalies --active hides the two resolved rows.
  const active = await listAnomalies(store, { activeOnly: true });
  assert.equal(active.anomalies.some((a) => a.fingerprint === orphanFp || a.fingerprint === datadirFp), false, 'resolved anomalies drop out of the active list');
  const all = await listAnomalies(store, {});
  assert.equal(all.anomalies.some((a) => a.fingerprint === orphanFp), true, 'but remain in the full ledger');
});

// Fetch the fingerprint of the single active anomaly of a class (optionally pinned by
// terminal_fingerprint), for classes authored by the real envelope rather than returned.
async function fpOf(store, cls, terminalFp) {
  const r = await runExclusive(store, async (conn) => {
    const sql = terminalFp
      ? 'SELECT fingerprint FROM anomalies WHERE anomaly_class = $1 AND terminal_fingerprint = $2'
      : 'SELECT fingerprint FROM anomalies WHERE anomaly_class = $1';
    return (await conn.query(sql, terminalFp ? [cls, terminalFp] : [cls])).rows;
  });
  return r[0]?.fingerprint;
}

test('t_resolve_anomaly_class_predicates', async () => {
  // Finding 3: resolve-anomaly enforces the FULL class-specific spec-830-840 predicates
  // against the canonical rows, positive AND negative. The human_approved gate applies ONLY
  // to markerless orphans; every other class is gated on its real canonical precondition.
  const { store } = await freshStore();
  await runningTask(store, 't1');
  const t1 = (await rows(store, "SELECT launch_marker, endpoint_id, pane_id FROM runs WHERE task_id = 't1'"))[0];

  // --- marker-bearing orphan adoption: needs bound_verified + FULL endpoint AND pane match ---
  // NEGATIVE: endpoint matches but pane does not.
  const orphanPaneMiss = await recordReconcilerAnomaly(store, {
    anomalyClass: 'orphan_pane', endpointId: t1.endpoint_id, paneId: '%WRONG', terminalFingerprint: t1.launch_marker,
    detail: { reason: 'unknown_marker' }, commandId: 'a-orphan-panemiss'
  });
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: orphanPaneMiss.fingerprint, reason: 'x', resolutionKind: 'agent_verified', commandId: 'r-orphan-panemiss' }),
    (e) => e instanceof AnomalyResolutionError && /neither safely adopted.*nor exactly cleaned/.test(e.message),
    'adoption requires the pane to match, not endpoint alone'
  );
  // human_approved does NOT bypass a marker-bearing orphan predicate.
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: orphanPaneMiss.fingerprint, reason: 'x', resolutionKind: 'human_approved', commandId: 'r-orphan-panemiss2' }),
    (e) => e instanceof AnomalyResolutionError,
    'human approval does not substitute for the marker-bearing orphan predicate'
  );
  // POSITIVE: full endpoint+pane match on a bound_verified run.
  const orphanOk = await recordReconcilerAnomaly(store, {
    anomalyClass: 'orphan_pane', endpointId: t1.endpoint_id, paneId: t1.pane_id, terminalFingerprint: t1.launch_marker,
    detail: { reason: 'unknown_marker' }, commandId: 'a-orphan-ok'
  });
  assert.equal((await resolveAnomaly(store, { fingerprint: orphanOk.fingerprint, reason: 'adopted, verified', resolutionKind: 'agent_verified', commandId: 'r-orphan-ok' })).status, 'resolved');

  // --- terminal_conflict: the WHOLE chain (single terminal + outbox acked + cleanup cleaned
  //     + conflicting command deterministically rejected with no mutation) ---
  const rev2 = await runningTask(store, 't2');
  const done2 = await completeRun(store, { taskId: 't2', generation: 1, expectedRevision: rev2, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done-t2' });
  // A REAL terminal conflict: a second terminal on the now-closed generation.
  await assert.rejects(
    () => failRun(store, { taskId: 't2', generation: 1, expectedRevision: done2.revision, reason: 'second terminal', producer: 'firstmate', seq: 2, commandId: 'c-conflict-t2' }),
    (e) => e.code === 'terminal_conflict'
  );
  const tcFp = await fpOf(store, 'terminal_conflict', 't2:1');
  // NEGATIVE: the terminal delivery is not yet acked.
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: tcFp, reason: 'x', resolutionKind: 'agent_verified', commandId: 'r-tc-noack' }),
    (e) => e instanceof AnomalyResolutionError && /not yet acked/.test(e.message),
    'terminal_conflict cannot resolve before the terminal delivery is acked'
  );
  // Ack the delivery (S4's job; set the canonical fact directly here) - still not cleaned.
  await runExclusive(store, (conn) => conn.query("UPDATE outbox SET acked_at = now() WHERE task_id = 't2'"));
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: tcFp, reason: 'x', resolutionKind: 'agent_verified', commandId: 'r-tc-nocleanup' }),
    (e) => e instanceof AnomalyResolutionError && /cleanup .* not complete/.test(e.message),
    'terminal_conflict cannot resolve before cleanup is complete'
  );
  // Finish cleanup, so the whole chain holds. POSITIVE.
  const intent2 = await cleanupIntent(store, { taskId: 't2', generation: 1, expectedRevision: done2.revision, commandId: 'c-intent-t2' });
  await cleanupFinish(store, { taskId: 't2', generation: 1, expectedRevision: intent2.revision, effectResult: { confirmed_absent: true }, commandId: 'c-finish-t2' });
  assert.equal((await resolveAnomaly(store, { fingerprint: tcFp, reason: 'canonical chain complete', resolutionKind: 'agent_verified', commandId: 'r-tc-ok' })).status, 'resolved', 'terminal_conflict resolves once terminal+ack+cleanup hold and the conflicting command left no result');

  // --- idempotency_conflict: deterministic stored result + real different payload ---
  await createTask(store, { taskId: 'ti', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'idem-key' });
  await assert.rejects( // same command-id, different payload
    () => createTask(store, { taskId: 'tj', kind: 'ship', title: 'y', origin: 'internal', internalReason: 'r', commandId: 'idem-key' }),
    (e) => e.code === 'idempotency_conflict'
  );
  const idemFp = await fpOf(store, 'idempotency_conflict', 'idem-key');
  assert.equal((await resolveAnomaly(store, { fingerprint: idemFp, reason: 'stored result deterministic; reuse rejected', resolutionKind: 'agent_verified', commandId: 'r-idem-ok' })).status, 'resolved');

  // --- causal_ordering_violation: a REAL stale-revision rejection resolves; a FABRICATED one does not ---
  await createTask(store, { taskId: 'tc', kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: 'c-tc' });
  await beginRun(store, { taskId: 'tc', expectedRevision: 1, commandId: 'c-tc-begin1' }); // rev 1 -> 2
  await assert.rejects( // stale token (expected 1, actual 2)
    () => beginRun(store, { taskId: 'tc', expectedRevision: 1, commandId: 'c-tc-begin-stale' }),
    (e) => e.code === 'causal_ordering_violation'
  );
  const causalFp = await fpOf(store, 'causal_ordering_violation', 'c-tc-begin-stale');
  assert.equal((await resolveAnomaly(store, { fingerprint: causalFp, reason: 'token stale, revision advanced, no mutation', resolutionKind: 'agent_verified', commandId: 'r-causal-ok' })).status, 'resolved', 'a real stale-revision causal conflict resolves');
  // FABRICATED causal anomaly naming a never-executed key with no facts: NOT resolvable.
  const fabFp = (await recordReconcilerAnomaly(store, { anomalyClass: 'causal_ordering_violation', terminalFingerprint: 'never-executed-key', detail: {}, commandId: 'a-causal-fab' })).fingerprint;
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: fabFp, reason: 'x', resolutionKind: 'agent_verified', commandId: 'r-causal-fab' }),
    (e) => e instanceof AnomalyResolutionError && /fabricated or unverifiable|command key\/causal facts/.test(e.message),
    'a fabricated causal anomaly without a deterministic rejected command cannot resolve'
  );

  // --- out-of-slice class: rejected (S4/S6 owns the predicate) ---
  const spFp = (await recordReconcilerAnomaly(store, { anomalyClass: 'stale_projection', terminalFingerprint: 'proj-1', detail: {}, commandId: 'a-sp' })).fingerprint;
  await assert.rejects(
    () => resolveAnomaly(store, { fingerprint: spFp, reason: 'x', resolutionKind: 'agent_verified', commandId: 'r-sp' }),
    (e) => e instanceof AnomalyResolutionError && /owned by another slice/.test(e.message),
    'a projection/consumer class is not resolvable in S5'
  );

  // --- a reconciler observation class with no spec predicate: agent-level ---
  const mpFp = (await recordReconcilerAnomaly(store, { anomalyClass: 'missing_pane', taskId: 'tc', generation: 1, terminalFingerprint: 'mk', detail: {}, commandId: 'a-mp' })).fingerprint;
  assert.equal((await resolveAnomaly(store, { fingerprint: mpFp, reason: 'operator remediated', resolutionKind: 'agent_verified', commandId: 'r-mp' })).status, 'resolved', 'a reconciler observation class resolves on agent authority');
});

test('t_production_probe_reports_transient_on_unreachable_backend', async () => {
  // Finding 4: the production probe seam distinguishes a TRANSIENT/backend-unverified
  // failure (the isolated tmux server could not be reached) from a definitive absence. An
  // isolated socket with no server is unreachable, so the probe reports transient - NOT a
  // proof of death - and the marker scan returns null (no scan performed), not [].
  const socket = `cp-s5-unreachable-${process.pid}`;
  const reachable = backendReachable(socket);
  // On a host without a server on this socket (and even without tmux at all), unreachable.
  if (reachable) return; // extraordinarily unlikely; skip rather than assert a live server
  const probe = probeIdentityTransientAware({
    run: { endpoint_id: '@0', pane_id: '%0', boot_id: 'b', pane_leader_pid: 1, pane_start_ticks: 1, agent_pid: 1, agent_start_ticks: 1, agent_exe: '/x', agent_argv_hash: 'h', agent_ppid: 1, agent_pty: 'p' },
    socket
  });
  assert.equal(probe.matches, false);
  assert.equal(probe.transient, true, 'an unreachable backend is a transient failure, not proof of death');
  assert.equal(probe.anomalyClass, 'running_without_verification');
  assert.equal(scanIsolatedSocket(socket), null, 'an unreachable socket yields a null scan (not an empty array)');
});
