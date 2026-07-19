// Typed control-plane errors owned by S1.
//
// S0's errors.mjs deliberately defers the command-conflict taxonomy to the slice
// that owns the verbs raising them ("Command-conflict errors ... belong to the
// slices that own the verbs that raise them and are defined there, not here.").
// S1 owns create-task/begin-run/event and the command-conflict audit, so the
// three conflict/transition errors it raises are defined here. Each extends the
// S0 ControlPlaneError so bin/cp.mjs's typed-error mapping (message/code/detail ->
// nonzero exit) works uniformly without any S0 change.

import { ControlPlaneError } from './errors.mjs';

// A command-id was reused with a DIFFERENT request payload than the stored result
// (spec section 6.2). The rejected mutation is rolled back and an
// `idempotency_conflict` anomaly is persisted before this is raised.
export class IdempotencyConflictError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'idempotency_conflict');
    this.detail = detail || null;
  }
}

// A mutation acted on a stale causal token: a non-replay CAS miss on
// `tasks.revision`, or a producer sequence at or below the stored high-water
// (ruling Q4/Q5). The rejected mutation is rolled back and a
// `causal_ordering_violation` anomaly is persisted before this is raised.
export class CausalOrderingError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'causal_ordering_violation');
    this.detail = detail || null;
  }
}

// The requested transition is not legal from the task/run's current state (spec
// section 4 transitions), or an event type must go through its owning wrapper
// rather than generic append (spec section 3.1). A caller/routing error: the
// transaction is rolled back and NO anomaly is recorded (it is not a
// causal/idempotency conflict).
export class StateTransitionError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'state_transition');
    this.detail = detail || null;
  }
}
