import { ControlPlaneError } from './errors.mjs';

// CW2 (cutover stage 2) owns the shadow-run + divergence-monitor + archive-back-fill
// error taxonomy. Three verbs live in this slice:
//
//   * the SHADOW WRITER (lib/shadow-writer.mjs, bin/cp-shadow.mjs) mirrors firstmate
//     lifecycle actions into the live control-plane store fire-and-forget. By contract it
//     NEVER throws to its caller (a shadow write must never block or fail a legacy
//     operation); every failure is logged to a divergence file and swallowed. So
//     ShadowWriteError exists for the CLI's own surface validation only (a malformed
//     invocation), never to signal a mirror failure to a lifecycle chokepoint.
//
//   * `cp shadow-diff` (lib/shadow-diff.mjs) is a strictly READ-ONLY comparison of the S8
//     mapper's regenerated legacy view against committed store state. Like migrate-report
//     it applies nothing; ShadowDiffError is a surface/read failure only.
//
//   * `cp migrate-backfill` (lib/migrate-backfill.mjs) imports the ARCHIVED-HISTORY
//     residual from the retained CW1 residual report as AUDIT-ONLY historical records. Its
//     input is the residual/report FILES, never a legacy store, so - like migrate-apply -
//     there is no legacy-read error here. BackfillError is a surface/validation failure;
//     BackfillReconcileError is the loud post-import totality failure.

// A shadow-writer CLI invocation was malformed at the command surface (unknown
// sub-action, missing task id). NEVER raised by the library's mirror methods, which
// return a structured outcome and log divergence instead of throwing (constraint 1).
export class ShadowWriteError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'shadow_write');
    this.detail = detail || null;
  }
}

// A required `cp shadow-diff` argument was missing or invalid, or a legacy read failed.
// shadow-diff writes nothing to the store or the legacy home; it emits one report file.
export class ShadowDiffError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'shadow_diff');
    this.detail = detail || null;
  }
}

// A required `cp migrate-backfill` argument was missing or invalid at the command surface
// (no --residual/--data-dir/--out, an unreadable or malformed residual report, an --out
// that resolves under the target store, or a target already holding back-fill state
// without --resume).
export class BackfillError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'migrate_backfill');
    this.detail = detail || null;
  }
}

// The back-fill completed but its built-in reconciliation failed: imported + flagged did
// not equal the archived-history residual population, or the committed archived_history
// row count did not match the imported records. A back-fill whose totals do not reconcile
// must never be reported as clean; the residual report is still written (for audit) before
// this is raised, and its path is carried in the detail.
export class BackfillReconcileError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'migrate_backfill_reconcile');
    this.detail = detail || null;
  }
}
