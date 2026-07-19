// Package-private exclusive-transaction runtime.
//
// The raw exclusive-transaction primitive (the only thing that hands out a
// connection with unrestricted query/exec) must NOT be reachable from a public
// store instance. Round-1/round-2 attempts that put it on the instance - a named
// method, then a symbol-keyed method - both failed QA because the surface was
// merely obscured: `Object.getOwnPropertySymbols`/`getOwnPropertyNames` on a
// public store still enumerated a callable that ran arbitrary SQL
// (data/qa-s0r2-q23/report.md finding 1).
//
// The primitive now lives OFF the instance entirely, in a module-private WeakMap
// keyed by the store object. A public store instance exposes no property, symbol,
// or private field that yields it; enumerating the instance or its prototype
// reveals nothing callable that runs SQL, and there is no exported capability that
// restores raw SQL access to an outside caller holding only the store.
//
// SANCTIONED IN-PACKAGE EXTENSION PATH (explicitly for future slices, e.g. S1):
//   An adapter registers its raw primitive once, in its constructor:
//       registerExclusive(this, (fn) => this.#exclusiveImpl(fn));
//   In-package domain code (base store methods today; new lib/ modules in S1)
//   runs a transaction by importing this module and calling:
//       import { runExclusive } from './internal-runtime.mjs';
//       await runExclusive(store, async (conn) => { ...conn.query/exec... });
//   This module is NEVER re-exported from the package's public entrypoint
//   (bin/cp.mjs). Reaching the primitive therefore requires deep-importing this
//   internal module from inside the package - the same trust boundary S1's own
//   lib/ modules already live within - and is impossible with only the public
//   store object and public API. That is the whole point: S1 can extend the
//   domain from new lib/ modules without reopening a public arbitrary-SQL hole.

const impls = new WeakMap();

// Register a store's raw exclusive primitive. Called once by an adapter
// constructor. `fn` is `(callback) => Promise` where callback receives the
// engine-neutral connection { query, exec }.
export function registerExclusive(store, fn) {
  if (typeof fn !== 'function') {
    throw new TypeError('registerExclusive requires a function');
  }
  impls.set(store, fn);
}

// Run `callback` inside `store`'s exclusive transaction. In-package domain code
// only. Throws if the store never registered a primitive (an abstract base or a
// misconstructed adapter).
export function runExclusive(store, callback) {
  const impl = impls.get(store);
  if (!impl) {
    throw new Error('control-plane store has no registered exclusive primitive');
  }
  return impl(callback);
}
