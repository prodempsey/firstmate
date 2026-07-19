import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { mkFixtureHome, cleanupAll } from './helpers.mjs';

after(cleanupAll);

// Regression for data/qa-s0r2-q23 finding 1 (BLOCKER): the raw
// exclusive-transaction primitive must be UNDISCOVERABLE and UNINVOKABLE from a
// public store instance. The prior symbol-keyed method failed because
// Object.getOwnPropertySymbols enumerated it.

test('no symbol-keyed member is reachable anywhere on a public store or its chain', async () => {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init();

  const allSymbols = [];
  let obj = store;
  while (obj && obj !== Object.prototype) {
    allSymbols.push(...Object.getOwnPropertySymbols(obj));
    obj = Object.getPrototypeOf(obj);
  }
  assert.deepEqual(allSymbols, [], `unexpected symbol members: ${allSymbols.map(String).join(', ')}`);
});

test('the QA functional repro cannot run arbitrary SQL from a public store', async () => {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init();

  // Step 2-3 of the QA repro: enumerate the prototype's symbols, select a callable,
  // and try to invoke it with a callback that creates an arbitrary table.
  const protoSymbols = Object.getOwnPropertySymbols(Object.getPrototypeOf(store));
  const callableSymbol = protoSymbols.find((s) => typeof store[s] === 'function');
  assert.equal(callableSymbol, undefined, 'no callable symbol exists to invoke');

  let arbitrarySqlSucceeded = false;
  if (callableSymbol) {
    try {
      await store[callableSymbol](async (conn) => {
        await conn.exec('CREATE TABLE qa_arbitrary_sql (x int)');
      });
      arbitrarySqlSucceeded = true;
    } catch {
      arbitrarySqlSucceeded = false;
    }
  }
  assert.equal(arbitrarySqlSucceeded, false, 'arbitrary SQL mutation must not succeed');

  // Step 4: the arbitrary table must not exist; only the core tables remain.
  const tables = await store.tableNames();
  assert.ok(!tables.includes('qa_arbitrary_sql'), 'no arbitrary table was created');
  assert.deepEqual(tables, ['coordinator_state', 'schema_meta']);
});

test('sanctioned in-package extension path still runs domain transactions (S1 relies on this)', async () => {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init();

  // In-package domain code (base store methods today; new lib/ modules in S1)
  // reaches the exclusive primitive ONLY by importing internal-runtime.mjs. This
  // is the documented, sanctioned path - not reachable from a public store object.
  const one = await runExclusive(store, async (conn) => {
    const r = await conn.query('SELECT 1 AS one');
    return Number(r.rows[0].one);
  });
  assert.equal(one, 1);
});
