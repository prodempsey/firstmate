// Typed control-plane errors owned by S6.
//
// S0's errors.mjs defers the command-conflict/verb taxonomy to the slice that owns
// the verbs raising them; S1 defined the idempotency/causal/transition trio, S2 the
// terminal-conflict class, S3 the identity-verification class, S4 the lease/sink
// classes, and S5 the anomaly-resolution guard. S6 owns the snapshot/projection/
// export surface (snapshot / project / export-snapshot), and its two new typed
// errors both extend the S0 ControlPlaneError so bin/cp.mjs's typed-error mapping
// (message/code/detail -> nonzero exit) works uniformly without any S0 change.

import { ControlPlaneError } from './errors.mjs';

// The stable order prefix could not be captured (spec 739-752). Raised when the
// external canonical captain inbox is unreadable, or when the file kept shrinking,
// rotating, or changing identity across the bounded retry budget so no stable
// complete-line prefix could be pinned. It is a fail-LOUD condition: `cp snapshot`
// aborts rather than hashing an unstable or partially-written order range, so a
// snapshot never folds a torn prefix. An ABSENT inbox is NOT this error - a fleet
// with no captain orders yet has an empty (zero-byte) prefix, which is a valid
// stable prefix, not an instability.
export class SnapshotSourceError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'snapshot_source');
    this.detail = detail || null;
  }
}

// A requested snapshot does not exist (spec Q6 ruling). Raised by `cp project` and
// `cp export-snapshot` when `--revision N` names a projection revision that is
// absent (never pruned in S6, but never taken either), and when NO snapshot exists
// at all and the caller asked for the latest. The ruling is explicit: an absent
// requested revision is a typed not-found, NEVER a silent fall-back to the latest
// snapshot, so a caller pinning a revision can never be handed a different one.
export class SnapshotNotFoundError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'snapshot_not_found');
    this.detail = detail || null;
  }
}

// A reader rejected an exported snapshot file (spec 769). Raised by the reader-side
// verifier when the recomputed payload checksum does not match the envelope's
// recorded checksum, when the envelope's projection revision regresses below the
// reader's last-seen revision, or when the envelope's order source path does not
// match the path the reader expects. All three are integrity failures a consumer
// must refuse rather than project stale or foreign state.
export class SnapshotVerificationError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'snapshot_verification');
    this.detail = detail || null;
  }
}
