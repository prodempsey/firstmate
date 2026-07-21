import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Workflow 9 - PGlite durability / lock / reopen (spec matrix row 868): concurrent `cp`
// invocations serialize on the store flock; a process killed mid-transaction leaves NO
// partial commit after reopen; reads also take the lock; and the first-init missing-dataDir
// path works. All against the REAL cp CLI and real child processes. No real pane needed.
export const meta = { tmuxRequired: false };

const CRASH_WRITER = fileURLToPath(new URL('../fixtures/crash-writer.mjs', import.meta.url));

export async function run(h) {
  // (a) Concurrent cp invocations serialize. Launch many writers AND a reader at once; the
  // exclusive store flock forces them to serialize rather than corrupt each other. If
  // serialization were broken, PGlite would error or lose writes. All must succeed and the
  // final state must be exactly consistent with every write having landed once.
  const N = 6;
  const writers = Array.from({ length: N }, (_, i) => h.cpAsync(['create-task', `t-conc-${i}`, '--kind', 'ship', '--title', `c${i}`, '--origin', 'internal', '--internal-reason', 'r', '--command-id', `cc-${i}`]));
  const reader = h.cpAsync(['task-head', 't-conc-0']); // a concurrent READ also contends for the same lock
  const results = await Promise.all(writers);
  await reader; // its status is racy (target may not exist yet); the point is it locks without corrupting
  assert.ok(results.every((r) => r.status === 0), 'every concurrent writer committed (serialized, not corrupted)');
  const present = await h.read("SELECT count(*)::int AS n FROM tasks WHERE task_id LIKE 't-conc-%'");
  assert.equal(Number(present[0].n), N, 'exactly N tasks exist - no lost or double writes under contention');

  // (b) Kill mid-transaction and reopen: no partial commit. The crash worker exits inside
  // the BEGIN, before COMMIT.
  const countersBefore = (await h.read('SELECT domain_revision, commit_sequence FROM coordinator_state WHERE id = 1'))[0];
  const crash = spawnSync('node', [CRASH_WRITER], {
    encoding: 'utf8', env: { ...process.env, CP_FM_HOME: h.fmHome, CP_TASK_ID: 't-crash', CP_COMMAND_ID: 'c-crash' }
  });
  assert.equal(crash.status, 37, 'the writer hard-exited at the pre-commit fault seam');
  await h.reopenStore();
  const crashed = await h.read("SELECT count(*)::int AS n FROM tasks WHERE task_id = 't-crash'");
  assert.equal(Number(crashed[0].n), 0, 'the killed transaction left NO partial commit (task absent after reopen)');
  const countersAfter = (await h.read('SELECT domain_revision, commit_sequence FROM coordinator_state WHERE id = 1'))[0];
  assert.equal(Number(countersAfter.domain_revision), Number(countersBefore.domain_revision), 'domain_revision did not move for the rolled-back transaction');
  assert.equal(Number(countersAfter.commit_sequence), Number(countersBefore.commit_sequence), 'commit_sequence did not move for the rolled-back transaction');

  // (c) A read verb takes the lock too and returns a consistent view after the crash.
  const head = h.cp(['task-head', 't-conc-0']);
  assert.equal(head.json.status, 'queued', 'a locked read returns the committed state');

  // (d) First-init missing-dataDir path: point cp init at a dataDir that does NOT exist; it
  // must create it (owner-only) and initialize cleanly.
  const freshDataDir = path.join(h.worktree, 'fresh-pgdata');
  assert.equal(fs.existsSync(freshDataDir), false, 'the fresh dataDir does not exist yet');
  const initRes = spawnSync('node', [fileURLToPath(new URL('../../bin/cp.mjs', import.meta.url)), 'init', '--data-dir', freshDataDir, '--home-label', 'fresh'], { encoding: 'utf8', env: { ...process.env, FM_HOME: h.fmHome } });
  assert.equal(initRes.status, 0, `first-init on a missing dataDir succeeds: ${initRes.stderr}`);
  assert.equal(fs.existsSync(freshDataDir), true, 'the missing dataDir was created by first-init');
  assert.equal(fs.statSync(freshDataDir).mode & 0o007, 0, 'the created dataDir is not world-accessible');

  return { expectedActiveAnomalies: [] };
}
