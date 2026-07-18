import fs from 'node:fs';
import path from 'node:path';
import { ControlPlaneStore } from './control-plane-store.mjs';
import { openPglite } from './pglite-engine.mjs';
import { acquireFlock, withFlock } from './flock.mjs';
import { resolveDataPaths } from './paths.mjs';
import { PathIntegrityError } from './errors.mjs';

// Production S0 storage adapter: PGlite persistent NodeFS behind the storage
// seam, serialized by real flock(2). Implements the first-init and steady-state
// protocols of spec section 2.2. One PGlite instance is opened and closed per
// exclusive section (no long-lived connection), and every open - reads included -
// is gated by an exclusive flock.
export class PgliteLocalStore extends ControlPlaneStore {
  constructor({ dataDir, fmHome, env } = {}) {
    super();
    // Pre-canonical layout; canonicalization happens per-open in _resolveCanonical.
    this._layout = resolveDataPaths({ dataDir, fmHome, env });
    this._lockTimeoutMs = Number((env || process.env).CP_LOCK_TIMEOUT_MS || 15000);
  }

  static create(options = {}) {
    return new PgliteLocalStore(options);
  }

  get dataDir() {
    return this._layout.pgdata;
  }

  // Resolve the canonical pgdata + lock paths, creating pgdata on first init.
  //
  // First-init protocol (spec section 2.2, steps 1-6): under an exclusive
  // parent-scoped init lock, canonicalize the parent, create pgdata 0700 if
  // absent, canonicalize the child, verify it did not escape the canonical parent
  // via a symlink, and derive the canonical sibling lock path.
  //
  // Steady state: pgdata already exists, so we canonicalize and verify without the
  // init lock (the spec's steady-state protocol does not take the init lock).
  async _resolveCanonical() {
    const { parent, pgdata, initLock } = this._layout;
    // Ensure the control-plane parent dir exists so it can be canonicalized.
    fs.mkdirSync(parent, { recursive: true, mode: 0o700 });

    if (fs.existsSync(pgdata)) {
      return this._canonicalizeExisting(parent, pgdata);
    }

    // First init: serialize creation with the parent-scoped init lock.
    return withFlock(
      initLock,
      async () => {
        if (!fs.existsSync(pgdata)) {
          fs.mkdirSync(pgdata, { mode: 0o700 });
        }
        return this._canonicalizeExisting(parent, pgdata);
      },
      { timeoutMs: this._lockTimeoutMs }
    );
  }

  _canonicalizeExisting(parent, pgdata) {
    const canonicalParent = fs.realpathSync(parent);
    const canonicalChild = fs.realpathSync(pgdata);
    // The canonical child must sit directly inside the canonical parent; anything
    // else means a symlink swapped the path out from under us.
    if (path.dirname(canonicalChild) !== canonicalParent) {
      throw new PathIntegrityError(
        'pgdata canonical path escaped its canonical parent (symlink swap?)',
        { canonicalParent, canonicalChild }
      );
    }
    const stat = fs.lstatSync(canonicalChild);
    if (!stat.isDirectory()) {
      throw new PathIntegrityError('pgdata is not a directory', { canonicalChild });
    }
    const lock = path.join(canonicalParent, `${path.basename(canonicalChild)}.lock`);
    return { pgdata: canonicalChild, lock };
  }

  // The one seam primitive. Acquire exclusive flock, open exactly one PGlite,
  // run fn inside an explicit transaction, then close PGlite before releasing the
  // lock (close-before-unlock is mandatory - spec section 2.2).
  async runExclusive(fn) {
    const { pgdata, lock } = await this._resolveCanonical();
    const handle = await acquireFlock(lock, { exclusive: true, timeoutMs: this._lockTimeoutMs });
    let db;
    try {
      db = await openPglite(pgdata, handle);
      const conn = makeConn(db);
      await db.query('BEGIN');
      let result;
      try {
        result = await fn(conn);
        await db.query('COMMIT');
      } catch (error) {
        try {
          await db.query('ROLLBACK');
        } catch {
          // A failed rollback still gets the connection closed below.
        }
        throw error;
      }
      return result;
    } finally {
      if (db) {
        await db.close();
      }
      await handle.release();
    }
  }
}

// Adapt a PGlite instance to the seam's connection shape: parameterized `query`
// plus multi-statement `exec` (schema application).
function makeConn(db) {
  return {
    query: (sql, params) => db.query(sql, params),
    exec: (sql) => db.exec(sql)
  };
}
