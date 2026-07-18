// Typed control-plane errors.
//
// S0 defines the error taxonomy the coordinator raises. The command-conflict
// errors (IdempotencyConflictError, CausalOrderingError, TerminalConflictError)
// are named by the spec (section 6.2) and are defined here so later slices raise
// the same types; S0 itself only needs the store/init/guard errors, but the
// taxonomy is owned in one place.

export class ControlPlaneError extends Error {
  constructor(message, code) {
    super(message);
    this.name = new.target.name;
    this.code = code || new.target.name;
  }
}

// Storage-seam / lifecycle errors (S0 scope).

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

// A canonicalized pgdata path escaped its parent (symlink swap / traversal), or a
// path invariant from the first-init protocol (spec section 2.2) failed.
export class PathIntegrityError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'path_integrity');
    this.detail = detail || null;
  }
}

// A caller tried to open PGlite outside the sanctioned engine factory, or without
// holding the exclusive lock. Enforces the runtime owner guard (spec section 2.2).
export class OwnerGuardError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'owner_guard');
    this.detail = detail || null;
  }
}

// A required argument was missing or a value was invalid at the command surface.
export class ValidationError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'validation');
    this.detail = detail || null;
  }
}

// A domain constraint the store enforces above raw SQL was violated (e.g. an
// origin/order-ref mismatch surfaced as a typed error rather than a raw DB error).
export class ConstraintError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'constraint');
    this.detail = detail || null;
  }
}

// Command-conflict errors (spec section 6.2). Defined in S0's taxonomy; the
// conflict-audit transaction that coalesces anomalies for these is later-slice.

export class IdempotencyConflictError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'idempotency_conflict');
    this.detail = detail || null;
  }
}

export class CausalOrderingError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'causal_ordering_violation');
    this.detail = detail || null;
  }
}

export class TerminalConflictError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'terminal_conflict');
    this.detail = detail || null;
  }
}
