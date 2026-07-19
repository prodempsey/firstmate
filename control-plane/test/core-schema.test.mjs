import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

after(cleanupAll);

// S0 owns exactly two tables. `cp init` must create these and NOTHING else;
// domain tables ship in their owning slices (spec-amend-s4 section 12, S0 row;
// section 3.2 "S0 tests only store-open/init/lock/owner-guard behavior").
const S0_CORE_TABLES = ['coordinator_state', 'schema_meta'];

test('init creates exactly the two S0 core tables and no domain tables', async () => {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init();

  const tables = await store.tableNames();
  assert.deepEqual(tables, S0_CORE_TABLES, 'only the S0 core tables exist');

  // Explicitly assert the S1+ domain tables are absent.
  for (const t of ['tasks', 'runs', 'task_events', 'outbox', 'snapshots']) {
    assert.ok(!tables.includes(t), `domain table ${t} must not exist in S0`);
  }
});

test('core schema is idempotent and survives close/reopen', async () => {
  const { fmHome } = mkFixtureHome();
  await new PgliteLocalStore({ fmHome }).init();
  // Re-applying over an existing schema is a clean no-op.
  await new PgliteLocalStore({ fmHome }).init();

  // A fresh store instance re-opens the same on-disk pgdata (persistent NodeFS).
  const meta = await new PgliteLocalStore({ fmHome }).schemaMeta();
  assert.equal(meta.schema_version, 's0');
  assert.match(meta.home_uuid, /^[0-9a-f-]{36}$/);
});
