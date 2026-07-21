// Crash-probe worker for the S4 two-store consistency tests
// (t_at_least_once_crash_between_apply_and_ack, t_crash_after_claim_before_effect,
// t_crash_during_effect, t_crash_after_mark_applied_before_ack).
//
// The parent has already produced a deliverable outbox row and claimed the consumer
// lease, and hands this worker the owner_token, the outbox_id/event_id, the sink_kind,
// and an isolated file-ledger dir. The worker drives the real consumer verbs and the
// real file-ledger sink, then performs a HARD process.exit at a chosen cut - a genuine
// writer-exit, not a caught in-process throw. Each domain verb and the sink write each
// commit-and-close before returning (open-per-exclusive-section for PGlite, atomic
// temp->rename for the ledger), so an exit BETWEEN steps leaves the earlier step
// durably committed and the later step not begun. The parent then drives recovery and
// asserts the effect landed EXACTLY once and the cursor advanced once.
//
// CP_CRASH_CUT selects the cut:
//   after_claim_before_sink - claim-delivery committed; exit before any sink effect.
//   during_sink             - sink temp write + fsync done; exit before the atomic
//                             rename (so no committed ledger entry survives).
//   after_sink_before_mark  - sink effect committed; exit before mark-applied.
//   after_mark_before_ack   - mark-applied committed; exit before ack.
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { claimDelivery, markApplied, ack } from '../../lib/domain-store-s4.mjs';
import { FileLedgerSink } from '../../lib/sinks.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
const ownerToken = process.env.CP_OWNER_TOKEN;
const ownerEpoch = Number(process.env.CP_OWNER_EPOCH);
const outboxId = Number(process.env.CP_OUTBOX_ID);
const eventId = process.env.CP_EVENT_ID;
const sinkKind = process.env.CP_SINK_KIND;
const cut = process.env.CP_CRASH_CUT;
const prefix = process.env.CP_CMD_PREFIX || 'crash';
const sink = new FileLedgerSink({ dir: process.env.CP_SINK_DIR });
const payload = { event_id: eventId };

await claimDelivery(store, { outboxId, ownerToken, ownerEpoch, sinkKind, commandId: `${prefix}-cd` });
if (cut === 'after_claim_before_sink') process.exit(51);

if (cut === 'during_sink') {
  // Durable temp write + fsync, then exit before the atomic link commit: proves the
  // sink leaves NO half-applied effect, so recovery re-applies idempotently.
  await sink.apply(sinkKind, eventId, payload, { faultBeforeCommit: () => process.exit(54) });
  process.exit(99); // unreachable: faultBeforeCommit exits first
}

const sinkResult = await sink.apply(sinkKind, eventId, payload);
if (cut === 'after_sink_before_mark') process.exit(52);

await markApplied(store, { eventId, ownerToken, ownerEpoch, sinkResult: sinkResult.result, commandId: `${prefix}-ma` });
if (cut === 'after_mark_before_ack') process.exit(53);

await ack(store, { outboxId, ownerToken, ownerEpoch, commandId: `${prefix}-ak` });
process.exit(0);
