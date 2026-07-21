import { ControlPlaneError } from './errors.mjs';

// S8 owns the migrate-report error taxonomy (spec section 12 S8 row; section 13
// "Migration posture: cp migrate-report is read-only"). Migration is a strictly
// read-only shadow read over the legacy stores that emits a proposal and applies
// nothing, so the only failures S8 can raise are surface/validation failures
// (bad flags) and a legacy-store read failure - never a mutation failure, because
// S8 never mutates a legacy store.

// A required migrate-report argument was missing or invalid at the command surface
// (e.g. no --out, or --out pointing inside the legacy home it would read).
export class MigrateReportError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'migrate_report');
    this.detail = detail || null;
  }
}

// A legacy store could not be read. The shadow read opens legacy paths for READ
// ONLY; an unreadable store (permissions, a directory where a file was expected)
// surfaces loudly rather than being silently treated as empty, so a truncated
// migration proposal can never masquerade as a complete one.
export class LegacyReadError extends ControlPlaneError {
  constructor(message, detail) {
    super(message, 'legacy_read');
    this.detail = detail || null;
  }
}
