import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { openPglite } from '../lib/pglite-engine.mjs';
import { acquireFlock } from '../lib/flock.mjs';
import { OwnerGuardError } from '../lib/errors.mjs';
import { findViolations } from '../scripts/check-no-direct-pglite.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

after(cleanupAll);

test('runtime guard: openPglite refuses without a lock handle', async () => {
  const dir = path.join(mkTempDir(), 'pgdata');
  fs.mkdirSync(dir);
  await assert.rejects(() => openPglite(dir, undefined), OwnerGuardError);
  await assert.rejects(() => openPglite(dir, {}), OwnerGuardError);
});

test('runtime guard: openPglite refuses a released lock handle', async () => {
  const base = mkTempDir();
  const dir = path.join(base, 'pgdata');
  fs.mkdirSync(dir);
  const lock = path.join(base, 'pgdata.lock');
  const handle = await acquireFlock(lock, { exclusive: true, timeoutMs: 5000 });
  await handle.release();
  await assert.rejects(() => openPglite(dir, handle), OwnerGuardError);
});

test('runtime guard: openPglite refuses a shared (non-exclusive) lock', async () => {
  const base = mkTempDir();
  const dir = path.join(base, 'pgdata');
  fs.mkdirSync(dir);
  const lock = path.join(base, 'pgdata.lock');
  const handle = await acquireFlock(lock, { exclusive: false, timeoutMs: 5000 });
  try {
    await assert.rejects(() => openPglite(dir, handle), OwnerGuardError);
  } finally {
    await handle.release();
  }
});

test('static guard: no shipped file constructs PGlite outside the engine module', () => {
  const violations = findViolations();
  assert.deepEqual(violations, [], `unexpected direct-PGlite usage: ${violations.join(', ')}`);
});

test('static guard: a planted violation is detected', () => {
  const root = mkTempDir();
  fs.mkdirSync(path.join(root, 'lib'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'lib', 'rogue.mjs'),
    "import { PGlite } from '@electric-sql/pglite';\nnew PGlite('/tmp/x');\n"
  );
  const violations = findViolations(root);
  assert.deepEqual(violations, [path.join('lib', 'rogue.mjs')]);
});
