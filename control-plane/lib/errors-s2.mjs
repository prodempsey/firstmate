// Typed control-plane errors owned by S2.
//
// S0's errors.mjs defers the command-conflict taxonomy to the slice that owns the
// verbs raising them; S1 defined the idempotency/causal/transition trio for its own
// verbs (errors-s1.mjs). S2 owns complete/fail/cancel and the terminal-conflict
// class, so it is defined here. It extends the S0 ControlPlaneError so bin/cp.mjs's
// typed-error mapping (message/code/detail -> nonzero exit) works uniformly without
// any S0 change.

import { ControlPlaneError } from './errors.mjs';

// A terminal commit was attempted against a generation that is ALREADY closed, or
// that already carries a terminal event (spec section 6.2). Two paths raise it and
// both are audited identically:
//
//   * the explicit guard - the run's closed_at is non-null when complete/fail runs;
//   * the ux_terminal_per_gen unique violation - a terminal task_events row already
//     exists for the generation even though the run read as open (the belt-and-
//     braces path; a 23505 there is remapped to this error rather than escaping as
//     a raw driver fault).
//
// Like the S1 conflict classes, the rejected mutation is rolled back to the command
// savepoint and a `terminal_conflict` anomaly is persisted before this is raised.
// Distinct from CausalOrderingError: the caller's causal token may be perfectly
// current: the generation is simply already terminal, and a second terminal outcome
// for one generation is never legal.
export class TerminalConflictError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'terminal_conflict');
    this.detail = detail || null;
  }
}
