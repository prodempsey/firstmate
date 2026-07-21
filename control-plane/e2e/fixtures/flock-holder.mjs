import fs from 'node:fs';
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';
import { runExclusive } from '../../lib/internal-runtime.mjs';

// A real child process that OPENS the store and enters the exclusive section, HOLDING the
// store flock, then either hangs to be killed mid-transaction (wf1's real restarts) or holds
// the lock until a release signal (wf9's read-lock contention proof). This is what makes
// wf1's "kill and reopen the store mid-lifecycle" and wf9's "reads also lock" claims about a
// genuine second process abruptly dying / genuinely contending, not an in-process close.
//
// env: CP_FM_HOME (required); CP_READY_FILE (required, written once the flock is held);
//      CP_MODE = 'kill'    -> optionally write CP_SENTINEL into command_results, then hang
//                             forever holding the flock mid-transaction (parent SIGKILLs it;
//                             the uncommitted write must roll back = no resurrection);
//                CP_MODE = 'release' -> hold the flock until CP_RELEASE_FILE appears, then
//                             leave the exclusive section (commit) and exit 0.
// A private SharedArrayBuffer gives a synchronous sleep with no busy-wait.

const BUF = new Int32Array(new SharedArrayBuffer(4));
const store = new PgliteLocalStore({ fmHome: process.env.CP_FM_HOME });
const mode = process.env.CP_MODE || 'kill';

await runExclusive(store, async (conn) => {
  await conn.query('SELECT 1'); // prove the exclusive section (and thus the flock) is held
  if (process.env.CP_SENTINEL) {
    // A write that MUST NOT persist if this process is killed here: it is inside the BEGIN
    // and never reaches COMMIT while we hang. command_results has no foreign keys.
    await conn.query(
      "INSERT INTO command_results (command_id, verb, request_hash, result_json, created_at) VALUES ($1, 'e2e-sentinel', 'h', '{}'::jsonb, now())",
      [process.env.CP_SENTINEL]
    );
  }
  fs.writeFileSync(process.env.CP_READY_FILE, 'ready');
  if (mode === 'release') {
    while (!fs.existsSync(process.env.CP_RELEASE_FILE)) Atomics.wait(BUF, 0, 0, 20);
    return; // leaving the callback commits and releases the lock cleanly
  }
  await new Promise(() => {}); // mode 'kill': hang forever holding the flock mid-transaction
});

process.exit(0);
