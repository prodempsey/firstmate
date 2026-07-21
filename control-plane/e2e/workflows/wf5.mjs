import assert from 'node:assert/strict';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { archiveTask } from '../../lib/domain-store-archive.mjs';
import { resolveAnomaly } from '../../lib/domain-store-s5.mjs';
import { TerminalConflictError } from '../../lib/errors-s2.mjs';
import { doubleRunning, doubleCleanup } from '../fixtures/lifecycle.mjs';
import { makeSink, drainToIdle } from '../fixtures/consumer.mjs';

// Workflow 5 - Duplicate and conflicting completion (spec matrix row 864): an identical
// replayed complete returns the SAME stored result (idempotent by command-id); a
// CONFLICTING terminal outcome on the already-closed generation returns TerminalConflictError
// and records a terminal_conflict audit anomaly, which resolves to a RESOLVED audit row once
// the canonical terminal chain is proven (one terminal event, its outbox acked, cleanup
// cleaned, the conflicting command rejected). No real pane needed.
export const meta = { tmuxRequired: false };

export async function run(h) {
  const store = h.store;
  const taskId = 't-conflict';
  const started = await doubleRunning(store, taskId, { seed: 5 });

  // Canonical completion.
  const done = await completeRun(store, {
    taskId, generation: 1, expectedRevision: started.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: { ok: true }, commandId: 'c-done'
  });

  // Idempotent replay: identical command-id returns the identical stored result and moves
  // no counter (a duplicate completion is a no-op, not a second terminal).
  const replay = await completeRun(store, {
    taskId, generation: 1, expectedRevision: started.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: { ok: true }, commandId: 'c-done'
  });
  assert.deepEqual(replay, done, 'an identical replayed complete returns the same result');
  const terminalCount = await h.read("SELECT count(*)::int AS n FROM task_events WHERE task_id = $1 AND is_terminal", [taskId]);
  assert.equal(Number(terminalCount[0].n), 1, 'the replay wrote no second terminal event');

  // Conflicting terminal outcome on the already-closed generation: a DIFFERENT command that
  // tries a second, contradictory terminal must be rejected with TerminalConflictError.
  await assert.rejects(
    () => completeRun(store, { taskId, generation: 1, expectedRevision: done.revision, outcome: 'success', producer: 'crewmate', seq: 2, evidence: {}, commandId: 'c-conflict' }),
    (e) => e instanceof TerminalConflictError && e.code === 'terminal_conflict',
    'a conflicting terminal outcome is rejected with TerminalConflictError'
  );
  const conflictAnom = (await h.read("SELECT fingerprint, status FROM anomalies WHERE anomaly_class = 'terminal_conflict'"));
  assert.equal(conflictAnom.length, 1, 'the conflict recorded exactly one terminal_conflict anomaly');
  assert.equal(conflictAnom[0].status, 'active', 'the conflict anomaly starts active');
  // The conflicting command is idempotently rejected (no command_results row was written for it).
  const conflictCmd = await h.read("SELECT count(*)::int AS n FROM command_results WHERE command_id = 'c-conflict'");
  assert.equal(Number(conflictCmd[0].n), 0, 'the rejected conflicting command left no committed result');

  // Prove the canonical chain: ack the one terminal delivery, then clean up. Now the
  // terminal_conflict predicate holds and the anomaly resolves to a RESOLVED audit row.
  const sink = makeSink(h.sinkDir);
  await drainToIdle(store, { sink });
  const cleanedRev = await doubleCleanup(store, taskId, done.revision);
  const resolved = await resolveAnomaly(store, {
    fingerprint: conflictAnom[0].fingerprint, reason: 'e2e: canonical terminal chain proven', resolutionKind: 'agent_verified', commandId: 'c-res-conflict'
  });
  assert.equal(resolved.status, 'resolved', 'the terminal_conflict anomaly resolves once the canonical chain is proven');

  // The canonical terminal survives to archive.
  const arch = await archiveTask(store, { taskId, expectedRevision: cleanedRev, commandId: 'c-arch' });
  assert.equal(arch.status, 'archived');

  return { expectedActiveAnomalies: [] };
}
