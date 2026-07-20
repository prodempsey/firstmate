// Typed control-plane errors owned by S3.
//
// S0's errors.mjs defers the command-conflict taxonomy to the slice that owns the
// verbs raising them; S1 defined the idempotency/causal/transition trio and S2 the
// terminal-conflict class. S3 owns the lifecycle verbs (record-spawn/commit-running/
// verify-running/cleanup-intent/cleanup-finish) and the identity-verification class,
// so it is defined here. It extends the S0 ControlPlaneError so bin/cp.mjs's
// typed-error mapping (message/code/detail -> nonzero exit) works uniformly without
// any S0 change.

import { ControlPlaneError } from './errors.mjs';

// The stored launch identity did not match a live probe when a verification was
// required (spec section 5.1 `identity_matches`). Two paths raise it and they are
// deliberately distinguished by whether the mutation was audited:
//
//   * commit-running on a FAILING identity probe raises it through the sanctioned
//     audit path (ConflictSignal('identity') -> savepoint rollback -> `identity_mismatch`
//     or `missing_pane` anomaly persisted -> this error). The run STAYS spawning and
//     the binding is unchanged (ORD-228 ruling RISK#1): S3 never commits the
//     identity_lost event or the binding='lost' transition, which are S5.
//   * record-spawn that cannot capture a coherent identity raises it directly,
//     un-audited: that is an environmental/out-of-order failure of the caller's own
//     spawn, not a canonical conflict between two competing commands, so the whole
//     transaction is abandoned and nothing (not even an anomaly) persists.
//
// The SAME typed error surfaces to the caller in both cases; only whether an anomaly
// row survives differs. This is the structural antidote to the dead-crew-reported-
// alive class: a run whose endpoint died between record-spawn and commit-running can
// never be promoted to running/bound_verified, because promotion is gated on a live
// identity match at commit time.
export class IdentityMismatchError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'identity_mismatch');
    this.detail = detail || null;
  }
}
