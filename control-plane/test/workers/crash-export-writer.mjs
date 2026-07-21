// Crash-probe worker for t_export_crash_mid_write_leaves_no_partial_file.
//
// Runs `cp export-snapshot` but HARD-EXITS via the atomic-write `fault` seam at the
// exact cutpoint AFTER the temp file has been written+fsync'd and BEFORE the atomic
// rename to the final path. Because the export is temp -> fsync -> rename, the crash can
// only ever leave a stray temp file; the parent must observe NO file at the final
// CP_OUT path (never a torn/partial final file). A rerun then completes cleanly.
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { exportSnapshot } from '../../lib/projections.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
const outPath = process.env.CP_OUT;

await exportSnapshot(store, { outPath }, { fault: () => process.exit(48) });

// Unreachable: the fault must exit the process before the rename.
await store.close();
process.exit(0);
