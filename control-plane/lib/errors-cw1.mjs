import { ControlPlaneError } from './errors.mjs';

// CW1 (cutover stage 1) owns the migrate-APPLY error taxonomy. Where S8's
// `migrate-report` was a strictly read-only shadow read that could only fail at the
// surface or on a legacy read, migrate-apply is the executor that turns the S8
// report's `mapped` proposals into real control-plane records through the landed cp
// verbs. Its failures are therefore of two kinds: a surface/validation failure
// (MigrateApplyError) and a post-apply reconciliation failure (MigrateReconcileError).
//
// migrate-apply NEVER opens a legacy store - its INPUT is the S8 report file, not the
// legacy home - so there is deliberately no legacy-read error here; the legacy stores
// stay read-only by construction because this verb never touches them.

// A required migrate-apply argument was missing or invalid at the command surface
// (no --report/--data-dir/--out, an unreadable or malformed report, a report whose
// own totality does not reconcile, an --out that resolves under the target store, or
// a target that already holds applied migration state without --resume).
export class MigrateApplyError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'migrate_apply');
    this.detail = detail || null;
  }
}

// The apply completed but its built-in reconciliation failed: applied + residual did
// not equal the report's mapped + flagged, the store's task/run/event counts did not
// match the applied proposals, or the post-apply snapshot did not succeed. This is a
// loud stop-and-investigate - a migration whose totals do not reconcile must never be
// reported as clean. The residual/verification report is still written (for audit)
// before this is raised; its path is carried in the detail.
export class MigrateReconcileError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'migrate_reconcile');
    this.detail = detail || null;
  }
}
