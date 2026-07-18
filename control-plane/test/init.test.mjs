import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { PathIntegrityError } from '../lib/errors.mjs';
import { mkFixtureHome, mkTempDir, cleanupAll } from './helpers.mjs';

after(cleanupAll);

test('first init works when pgdata is absent', async () => {
  const { fmHome, dataDir } = mkFixtureHome();
  assert.equal(fs.existsSync(dataDir), false, 'precondition: pgdata absent');

  const store = new PgliteLocalStore({ fmHome });
  const result = await store.init({ homeLabel: 'fixture-a' });
  await store.close();

  assert.equal(fs.existsSync(dataDir), true, 'pgdata created');
  assert.match(result.homeUuid, /^[0-9a-f-]{36}$/, 'home_uuid minted');
  assert.equal(result.schemaVersion, 's0');

  // Seeded core state is readable.
  const state = await new PgliteLocalStore({ fmHome }).coordinatorState();
  assert.equal(Number(state.domain_revision), 0);
  assert.equal(Number(state.commit_sequence), 0);
});

test('init is idempotent and home_uuid is stable', async () => {
  const { fmHome } = mkFixtureHome();
  const first = await new PgliteLocalStore({ fmHome }).init();
  const second = await new PgliteLocalStore({ fmHome }).init();
  assert.equal(first.homeUuid, second.homeUuid, 'home_uuid never rewritten');
});

test('our creation of pgdata uses mode 0700 (spec section 2.2 step 3)', async () => {
  const { fmHome, dataDir } = mkFixtureHome();
  // _resolveCanonical performs the mkdir; inspect the mode before any PGlite open.
  const store = new PgliteLocalStore({ fmHome });
  await store._resolveCanonical();
  const mode = fs.statSync(dataDir).mode & 0o777;
  assert.equal(mode, 0o700, `expected our mkdir to be 0700, got ${mode.toString(8)}`);
});

test('pgdata is never world-accessible at rest', async () => {
  const { fmHome, dataDir } = mkFixtureHome();
  await new PgliteLocalStore({ fmHome }).init();
  // PGlite's embedded Postgres normalizes the data dir to its own secure mode
  // (0750) during initdb. The durable invariant is: owner has full access and the
  // world has none.
  const mode = fs.statSync(dataDir).mode & 0o777;
  assert.equal(mode & 0o700, 0o700, 'owner retains full access');
  assert.equal(mode & 0o007, 0, `no world permissions, got ${mode.toString(8)}`);
});

test('explicit --data-dir override initializes independently', async () => {
  const base = mkTempDir();
  const dataDir = path.join(base, 'nested', 'pgdata');
  const store = new PgliteLocalStore({ dataDir });
  const result = await store.init();
  assert.equal(fs.existsSync(dataDir), true);
  assert.match(result.homeUuid, /^[0-9a-f-]{36}$/);
});

test('symlink escape of pgdata is rejected', async () => {
  const parentBase = mkTempDir();
  const parent = path.join(parentBase, 'control-plane');
  fs.mkdirSync(parent, { recursive: true });
  // pgdata is a symlink pointing OUTSIDE its parent -> canonical child escapes.
  const outside = mkTempDir('cp-s0-outside-');
  const realTarget = path.join(outside, 'evil-pgdata');
  fs.mkdirSync(realTarget);
  const pgdata = path.join(parent, 'pgdata');
  fs.symlinkSync(realTarget, pgdata);

  const store = new PgliteLocalStore({ dataDir: pgdata });
  await assert.rejects(() => store.init(), (err) => {
    assert.ok(err instanceof PathIntegrityError, `expected PathIntegrityError, got ${err.name}`);
    return true;
  });
});
