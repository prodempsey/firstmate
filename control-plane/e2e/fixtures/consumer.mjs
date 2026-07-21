import fs from 'node:fs';
import { FirstMateConsumer } from '../../lib/firstmate-consumer.mjs';
import { FileLedgerSink } from '../../lib/sinks.mjs';
import { readCursor } from '../../lib/domain-store-s4.mjs';

// The REAL S4 FirstMate consumer adapter (spec section 11: "the real S4 FirstMate consumer
// adapter with the durable reference sink") driven against a genuine durable sink. The
// FileLedgerSink writes one file per (sink_kind, event_id) with atomic first-writer-wins,
// so effects are idempotent BY EVENT_ID exactly as the spec requires - re-driving the same
// event never doubles the effect. Nothing here is a stub: FirstMateConsumer and
// FileLedgerSink are the production modules FirstMate itself drives at cutover.

// A durable reference sink rooted at `sinkDir`. One sink per E2E run (inside the fixture
// root); its ledger files are the observable "effects" the finals count.
export function makeSink(sinkDir) {
  fs.mkdirSync(sinkDir, { recursive: true });
  return new FileLedgerSink({ dir: sinkDir });
}

// Claim the single consumer lease and drain every unacked outbox row to idle through the
// real adapter. A fresh claim each call rotates (owner_token, owner_epoch), which is
// exactly the reopen/restart path wf1's "no resurrection" and wf8's fencing exercise.
// Returns { lease, result } where result is FirstMateConsumer.drainUntilIdle's outcome.
export async function drainToIdle(store, { sink, bootId = 'boot-e2e', pid = process.pid, now }) {
  const consumer = new FirstMateConsumer(store, { sink, bootId, pid });
  const lease = await consumer.claim({ now });
  const result = await consumer.drainUntilIdle({ now });
  return { consumer, lease, result };
}

// The durable consumer cursor (last acked outbox id). The finals read this before and
// after a store reopen to prove it survives.
export async function cursorOf(store) {
  return readCursor(store, {});
}

// Count the durable COMMITTED effect files the sink has (one per applied (sink_kind,
// event_id)). Uncommitted temp files (`<file>.tmp-<pid>-<hex>`, left when a caller crashed
// between fsync and the atomic link) are crash artifacts, not effects, and are excluded -
// exactly the benign stray the S6 export suite tolerates. Used to assert an effect happened
// exactly once despite crashes/redelivery.
export function sinkEffectCount(sinkDir) {
  if (!fs.existsSync(sinkDir)) return 0;
  let n = 0;
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.isDirectory()) walk(`${d}/${e.name}`);
      else if (!e.name.includes('.tmp-')) n += 1;
    }
  };
  walk(sinkDir);
  return n;
}
