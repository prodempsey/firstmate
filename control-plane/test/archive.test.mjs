import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { runVerb } from '../lib/coordinator.mjs';
import { StateTransitionError } from '../lib/errors-s1.mjs';
import { createTask, beginRun, appendEvent } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import { recordSpawn, commitRunning, cleanupIntent, cleanupFinish } from '../lib/domain-store-s3.mjs';
import { claimConsumer, claimDelivery, markApplied, ack } from '../lib/domain-store-s4.mjs';
import { archiveTask } from '../lib/domain-store-archive.mjs';
import { isDeliverable } from '../lib/delivery-policy.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// `cp archive` (spec-amend-s4 section 4 line 482, section 6 line 585): the distinct
// terminal-archive verb {completed|failed} -> archived, gated on terminal state AND the
// current generation's terminal outbox acked (S4) AND cleanup 'cleaned' (S3). The
// `archived` event is audit-only (no outbox row), the mutation is an ordinary CAS
// envelope (domain+commit +1, projection untouched), and replay is idempotent. There is
// no needs_human -> archived path (spec 484), and archive is distinct from queued-only
// cancel (spec 487-489).
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

async function taskRow(store, taskId) {
  const r = await rows(store, 'SELECT status, revision, archived_at FROM tasks WHERE task_id = $1', [taskId]);
  return r[0];
}

// Ordered by wall-clock: producer_seq is per (scope, generation) namespace, so the
// task-scope `archived` event (coordinator seq 2) does NOT sort after run-scope events
// by producer_seq. created_at is the cross-namespace chronological order.
async function eventTypes(store, taskId) {
  const r = await rows(
    store, 'SELECT event_type FROM task_events WHERE task_id = $1 ORDER BY created_at, event_type', [taskId]
  );
  return r.map((x) => x.event_type);
}

async function outboxCount(store, taskId) {
  const r = await rows(store, 'SELECT count(*)::int AS n FROM outbox WHERE task_id = $1', [taskId]);
  return Number(r[0].n);
}

// ---- lifecycle builders (each advances the task revision) ----

// created(1) -> begin-run(2) -> record-spawn(3) -> commit-running(4). Uses the same
// deterministic identity double the S3 suites inject, so no real host is touched.
async function runningTask(store, taskId = 't1') {
  await createTask(store, {
    taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}`
  });
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: `c-spawn-${taskId}`
  }, { captureIdentity: captureOk });
  const cr = await commitRunning(store, {
    taskId, generation: 1, expectedRevision: rs.revision, commandId: `c-run-${taskId}`
  }, { probeIdentity: probeMatch });
  return cr.revision; // 4
}

// running -> completed (rev 5), leaving the terminal run binding cleanup_pending (a
// stored endpoint remains). Returns the current revision and the terminal outbox identity.
async function completedTask(store, taskId = 't1') {
  const rev = await runningTask(store, taskId);
  const done = await completeRun(store, {
    taskId, generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {},
    commandId: `c-done-${taskId}`
  });
  const r = await rows(
    store,
    "SELECT outbox_id, event_id FROM outbox WHERE task_id = $1 AND event_type IN ('completed','failed')",
    [taskId]
  );
  assert.equal(r.length, 1, 'exactly one terminal outbox row after complete');
  return { rev: done.revision, terminal: { outboxId: Number(r[0].outbox_id), eventId: r[0].event_id } };
}

// completed -> cleanup-intent(6) -> cleanup-finish(7): cleanup_state 'cleaned'.
async function cleanedTask(store, taskId = 't1') {
  const { rev, terminal } = await completedTask(store, taskId);
  const intent = await cleanupIntent(store, { taskId, generation: 1, expectedRevision: rev, commandId: `c-intent-${taskId}` });
  const fin = await cleanupFinish(store, {
    taskId, generation: 1, expectedRevision: intent.revision,
    effectResult: { killed: true, confirmed_absent: true }, commandId: `c-finish-${taskId}`
  });
  assert.equal(fin.cleanup_state, 'cleaned');
  return { rev: fin.revision, terminal };
}

// Drive the FirstMate consumer to ACK the terminal outbox row (claim -> claim-delivery
// -> mark-applied -> ack). No task-revision change: consumer verbs are not task-causal.
async function ackTerminal(store, terminal, taskId = 't1') {
  const lease = await claimConsumer(store, { bootId: 'boot-a', pid: 1000, commandId: `c-claim-${taskId}` });
  await claimDelivery(store, {
    outboxId: terminal.outboxId, ownerToken: lease.owner_token, ownerEpoch: lease.owner_epoch,
    sinkKind: 'disposition', commandId: `c-cd-${taskId}`
  });
  await markApplied(store, {
    eventId: terminal.eventId, ownerToken: lease.owner_token, ownerEpoch: lease.owner_epoch,
    sinkResult: { ok: true, event_id: terminal.eventId }, commandId: `c-ma-${taskId}`
  });
  await ack(store, {
    outboxId: terminal.outboxId, ownerToken: lease.owner_token, ownerEpoch: lease.owner_epoch,
    commandId: `c-ak-${taskId}`
  });
}

// Fully archivable: terminal + cleaned + terminal outbox acked (rev 7).
async function archivableTask(store, taskId = 't1') {
  const { rev, terminal } = await cleanedTask(store, taskId);
  await ackTerminal(store, terminal, taskId);
  return rev; // 7
}

// Each precondition individually missing rejects with a StateTransitionError that names
// the missing precondition; the other two preconditions hold in each case.
test('t_archive_requires_terminal_acked_cleaned', async () => {
  // (1) terminal state MISSING: a running task (acked/cleaned cannot exist without a
  // terminal, so the status guard is what must fire first).
  {
    const { store } = await freshStore();
    const rev = await runningTask(store, 't1'); // running, rev 4
    await assert.rejects(
      () => archiveTask(store, { taskId: 't1', expectedRevision: rev, commandId: 'arch-run' }),
      (err) => err instanceof StateTransitionError && /terminal task/.test(err.message),
      'archive on a non-terminal task is refused for the terminal precondition'
    );
    assert.equal((await taskRow(store, 't1')).status, 'running', 'refused archive mutates nothing');
  }

  // (2) terminal outbox NOT acked: cleaned but the terminal delivery was never acked.
  {
    const { store } = await freshStore();
    const { rev } = await cleanedTask(store, 't1'); // completed + cleaned, NOT acked, rev 7
    await assert.rejects(
      () => archiveTask(store, { taskId: 't1', expectedRevision: rev, commandId: 'arch-unacked' }),
      (err) => err instanceof StateTransitionError && /acked/.test(err.message),
      'archive without an acked terminal outbox is refused for the ack precondition'
    );
    assert.equal((await taskRow(store, 't1')).status, 'completed');
  }

  // (3) cleanup NOT cleaned: terminal + acked but the cleanup saga never finished.
  {
    const { store } = await freshStore();
    const { rev, terminal } = await completedTask(store, 't1'); // completed, cleanup_pending, rev 5
    await ackTerminal(store, terminal, 't1');
    await assert.rejects(
      () => archiveTask(store, { taskId: 't1', expectedRevision: rev, commandId: 'arch-uncleaned' }),
      (err) => err instanceof StateTransitionError && /cleanup/.test(err.message) && /cleaned/.test(err.message),
      'archive before cleanup is cleaned is refused for the cleanup precondition'
    );
    assert.equal((await taskRow(store, 't1')).status, 'completed');
  }
});

test('t_archive_sets_status_and_audit_event_no_outbox', async () => {
  const { store } = await freshStore();
  const rev = await archivableTask(store, 't1'); // rev 7
  const obBefore = await outboxCount(store, 't1'); // the single terminal delivery

  const res = await archiveTask(store, { taskId: 't1', expectedRevision: rev, commandId: 'arch-ok' });

  assert.equal(res.status, 'archived');
  assert.equal(res.revision, rev + 1);
  assert.equal(res.delivered, false, 'archive delivers nothing');
  assert.ok(res.archived_event_id, 'archive returns the audit event id');

  const trow = await taskRow(store, 't1');
  assert.equal(trow.status, 'archived', 'the task is archived');
  assert.equal(Number(trow.revision), rev + 1);
  assert.ok(trow.archived_at, 'archived_at is stamped');

  const types = await eventTypes(store, 't1');
  assert.equal(types.filter((t) => t === 'archived').length, 1, 'exactly one archived event');
  assert.ok(types.includes('completed') && types.includes('cleaned'), 'the archived event joins the durable terminal/cleanup trail');
  assert.equal(isDeliverable('archived'), false, 'the delivery policy classifies archived audit-only');
  assert.equal(await outboxCount(store, 't1'), obBefore, 'archive creates no outbox row');
});

test('t_archive_idempotent_replay', async () => {
  const { store } = await freshStore();
  const rev = await archivableTask(store, 't1');

  const r1 = await archiveTask(store, { taskId: 't1', expectedRevision: rev, commandId: 'arch-replay' });
  const after1 = await counters(store);
  const r2 = await archiveTask(store, { taskId: 't1', expectedRevision: rev, commandId: 'arch-replay' });
  const after2 = await counters(store);

  assert.deepEqual(r2, r1, 'a same-command replay returns the identical stored result');
  assert.deepEqual(after2, after1, 'replay is neither a write nor an audit: no counter moves');
  const types = await eventTypes(store, 't1');
  assert.equal(types.filter((t) => t === 'archived').length, 1, 'replay writes no second archived event');
  assert.equal(Number((await taskRow(store, 't1')).revision), rev + 1, 'replay does not re-bump the revision');
});

test('t_archive_rejects_needs_human_path', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1'); // running, rev 4
  // running -> needs_human via the generic event verb (spec section 4 transition table).
  const nh = await appendEvent(store, {
    taskId: 't1', generation: 1, eventType: 'needs_human', producer: 'crewmate', seq: 1,
    expectedRevision: rev, commandId: 'c-nh'
  });
  assert.equal(nh.status, 'needs_human');

  await assert.rejects(
    () => archiveTask(store, { taskId: 't1', expectedRevision: nh.revision, commandId: 'arch-nh' }),
    (err) => err instanceof StateTransitionError && /terminal task/.test(err.message),
    'there is no needs_human -> archived path (spec 484)'
  );
  assert.equal((await taskRow(store, 't1')).status, 'needs_human', 'the refused archive mutates nothing');
});

test('t_archive_counter_semantics', async () => {
  const { store } = await freshStore();
  const rev = await archivableTask(store, 't1');
  const before = await counters(store);

  await archiveTask(store, { taskId: 't1', expectedRevision: rev, commandId: 'arch-counters' });

  const after = await counters(store);
  assert.equal(after.domain, before.domain + 1, 'archive advances domain_revision by exactly one');
  assert.equal(after.commit, before.commit + 1, 'archive advances commit_sequence by exactly one');
  assert.equal(after.projection, before.projection, 'archive never touches projection_revision (S6)');
  assert.equal(before.projection, 0, 'projection_revision stays 0 (no projection ran)');
});

// The verb is wired end-to-end through the S0 coordinator registration and the archive
// dispatcher's arg parsing, not just callable as a domain function.
test('t_archive_cli_wired_through_coordinator', async () => {
  const { store, fmHome } = await freshStore();
  const rev = await archivableTask(store, 't1'); // rev 7
  const env = { ...process.env, FM_HOME: fmHome };

  const out = await runVerb(['archive', 't1', '--expected-revision', String(rev), '--command-id', 'cli-arch'], { env });
  assert.equal(out.ok, true);
  assert.equal(out.result.status, 'archived');
  assert.equal(out.result.revision, rev + 1);
  assert.equal((await taskRow(store, 't1')).status, 'archived', 'the CLI path archived the task');
});
