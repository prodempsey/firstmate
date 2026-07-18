import { PGlite } from '@electric-sql/pglite';
import { isFlockHandleLive } from './flock.mjs';
import { OwnerGuardError } from './errors.mjs';

// SOLE OWNER of PGlite construction.
//
// This is the only module in the package permitted to call `new PGlite(...)`.
// The static owner-guard check (scripts/check-no-direct-pglite.mjs) fails CI if
// `new PGlite(` appears in any other file, and the runtime owner guard below
// refuses to open unless the caller presents a currently-held exclusive flock
// handle (spec section 2.2: "Direct new PGlite(dataDir) outside the coordinator
// package is forbidden by lint/CI and a runtime owner guard").
//
// Because the capability to open IS proof of holding the lock, it is impossible
// to open the data directory without serializing through flock, including reads.

export async function openPglite(dataDir, lockHandle) {
  if (!isFlockHandleLive(lockHandle)) {
    throw new OwnerGuardError(
      'refusing to open PGlite without a currently-held control-plane lock',
      { dataDir }
    );
  }
  if (!lockHandle.exclusive) {
    throw new OwnerGuardError(
      'refusing to open PGlite under a shared lock; the writer path requires an exclusive lock',
      { dataDir }
    );
  }
  // relaxedDurability disabled per spec section 2.1.
  return PGlite.create({ dataDir, relaxedDurability: false });
}
