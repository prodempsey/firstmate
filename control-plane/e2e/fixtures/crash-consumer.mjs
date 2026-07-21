import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { claimDelivery, markApplied, ack } from '../../lib/domain-store-s4.mjs';
import { FileLedgerSink } from '../../lib/sinks.mjs';

// Child-process consumer crash worker for wf6 (spec matrix row 865: "crash after claim
// before effect, during effect, after effect before mark-applied, and after mark-applied
// before ack ... via real child exits"). It drives the raw S4 delivery verbs plus the real
// durable sink against ONE terminal outbox row, using the lease the parent already holds,
// and HARD-exits at the exact requested cutpoint. The parent then recovers with the real
// FirstMateConsumer and proves the sink effect happened exactly once (idempotent by
// event_id) and the cursor advanced exactly once.
//
// env: CP_FM_HOME, CP_OWNER_TOKEN, CP_OWNER_EPOCH, CP_OUTBOX_ID, CP_EVENT_ID, CP_SINK_KIND,
//      CP_SINK_DIR, CP_TASK_ID, CP_EVENT_TYPE, CP_PAYLOAD_HASH, CP_CRASH_CUT, CP_CMD_PREFIX
// exit codes: 51 after-claim, 54 during-sink, 52 after-sink, 53 after-mark.

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
const sink = new FileLedgerSink({ dir: process.env.CP_SINK_DIR });
const cut = process.env.CP_CRASH_CUT;
const tok = { ownerToken: process.env.CP_OWNER_TOKEN, ownerEpoch: Number(process.env.CP_OWNER_EPOCH) };
const outboxId = Number(process.env.CP_OUTBOX_ID);
const eventId = process.env.CP_EVENT_ID;
const sinkKind = process.env.CP_SINK_KIND;
const prefix = process.env.CP_CMD_PREFIX;
const payload = { task_id: process.env.CP_TASK_ID, event_type: process.env.CP_EVENT_TYPE, payload_hash: process.env.CP_PAYLOAD_HASH };

await claimDelivery(store, { outboxId, ...tok, sinkKind, commandId: `${prefix}-cd` });
if (cut === 'after_claim_before_sink') process.exit(51);

const applied = await sink.apply(sinkKind, eventId, payload, cut === 'during_sink' ? { faultBeforeCommit: () => process.exit(54) } : {});
if (cut === 'after_sink_before_mark') process.exit(52);

await markApplied(store, { eventId, ...tok, sinkResult: applied.result, commandId: `${prefix}-ma` });
if (cut === 'after_mark_before_ack') process.exit(53);

await ack(store, { outboxId, ...tok, commandId: `${prefix}-ak` });
process.exit(0);
