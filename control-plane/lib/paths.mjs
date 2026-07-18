import path from 'node:path';
import { ValidationError } from './errors.mjs';

// Resolve the control-plane data directory (the PGlite `pgdata`) and its lock
// paths. Per spec section 2.1 the production location is
// FM_HOME/state/control-plane/pgdata with a sibling lock at pgdata.lock; the
// first-init lock is .pgdata.init.lock in the same parent (spec section 2.2).
//
// An explicit dataDir (from `cp init --data-dir` or a test fixture) overrides the
// FM_HOME derivation. Everything is returned as an absolute path; the store still
// re-canonicalizes with realpath at open time before deriving the lock, so this
// is only the pre-canonical layout.
export function resolveDataPaths({ dataDir, fmHome, env = process.env } = {}) {
  let pgdata = dataDir;
  if (!pgdata) {
    const home = fmHome || env.FM_HOME;
    if (!home) {
      throw new ValidationError(
        'no data directory: pass --data-dir or set FM_HOME',
        { hint: 'FM_HOME/state/control-plane/pgdata' }
      );
    }
    pgdata = path.join(home, 'state', 'control-plane', 'pgdata');
  }
  pgdata = path.resolve(pgdata);
  const parent = path.dirname(pgdata);
  const base = path.basename(pgdata);
  return {
    pgdata,
    parent,
    lock: path.join(parent, `${base}.lock`),
    initLock: path.join(parent, `.${base}.init.lock`)
  };
}
