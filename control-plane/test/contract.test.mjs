import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { PgHostedContractStore, HostedAdapterUnavailable } from '../lib/pg-hosted-contract-store.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

after(cleanupAll);

// The S0 storage-seam contract, expressed once and run against any adapter. It
// uses only the core tables (schema_meta, coordinator_state) so it exercises
// open/lock/transaction/durability "without domain tables" (spec section 12, S0
// acceptance), and proves the seam is not tied to any one engine's serialization.
async function runSeamContract(store) {
  await store.initCore({ homeLabel: 'contract' });

  // Exclusive transactional write is visible to a subsequent locked read.
  const probe1 = await store.contractProbe();
  assert.equal(probe1.after, probe1.before + 1, 'commit_sequence advanced by exactly one');

  // Durability: a second exclusive section sees the committed increment.
  const probe2 = await store.contractProbe();
  assert.equal(probe2.before, probe1.after, 'prior commit is durable across exclusive sections');
  assert.equal(probe2.after, probe2.before + 1);
}

test('seam contract runs against PGlite without domain tables', async () => {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  try {
    await runSeamContract(store);

    // Prove no domain table exists after initCore.
    const hasTasks = await store.runExclusive(async (conn) => {
      const r = await conn.query(
        "SELECT count(*)::int n FROM information_schema.tables WHERE table_schema='public' AND table_name='tasks'"
      );
      return Number(r.rows[0].n);
    });
    assert.equal(hasTasks, 0, 'initCore must not create domain tables');
  } finally {
    await store.close();
  }
});

test('seam contract runs against the test-only hosted adapter (skips if unavailable)', async (t) => {
  let store;
  try {
    store = await PgHostedContractStore.create();
  } catch (error) {
    if (error instanceof HostedAdapterUnavailable) {
      t.skip(`hosted adapter unavailable: ${error.message} (set CP_HOSTED_TEST_URL + install pg to run)`);
      return;
    }
    throw error;
  }
  try {
    await runSeamContract(store);
  } finally {
    await store.close();
  }
});
