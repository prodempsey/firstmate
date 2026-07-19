import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { PgHostedContractStore } from '../lib/pg-hosted-contract-store.mjs';
import { startEmbeddedPostgres } from './pg-fixture.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

after(cleanupAll);

// The S0 storage-seam contract, expressed once and run against any adapter. It
// uses only the core tables (schema_meta, coordinator_state) so it exercises
// open/lock/transaction/durability "without domain tables" (spec section 12, S0
// acceptance), and proves the seam is not tied to any one engine's serialization.
async function runSeamContract(store) {
  await store.init({ homeLabel: 'contract' });

  const tables = await store.tableNames();
  assert.ok(tables.includes('schema_meta') && tables.includes('coordinator_state'), 'core tables present');
  assert.ok(!tables.includes('tasks'), 'contract runs without domain tables');

  // Exclusive transactional write is visible to a subsequent locked read.
  const probe1 = await store.contractProbe();
  assert.equal(probe1.after, probe1.before + 1, 'commit_sequence advanced by exactly one');

  // Durability: a second exclusive section sees the committed increment.
  const probe2 = await store.contractProbe();
  assert.equal(probe2.before, probe1.after, 'prior commit is durable across exclusive sections');
  assert.equal(probe2.after, probe2.before + 1);
}

test('seam contract runs against PGlite (core tables only)', async () => {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  try {
    await runSeamContract(store);
  } finally {
    await store.close();
  }
});

test('seam contract runs against a real multi-connection Postgres fixture', async (t) => {
  const fixture = await startEmbeddedPostgres();
  if (fixture.unavailable) {
    t.skip(`hosted Postgres fixture unavailable on this platform: ${fixture.unavailable}`);
    return;
  }
  const store = await PgHostedContractStore.create({ connString: fixture.connString });
  try {
    await runSeamContract(store);
  } finally {
    await store.close();
    await fixture.stop();
  }
});
