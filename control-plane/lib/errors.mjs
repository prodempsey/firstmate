// Typed control-plane errors — S0 scope only.
//
// S0 owns the store/init/lock/owner-guard error taxonomy. Command-conflict errors
// (idempotency/causal-ordering/terminal) belong to the slices that own the verbs
// that raise them and are defined there, not here.

export class ControlPlaneError extends Error {
  constructor(message, code) {
    super(message);
    this.name = new.target.name;
    this.code = code || new.target.name;
  }
}

// The exclusive lock could not be acquired within the timeout.
export class LockTimeoutError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'lock_timeout');
    this.detail = detail || null;
  }
}

// The `flock(1)` helper is unavailable or failed for a reason other than contention.
export class LockUnavailableError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'lock_unavailable');
    this.detail = detail || null;
  }
}

// The exclusive lock was lost mid-section (the flock holder died before the work
// committed). The in-flight transaction must roll back rather than commit under a
// lock we no longer hold.
export class LockLostError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'lock_lost');
    this.detail = detail || null;
  }
}

// A canonicalized pgdata path escaped its parent (symlink swap / traversal), or a
// path invariant from the first-init protocol (spec section 2.2) failed.
export class PathIntegrityError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'path_integrity');
    this.detail = detail || null;
  }
}

// A caller tried to open PGlite outside the sanctioned engine factory, or without
// holding a currently-live exclusive lock. Enforces the runtime owner guard
// (spec section 2.2).
export class OwnerGuardError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'owner_guard');
    this.detail = detail || null;
  }
}

// A required argument was missing or invalid at the command surface.
export class ValidationError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'validation');
    this.detail = detail || null;
  }
}
