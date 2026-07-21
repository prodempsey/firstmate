import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { completeRun } from '../../lib/domain-store-s2.mjs';
import { claimConsumer, readReceipt, readCursor } from '../../lib/domain-store-s4.mjs';
import { doubleRunning } from '../fixtures/lifecycle.mjs';
import { makeSink, drainToIdle, sinkEffectCount } from '../fixtures/consumer.mjs';

// Workflow 6 - FirstMate consumer crash (spec matrix row 865): the consumer is crashed via
// a REAL child exit at each of the four cutpoints - after claim before the sink effect,
// during the effect, after the effect before mark-applied, and after mark-applied before
// ack. In every case the sink's idempotency BY EVENT_ID prevents a duplicate effect, and
// recovery through the real consumer advances the cursor exactly once. No real pane needed.
export const meta = { tmuxRequired: false };

const CRASH_CONSUMER = fileURLToPath(new URL('../fixtures/crash-consumer.mjs', import.meta.url));
const CUTS = [
  { cut: 'after_claim_before_sink', exit: 51 },
  { cut: 'during_sink', exit: 54 },
  { cut: 'after_sink_before_mark', exit: 52 },
  { cut: 'after_mark_before_ack', exit: 53 }
];

export async function run(h) {
  const store = h.store;
  let expectedCursor = 0;

  for (let i = 0; i < CUTS.length; i += 1) {
    const { cut, exit } = CUTS[i];
    const taskId = `t-ccrash-${i}`;
    const started = await doubleRunning(store, taskId, { seed: 10 + i });
    await completeRun(store, { taskId, generation: 1, expectedRevision: started.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: `c-done-${i}` });
    const row = (await h.read("SELECT outbox_id, event_id, task_id, event_type, payload_hash FROM outbox WHERE task_id = $1 AND event_type = 'completed'", [taskId]))[0];
    const outboxId = Number(row.outbox_id);

    // The parent holds the single lease; the crash worker drives delivery on it and dies.
    const lease = await claimConsumer(store, { bootId: 'boot-wf6', pid: 6000, commandId: `c-claim-${i}` });
    const crash = spawnSync('node', [CRASH_CONSUMER], {
      encoding: 'utf8',
      env: {
        ...process.env, CP_FM_HOME: h.fmHome, CP_SINK_DIR: h.sinkDir,
        CP_OWNER_TOKEN: lease.owner_token, CP_OWNER_EPOCH: String(lease.owner_epoch),
        CP_OUTBOX_ID: String(outboxId), CP_EVENT_ID: row.event_id, CP_SINK_KIND: 'disposition',
        CP_TASK_ID: row.task_id, CP_EVENT_TYPE: row.event_type, CP_PAYLOAD_HASH: row.payload_hash,
        CP_CRASH_CUT: cut, CP_CMD_PREFIX: `w-${i}`
      }
    });
    assert.equal(crash.status, exit, `${cut}: the consumer hard-exited at the cutpoint`);

    const effectsBefore = sinkEffectCount(h.sinkDir);

    // Recover through the REAL consumer adapter (same owner renews the lease). The
    // recovery-aware drain re-drives from the receipt state and completes the delivery.
    const reSink = makeSink(h.sinkDir);
    const recovered = await drainToIdle(store, { sink: reSink, bootId: 'boot-wf6', pid: 6000 });
    assert.equal(recovered.result.idle, true, `${cut}: recovery drained to idle`);

    // Exactly one durable sink effect for this event_id - the crash never doubled it.
    const receipt = await readReceipt(store, { eventId: row.event_id });
    assert.equal(receipt.state, 'applied', `${cut}: the receipt is applied after recovery`);
    const acked = (await h.read('SELECT acked_at FROM outbox WHERE outbox_id = $1', [outboxId]))[0];
    assert.ok(acked.acked_at, `${cut}: the delivery is acked after recovery`);
    // The during_sink cut crashed before committing its file, so recovery writes the single
    // file; the after-sink cuts already had one file, and re-apply hits the idempotent
    // first-writer-wins path - never a second file. Net: one effect either way.
    assert.ok(sinkEffectCount(h.sinkDir) - effectsBefore <= 1, `${cut}: at most one new committed effect on recovery`);

    // The cursor advanced by exactly one (this delivery), never twice.
    expectedCursor = outboxId;
    const cursor = await readCursor(store, {});
    assert.equal(cursor.last_acked_outbox_id, expectedCursor, `${cut}: the cursor advanced exactly once to this delivery`);
  }

  // Every event produced exactly one durable effect - four events, four effect files.
  assert.equal(sinkEffectCount(h.sinkDir), CUTS.length, 'exactly one durable effect per event across all cutpoints');

  return { expectedActiveAnomalies: [] };
}
