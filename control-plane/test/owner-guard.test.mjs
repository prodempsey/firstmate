import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { openPglite } from '../lib/pglite-engine.mjs';
import { acquireFlock, isFlockHandleLive } from '../lib/flock.mjs';
import { OwnerGuardError } from '../lib/errors.mjs';
import { findViolations } from '../scripts/check-no-direct-pglite.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

after(cleanupAll);

function newPgdata() {
  const base = mkTempDir();
  const dir = path.join(base, 'pgdata');
  fs.mkdirSync(dir);
  return { base, dir, lock: path.join(base, 'pgdata.lock') };
}

test('runtime guard: openPglite refuses without a lock handle', async () => {
  const { dir } = newPgdata();
  await assert.rejects(() => openPglite(dir, undefined), OwnerGuardError);
  await assert.rejects(() => openPglite(dir, {}), OwnerGuardError);
});

test('runtime guard: openPglite refuses a released lock handle', async () => {
  const { dir, lock } = newPgdata();
  const handle = await acquireFlock(lock, { exclusive: true, timeoutMs: 5000 });
  await handle.release();
  assert.equal(isFlockHandleLive(handle), false);
  await assert.rejects(() => openPglite(dir, handle), OwnerGuardError);
});

test('runtime guard: openPglite refuses a shared (non-exclusive) lock', async () => {
  const { dir, lock } = newPgdata();
  const handle = await acquireFlock(lock, { exclusive: false, timeoutMs: 5000 });
  try {
    await assert.rejects(() => openPglite(dir, handle), OwnerGuardError);
  } finally {
    await handle.release();
  }
});

test('runtime guard: a dead flock holder invalidates the capability (no stale open)', async () => {
  const { dir, lock } = newPgdata();
  const handle = await acquireFlock(lock, { exclusive: true, timeoutMs: 5000 });
  assert.equal(isFlockHandleLive(handle), true, 'live immediately after acquire');

  // Kill the EXACT holder subprocess PID and wait for its exit. The kernel drops
  // the flock, so the capability must no longer authorize an open.
  const holderPid = handle._child.pid;
  await new Promise((res) => {
    handle._child.once('exit', res);
    process.kill(holderPid, 'SIGKILL');
  });

  assert.equal(isFlockHandleLive(handle), false, 'stale handle no longer live after holder death');
  await assert.rejects(() => openPglite(dir, handle), OwnerGuardError, 'no unlocked open on a dead holder');
});

test('static guard: the real repository has no direct-PGlite usage outside the engine', () => {
  const violations = findViolations();
  assert.deepEqual(violations, [], `unexpected direct-PGlite usage: ${violations.join(', ')}`);
});

test('static guard: a violation OUTSIDE the coordinator package is detected', () => {
  const root = mkTempDir();
  // Sanctioned engine file (allowed to construct PGlite).
  fs.mkdirSync(path.join(root, 'control-plane', 'lib'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'control-plane', 'lib', 'pglite-engine.mjs'),
    "import { PGlite } from '@electric-sql/pglite';\nexport const x = () => new PGlite('/d');\n"
  );
  // A rogue production module at the REPO ROOT bin/ (outside control-plane).
  fs.mkdirSync(path.join(root, 'bin'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'bin', 'rogue.mjs'),
    "import { PGlite } from '@electric-sql/pglite';\nnew PGlite('/tmp/x');\n"
  );
  // A test file and a node_modules file that must be ignored.
  fs.mkdirSync(path.join(root, 'control-plane', 'test'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'control-plane', 'test', 'x.test.mjs'),
    "const s = \"new PGlite('/no')\";\n"
  );
  fs.mkdirSync(path.join(root, 'node_modules', 'pkg'), { recursive: true });
  fs.writeFileSync(path.join(root, 'node_modules', 'pkg', 'index.mjs'), "new PGlite('/nm')\n");

  const violations = findViolations(root);
  assert.deepEqual(violations, ['bin/rogue.mjs'], 'only the out-of-package production module is flagged');
});
