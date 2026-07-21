// Typed control-plane errors owned by S5.
//
// S0's errors.mjs defers the command-conflict taxonomy to the slice that owns the
// verbs raising them; S1 defined the idempotency/causal/transition trio, S2 the
// terminal-conflict class, and S3 the identity-verification class. S5 owns the
// reconciler surface (reconcile/anomalies/resolve-anomaly), and its one new typed
// error is the anomaly-resolution guard. It extends the S0 ControlPlaneError so
// bin/cp.mjs's typed-error mapping (message/code/detail -> nonzero exit) works
// uniformly without any S0 change.

import { ControlPlaneError } from './errors.mjs';

// resolve-anomaly refused to move an anomaly to 'resolved'. Every path that raises it
// is a NON-audited routing/predicate rejection (not a canonical conflict): the whole
// transaction is abandoned, so nothing (no row change, no command_results ghost)
// persists. It is raised for:
//
//   * an unknown fingerprint (there is no such anomaly to resolve);
//   * an anomaly that is ALREADY resolved (a different command trying to re-resolve a
//     preserved historical row; the same command-id replays the stored result before
//     the mutate runs, so this only fires for a genuinely different re-resolution);
//   * a resolution-kind outside the allowed vocabulary; or
//   * the spec-830-840 predicate breach that ORD-228 ruling Q4 encodes: a
//     markerless/ambiguous-orphan (`orphan_pane`) anomaly may be resolved ONLY with
//     resolution-kind `human_approved` (captain-routed), never on agent authority.
//
// The row is NEVER deleted by resolve-anomaly (spec 597/828): a refusal leaves it
// exactly as active as it was, and a success flips status/resolution_kind/
// resolved_reason/resolved_at in place.
export class AnomalyResolutionError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'anomaly_resolution');
    this.detail = detail || null;
  }
}
