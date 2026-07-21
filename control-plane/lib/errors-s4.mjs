// Typed control-plane errors owned by S4.
//
// S0's errors.mjs defers the command-conflict taxonomy to the slice that owns the
// verbs raising them; S1 defined the idempotency/causal/transition trio, S2 the
// terminal-conflict class, and S3 the identity-mismatch class. S4 owns the FirstMate
// consumer verbs (claim-consumer/next/claim-delivery/mark-applied/ack) and the sink
// contract, so its two classes are defined here. Both extend the S0 ControlPlaneError
// so bin/cp.mjs's typed-error mapping (message/code/detail -> nonzero exit) works
// uniformly without any S0 change.

import { ControlPlaneError } from './errors.mjs';

// A consumer command presented an owner token (or a claim-consumer owner identity)
// that lost the single-lease fencing check (spec section 8.1; anomaly class
// `consumer_lease_conflict`, spec section 10). It surfaces in TWO distinct ways, and
// only the first is audited:
//
//   * FENCED - a LIVE lease is held by a DIFFERENT owner than the caller (a losing
//     claim-consumer takeover, or a fenced-off old owner still writing through a
//     mutating verb). This is a genuine two-owner contention: "exactly one wins". It
//     is recorded through the sanctioned audit path (ConflictSignal('lease') ->
//     savepoint rollback -> `consumer_lease_conflict` anomaly persisted -> this
//     error), exactly as S1/S2/S3 record their conflict classes.
//   * LAPSED - the caller's own lease simply expired or is absent (no competing live
//     owner). That is not a contention, so it is raised DIRECTLY and un-audited; the
//     caller is told to re-acquire with claim-consumer. `next`, a locked read with no
//     transaction that may write an anomaly, always raises this error directly.
//
// Token fencing protects later coordinator calls. It deliberately does NOT pretend to
// fence an external sink effect already in progress; that safety comes from sink
// idempotency by event_id (spec section 8.1).
export class LeaseConflictError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'consumer_lease_conflict');
    this.detail = detail || null;
  }
}

// A sink could not answer idempotently by event_id after an ambiguous timeout (spec
// section 8.3). FirstMate must NOT mark the receipt applied in that case - doing so
// would claim an effect it cannot confirm. Instead it records an active
// `sink_idempotency_unknown` anomaly through the same sanctioned audit path the lease
// conflict uses, and STOPS delivery rather than lying. This typed error is what
// surfaces to the caller so the drain loop halts.
export class SinkIdempotencyUnknownError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'sink_idempotency_unknown');
    this.detail = detail || null;
  }
}
