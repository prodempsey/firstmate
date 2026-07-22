// Crash-probe worker for the CW1 migrate-apply partial-resume test
// (t_migrate_apply_resumes_after_real_child_crash).
//
// The parent has `cp init`ed an isolated store and written an S8 report fixture. This
// worker drives the REAL migrate-apply executor but HARD-EXITS via the afterTask hook once
// CP_CRASH_AFTER tasks have been materialized, BEFORE the run finishes (so the
// residual/verification report is never written and later tasks never run).
//
// This is a genuine writer-exit, not a caught in-process throw: every verb the executor
// issues commits-and-closes its own PGlite transaction before returning, so the process
// vanishing here leaves the already-materialized tasks (and their migrate-apply command_
// results rows) durable and the rest not begun. The parent then reruns with --resume and
// asserts the migration completes idempotently and reconciles.
import { runMigrateApply } from '../../lib/migrate-apply.mjs';

const crashAfter = Number(process.env.CP_CRASH_AFTER || '1');

await runMigrateApply({
  reportPath: process.env.CP_REPORT,
  dataDir: process.env.CP_DATA_DIR,
  outPath: process.env.CP_OUT,
  resume: process.env.CP_RESUME === '1',
  allowResidualOver: Number(process.env.CP_ALLOW || '100'),
  hooks: {
    afterTask: (tasksCreated) => {
      if (tasksCreated >= crashAfter) process.exit(42);
    }
  }
});

// Unreachable when a crash is requested; a clean run (crashAfter huge) exits 0.
process.exit(0);
