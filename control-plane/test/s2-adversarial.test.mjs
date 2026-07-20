import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { TerminalConflictError } from '../lib/errors-s2.mjs';
import { completeRun, failRun, cancelTask } from '../lib/domain-store-s2.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

// Adversarial S2: what happens when a terminal writer crashes mid-bundle, when two
// terminal commands race, and when a generation is re-terminated. The invariant under
// attack throughout is that the terminal event, the run closure, and the outbox row
// are ONE commit - never two-out-of-three.
after(cleanupAll);

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
  return {
    domain: Number(r[0].domain_revision),
    projection: Number(r[0].projection_revision),
    commit: Number(r[0].commit_sequence)
  };
}

// See the identical fixture in s2-contract.test.mjs: a TEST-ONLY stand-in for S3's
// commit-running, writing through the in-package seam and deliberately not touching
// the coordinator counters so S2's own deltas stay measurable.
async function promoteToRunning(store, taskId, generation, revision) {
  await runExclusive(store, async (conn) => {
    await conn.query(
      "UPDATE runs SET status = 'open', binding_state = 'bound_verified' WHERE task_id = $1 AND run_generation = $2",
      [taskId, generation]
    );
    await conn.query(
      "UPDATE tasks SET status = 'running', revision = $2 WHERE task_id = $1",
      [taskId, revision + 1]
    );
  });
  return revision + 1;
}

async function runningTask(store, taskId = 't1') {
  await createTask(store, {
    taskId, kind: 'ship', title: 'x', origin: 'internal', internalReason: 'r',
    commandId: `c-create-${taskId}`
  });
  await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  return promoteToRunning(store, taskId, 1, 2);
}

// Minimal valid required terminal inputs (spec section 6) for tests whose subject is
// crash/race/conflict behavior rather than the input contract (which s2-contract
// pins). Conflicting attempts use seq 2 so only the conflict itself is under test.
const COMPLETE_INPUTS = { outcome: 'success', producer: 'crewmate', seq: 1, evidence: {} };
const COMPLETE_RETRY_INPUTS = { outcome: 'success', producer: 'crewmate', seq: 2, evidence: {} };
const FAIL_INPUTS = { reason: 'it broke', producer: 'crewmate', seq: 1 };

// The full terminal bundle as observable state, so a test can assert all-or-nothing
// in one comparison instead of three that could each pass while the set is torn.
async function terminalState(store, taskId) {
  return runExclusive(store, async (conn) => {
    const ev = await conn.query(
      'SELECT count(*)::int AS n FROM task_events WHERE task_id = $1 AND is_terminal', [taskId]
    );
    const run = await conn.query(
      'SELECT status, closed_at FROM runs WHERE task_id = $1 AND run_generation = 1', [taskId]
    );
    const reg = await conn.query("SELECT to_regclass('public.outbox') AS reg");
    const ob = reg.rows[0].reg === null
      ? { rows: [{ n: 0 }] }
      : await conn.query('SELECT count(*)::int AS n FROM outbox WHERE task_id = $1', [taskId]);
    return {
      terminalEvents: ev.rows[0].n,
      runStatus: run.rows[0].status,
      runClosed: run.rows[0].closed_at !== null,
      outboxRows: ob.rows[0].n
    };
  });
}

test('t_terminal_atomic_under_crash_between_writes', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1');
  const before = await counters(store);
  const openState = await terminalState(store, 't1');
  assert.deepEqual(
    openState,
    { terminalEvents: 0, runStatus: 'open', runClosed: false, outboxRows: 0 },
    'baseline: an open generation with nothing terminal'
  );

  // Crash cut A: after the entire domain bundle, before the counter bump and
  // command_results insert.
  await assert.rejects(
    () => completeRun(store, {
      taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-crash-a'
    }, { fault: () => { throw new Error('simulated crash after terminal bundle'); } }),
    /simulated crash after terminal bundle/
  );
  assert.deepEqual(await terminalState(store, 't1'), openState, 'crash cut A rolled the whole bundle back');
  assert.deepEqual(await counters(store), before, 'crash cut A moved no counter');

  // Crash cut B: the sharpest one - terminal event written, run closed, delivery NOT
  // yet inserted. A torn commit here would close a run whose completion FirstMate can
  // never learn about.
  await assert.rejects(
    () => completeRun(store, {
      taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-crash-b'
    }, { faultBeforeDelivery: () => { throw new Error('simulated crash before delivery'); } }),
    /simulated crash before delivery/
  );
  assert.deepEqual(
    await terminalState(store, 't1'), openState,
    'crash cut B left NO part of the bundle: no terminal event, no closure, no delivery'
  );
  assert.deepEqual(await counters(store), before, 'crash cut B moved no counter');

  // No command_results ghosts, so neither crashed command is mistaken for a replay.
  const ghosts = await rows(
    store, "SELECT count(*)::int AS n FROM command_results WHERE command_id IN ('c-crash-a','c-crash-b')"
  );
  assert.equal(ghosts[0].n, 0, 'no command_results ghost from either crash');

  // A clean retry after both crashes commits the full bundle exactly once.
  const ok = await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-retry'
  });
  assert.equal(ok.revision, rev + 1);
  assert.deepEqual(
    await terminalState(store, 't1'),
    { terminalEvents: 1, runStatus: 'completed', runClosed: true, outboxRows: 1 },
    'the retry commits event + closure + delivery together'
  );
  assert.deepEqual(
    await counters(store),
    { domain: before.domain + 1, projection: 0, commit: before.commit + 1 },
    'exactly one domain change survives two crashes and a retry'
  );
});

test('t_recovers_when_terminal_writer_exits_before_outbox', async () => {
  const { store, fmHome } = await freshStore();
  const rev = await runningTask(store, 't1');
  const before = await counters(store);
  await store.close();

  // A REAL writer-exit at the before-delivery cut: a child process hard-exits
  // mid-transaction (process.exit(41)). The OS releases the flock; on reopen, PGlite
  // crash recovery must show no partial commit.
  const worker = fileURLToPath(new URL('./workers/crash-terminal-writer.mjs', import.meta.url));
  const child = spawnSync(process.execPath, [worker], {
    env: {
      ...process.env,
      CP_FM_HOME: fmHome,
      CP_TASK_ID: 't1',
      CP_GENERATION: '1',
      CP_EXPECTED_REVISION: String(rev),
      CP_COMMAND_ID: 'c-crash-child'
    },
    encoding: 'utf8',
    timeout: 60000
  });
  assert.equal(child.status, 41, `terminal writer must hard-exit mid-transaction (stderr: ${child.stderr})`);

  const reopened = new PgliteLocalStore({ fmHome });
  assert.deepEqual(
    await terminalState(reopened, 't1'),
    { terminalEvents: 0, runStatus: 'open', runClosed: false, outboxRows: 0 },
    'the exited writer left no terminal event, no run closure, and no delivery'
  );
  assert.deepEqual(await counters(reopened), before, 'counters unchanged across the writer exit');
  const ghost = await rows(
    reopened, "SELECT count(*)::int AS n FROM command_results WHERE command_id = 'c-crash-child'"
  );
  assert.equal(ghost[0].n, 0, 'no command_results ghost from the exited writer');

  // The same command retried after the crash commits exactly once, delivery included.
  const retry = await completeRun(reopened, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-crash-child'
  });
  assert.equal(retry.revision, rev + 1);
  assert.deepEqual(
    await terminalState(reopened, 't1'),
    { terminalEvents: 1, runStatus: 'completed', runClosed: true, outboxRows: 1 }
  );
  assert.deepEqual(
    await counters(reopened),
    { domain: before.domain + 1, projection: 0, commit: before.commit + 1 }
  );
});

test('t_double_complete_replays_and_conflicts', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1');
  await completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-done' });
  const afterFirst = await counters(store);

  // Same command-id, same request: an idempotent REPLAY. No write, no audit, no
  // counter movement, stored result returned.
  const replay = await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-done'
  });
  assert.equal(replay.revision, rev + 1, 'the replay returns the stored result');
  assert.deepEqual(await counters(store), afterFirst, 'a replay advances nothing');
  assert.deepEqual(
    await terminalState(store, 't1'),
    { terminalEvents: 1, runStatus: 'completed', runClosed: true, outboxRows: 1 }
  );

  // A DIFFERENT command-id against the now-closed generation is a terminal conflict,
  // not a replay and not a stale-revision causal error.
  await assert.rejects(
    () => completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev + 1, ...COMPLETE_RETRY_INPUTS, commandId: 'c-again' }),
    (e) => e instanceof TerminalConflictError
      && e.code === 'terminal_conflict'
      && e.detail.reason === 'generation_already_closed',
    'a second terminal on a closed generation is a terminal conflict'
  );

  // The conflict is audited: mutation rolled back, anomaly persisted, domain+commit
  // each advance by exactly one (the audit is itself a canonical domain change).
  assert.deepEqual(
    await terminalState(store, 't1'),
    { terminalEvents: 1, runStatus: 'completed', runClosed: true, outboxRows: 1 },
    'the rejected terminal wrote no second event, closure, or delivery'
  );
  const c = await counters(store);
  assert.deepEqual(
    c,
    { domain: afterFirst.domain + 1, projection: 0, commit: afterFirst.commit + 1 },
    'the conflict audit is one domain change and never touches projection_revision'
  );
  const anom = await rows(
    store, "SELECT count(*)::int AS n FROM anomalies WHERE anomaly_class = 'terminal_conflict'"
  );
  assert.equal(anom[0].n, 1, 'exactly one terminal_conflict anomaly persisted');
});

test('t_complete_after_fail_conflicts', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1');

  await failRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...FAIL_INPUTS, commandId: 'c-fail'
  });
  const afterFail = await counters(store);
  const ev = await rows(
    store, "SELECT event_type, outcome FROM task_events WHERE task_id = 't1' AND is_terminal"
  );
  assert.deepEqual(ev, [{ event_type: 'failed', outcome: 'failure' }]);

  // A generation that failed cannot then complete: the outcome of a generation is
  // decided once.
  await assert.rejects(
    () => completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev + 1, ...COMPLETE_RETRY_INPUTS, commandId: 'c-complete' }),
    (e) => e instanceof TerminalConflictError
      && e.detail.existing_run_status === 'failed'
      && e.detail.attempted_status === 'completed',
    'complete after fail is a terminal conflict naming both outcomes'
  );

  // The failed terminal is untouched and no second delivery appeared.
  assert.deepEqual(
    await terminalState(store, 't1'),
    { terminalEvents: 1, runStatus: 'failed', runClosed: true, outboxRows: 1 }
  );
  const task = await rows(store, "SELECT status FROM tasks WHERE task_id = 't1'");
  assert.equal(task[0].status, 'failed', 'the task stayed failed');
  assert.deepEqual(await counters(store), { domain: afterFail.domain + 1, projection: 0, commit: afterFail.commit + 1 });

  // The reverse direction is symmetric.
  const rev2 = await runningTask(store, 't2');
  await completeRun(store, { taskId: 't2', generation: 1, expectedRevision: rev2, ...COMPLETE_INPUTS, commandId: 'c-done-2' });
  await assert.rejects(
    () => failRun(store, { taskId: 't2', generation: 1, expectedRevision: rev2 + 1, reason: 'it broke', producer: 'crewmate', seq: 2, commandId: 'c-fail-2' }),
    (e) => e instanceof TerminalConflictError && e.detail.existing_run_status === 'completed',
    'fail after complete is equally a terminal conflict'
  );
});

test('t_concurrent_complete_serializes', async () => {
  const { store, fmHome } = await freshStore();
  const other = new PgliteLocalStore({ fmHome });
  const rev = await runningTask(store, 't1');

  // Two complete commands race on the same open generation with the same causal
  // token, through two independent store instances contending on the real flock.
  const settled = await Promise.allSettled([
    completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-a' }),
    completeRun(other, { taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-b' })
  ]);
  const fulfilled = settled.filter((s) => s.status === 'fulfilled');
  const rejected = settled.filter((s) => s.status === 'rejected');
  assert.equal(fulfilled.length, 1, 'exactly one complete wins');
  assert.equal(rejected.length, 1, 'exactly one complete loses');
  assert.ok(
    rejected[0].reason instanceof TerminalConflictError,
    `the loser is a terminal conflict (got ${rejected[0].reason})`
  );

  // The winner produced exactly one of each; the loser mutated nothing.
  assert.deepEqual(
    await terminalState(store, 't1'),
    { terminalEvents: 1, runStatus: 'completed', runClosed: true, outboxRows: 1 },
    'serialization left exactly one terminal event and one delivery'
  );
  const t = await rows(store, "SELECT revision, status FROM tasks WHERE task_id = 't1'");
  assert.equal(Number(t[0].revision), rev + 1, 'task revision advanced by exactly one');
  assert.equal(t[0].status, 'completed');
  const anom = await rows(
    store, "SELECT count(*)::int AS n FROM anomalies WHERE anomaly_class = 'terminal_conflict'"
  );
  assert.equal(anom[0].n, 1, 'the losing command left exactly one terminal anomaly');
  await other.close();
});

test('t_complete_fail_race', async () => {
  const { store, fmHome } = await freshStore();
  const other = new PgliteLocalStore({ fmHome });
  const rev = await runningTask(store, 't1');

  // complete and fail race for the SAME generation. Whichever lands first decides the
  // generation's outcome; the other must be refused rather than overwrite it.
  const settled = await Promise.allSettled([
    completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-complete' }),
    failRun(other, { taskId: 't1', generation: 1, expectedRevision: rev, ...FAIL_INPUTS, commandId: 'c-fail' })
  ]);
  const fulfilled = settled.filter((s) => s.status === 'fulfilled');
  const rejected = settled.filter((s) => s.status === 'rejected');
  assert.equal(fulfilled.length, 1, 'exactly one terminal verb wins');
  assert.equal(rejected.length, 1, 'exactly one terminal verb loses');
  assert.ok(rejected[0].reason instanceof TerminalConflictError, 'the loser is a terminal conflict');

  // Exactly one terminal event and one delivery, and they agree with each other and
  // with the run and task status - no mixed outcome anywhere.
  const winner = fulfilled[0].value;
  const ev = await rows(
    store, "SELECT event_type, outcome FROM task_events WHERE task_id = 't1' AND is_terminal"
  );
  assert.equal(ev.length, 1, 'exactly one terminal event survived the race');
  assert.equal(ev[0].event_type, winner.event_type);
  const ob = await rows(store, "SELECT event_type FROM outbox WHERE task_id = 't1'");
  assert.equal(ob.length, 1, 'exactly one delivery survived the race');
  assert.equal(ob[0].event_type, winner.event_type, 'the delivery matches the winning terminal');
  const run = await rows(store, "SELECT status FROM runs WHERE task_id = 't1' AND run_generation = 1");
  assert.equal(run[0].status, winner.run_status, 'the run status matches the winning terminal');
  const task = await rows(store, "SELECT status, revision FROM tasks WHERE task_id = 't1'");
  assert.equal(task[0].status, winner.status);
  assert.equal(Number(task[0].revision), rev + 1, 'the task advanced by exactly one revision');
  await other.close();
});

test('t_conflicting_terminal_audits_and_persists', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1');
  await completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-done' });
  const base = await counters(store);

  // Three distinct conflicting terminals against the closed generation.
  for (const id of ['c-x1', 'c-x2', 'c-x3']) {
    await assert.rejects(
      () => completeRun(store, { taskId: 't1', generation: 1, expectedRevision: rev + 1, ...COMPLETE_RETRY_INPUTS, commandId: id }),
      (e) => e instanceof TerminalConflictError
    );
  }

  // Each rejected command is an audited domain change: the mutation rolled back but
  // the anomaly SURVIVED to commit, and domain+commit advanced once per conflict.
  assert.deepEqual(
    await counters(store),
    { domain: base.domain + 3, projection: 0, commit: base.commit + 3 },
    'each conflict audit is exactly one domain change; projection stays 0 (S6 owns it)'
  );

  // The three conflicts coalesce onto ONE fingerprint (same task + generation +
  // class), with occurrence_count carrying the repeat count. The row is never deleted
  // to satisfy a final-zero test (spec section 6.2).
  const anom = await rows(
    store,
    `SELECT fingerprint, occurrence_count, status, task_id, run_generation, detail_json
       FROM anomalies WHERE anomaly_class = 'terminal_conflict'`
  );
  assert.equal(anom.length, 1, 'repeat conflicts on one generation coalesce to one anomaly');
  assert.equal(Number(anom[0].occurrence_count), 3, 'occurrence_count carries every repeat');
  assert.equal(anom[0].status, 'active');
  assert.equal(anom[0].task_id, 't1');
  assert.equal(Number(anom[0].run_generation), 1);

  // The committed terminal is untouched by any of it.
  assert.deepEqual(
    await terminalState(store, 't1'),
    { terminalEvents: 1, runStatus: 'completed', runClosed: true, outboxRows: 1 }
  );

  // A conflict on a DIFFERENT generation is a different fingerprint, so coalescing
  // does not swallow distinct conflicts. A second generation is only reachable from a
  // FAILED task (begin-run correctly refuses to respawn a completed one), so this uses
  // the retry path: gen 1 fails, gen 2 is begun, completed, then conflicted.
  const rev2 = await runningTask(store, 't2');
  await failRun(store, { taskId: 't2', generation: 1, expectedRevision: rev2, ...FAIL_INPUTS, commandId: 'c-t2-fail' });
  await beginRun(store, { taskId: 't2', expectedRevision: rev2 + 1, commandId: 'c-t2-begin-2' });
  const rev2b = await promoteToRunning(store, 't2', 2, rev2 + 1);
  await completeRun(store, { taskId: 't2', generation: 2, expectedRevision: rev2b, ...COMPLETE_INPUTS, commandId: 'c-t2-done-2' });
  await assert.rejects(
    () => completeRun(store, { taskId: 't2', generation: 2, expectedRevision: rev2b + 1, ...COMPLETE_RETRY_INPUTS, commandId: 'c-t2-again' }),
    (e) => e instanceof TerminalConflictError
  );
  const anom2 = await rows(
    store,
    `SELECT task_id, run_generation FROM anomalies
       WHERE anomaly_class = 'terminal_conflict' ORDER BY task_id, run_generation`
  );
  assert.deepEqual(
    anom2.map((r) => `${r.task_id}:${r.run_generation}`), ['t1:1', 't2:2'],
    'a conflict on another generation is a distinct anomaly, not a coalesced one'
  );
});

test('t_terminal_replay_is_not_double_delivery', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1');
  const first = await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-done'
  });
  const original = await rows(
    store, "SELECT outbox_id, event_id, task_seq, delivery_attempts, acked_at FROM outbox WHERE task_id = 't1'"
  );
  assert.equal(original.length, 1);
  const afterFirst = await counters(store);

  // Replaying the terminal command many times must never enqueue a second delivery -
  // the consumer contract (S4) is exactly-once by event_id, and a duplicate row here
  // would become a duplicate side effect there.
  for (let i = 0; i < 5; i += 1) {
    const replay = await completeRun(store, {
      taskId: 't1', generation: 1, expectedRevision: rev, ...COMPLETE_INPUTS, commandId: 'c-done'
    });
    assert.deepEqual(replay, first, 'every replay returns the identical stored result');
  }

  const afterReplays = await rows(
    store, "SELECT outbox_id, event_id, task_seq, delivery_attempts, acked_at FROM outbox WHERE task_id = 't1'"
  );
  assert.equal(afterReplays.length, 1, 'five replays produced no additional delivery');
  // The row is byte-identical: replays did not even touch the existing delivery's
  // attempt counter or ack state.
  assert.deepEqual(afterReplays, original, 'the existing delivery row is untouched by replays');
  assert.deepEqual(await counters(store), afterFirst, 'replays advanced no counter');

  // Cancellation replays are equally non-duplicating on the task-scope path.
  await createTask(store, {
    taskId: 't2', kind: 'ship', title: 'y', origin: 'internal', internalReason: 'r', commandId: 'c-create-2'
  });
  const cancelled = await cancelTask(store, { taskId: 't2', expectedRevision: 1, reason: 'captain withdrew', commandId: 'c-cancel' });
  const beforeCancelReplay = await counters(store);
  const cancelReplay = await cancelTask(store, { taskId: 't2', expectedRevision: 1, reason: 'captain withdrew', commandId: 'c-cancel' });
  assert.deepEqual(cancelReplay, cancelled, 'the cancel replay returns the stored result');
  const cancelOb = await rows(store, "SELECT count(*)::int AS n FROM outbox WHERE task_id = 't2'");
  assert.equal(cancelOb[0].n, 1, 'the cancel replay produced no second delivery');
  assert.deepEqual(await counters(store), beforeCancelReplay, 'the cancel replay advanced no counter');
});
