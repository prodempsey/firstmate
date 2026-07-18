import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

after(cleanupAll);

const EXPECTED_TABLES = [
  'anomalies',
  'command_results',
  'consumer_cursors',
  'consumer_leases',
  'consumer_receipts',
  'coordinator_state',
  'outbox',
  'producer_highwater',
  'runs',
  'schema_meta',
  'snapshots',
  'task_events',
  'tasks'
];

test('full DDL applies clean: all control-plane tables present', async () => {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init();

  const tables = await store.runExclusive(async (conn) => {
    const r = await conn.query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name"
    );
    return r.rows.map((row) => row.table_name);
  });

  assert.deepEqual(tables, EXPECTED_TABLES, 'exactly the spec section-3 tables exist');
});

test('DDL is idempotent: re-init does not error and preserves data', async () => {
  const { fmHome } = mkFixtureHome();
  await new PgliteLocalStore({ fmHome }).init();
  // second application over an existing schema must be a clean no-op
  await new PgliteLocalStore({ fmHome }).init();

  const version = await new PgliteLocalStore({ fmHome }).runExclusive(async (conn) => {
    const r = await conn.query("SELECT value FROM schema_meta WHERE key='schema_version'");
    return r.rows[0].value;
  });
  assert.equal(version, 's0');
});

test('schema survives close/reopen (persistent NodeFS durability)', async () => {
  const { fmHome } = mkFixtureHome();
  await new PgliteLocalStore({ fmHome }).init();

  // A fresh store instance re-opens the same on-disk pgdata.
  const reopened = await new PgliteLocalStore({ fmHome }).runExclusive(async (conn) => {
    const r = await conn.query("SELECT count(*)::int AS n FROM schema_meta WHERE key='home_uuid'");
    return Number(r.rows[0].n);
  });
  assert.equal(reopened, 1, 'home_uuid persisted across reopen');
});
