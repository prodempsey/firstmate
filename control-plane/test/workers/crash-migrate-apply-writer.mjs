// Crash-probe worker for the CW1 migrate-apply partial-resume test
// (t_migrate_apply_resumes_after_real_child_crash).
//
// The parent has already `cp init`ed an isolated store and written an S8 report fixture
// whose mapped set contains several fully-assemblable, queued, order-linked tasks. This
// worker drives the REAL migrate-apply executor but HARD-EXITS via the afterApply hook
// AFTER exactly CP_CRASH_AFTER create-task commits and BEFORE the run finishes (so the
// residual/verification report is never written and later applies never run).
//
// This is a genuine writer-exit, not a caught in-process throw: each create-task
// commits-and-closes its own PGlite transaction before returning, so the process
// vanishing here leaves the first CP_CRASH_AFTER tasks durably committed (each with its
// migrate-apply:create-task:<id> command_results row) and the rest not begun. The parent
// then reruns with --resume and asserts the migration completes idempotently and
// reconciles.
import { runMigrateApply } from '../../lib/migrate-apply.mjs';

const crashAfter = Number(process.env.CP_CRASH_AFTER || '1');

await runMigrateApply({
  reportPath: process.env.CP_REPORT,
  dataDir: process.env.CP_DATA_DIR,
  outPath: process.env.CP_OUT,
  resume: process.env.CP_RESUME === '1',
  hooks: {
    afterApply: (n) => {
      if (n >= crashAfter) {
        // The n-th create-task has already committed; exit hard before doing any more.
        process.exit(42);
      }
    }
  }
});

// Unreachable when a crash is requested; a clean run (crashAfter huge) exits 0.
process.exit(0);
