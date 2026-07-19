import { ControlPlaneStore } from './control-plane-store.mjs';
import { ControlPlaneError } from './errors.mjs';
import { RUN_EXCLUSIVE } from './internal-symbols.mjs';

// TEST-ONLY, NONPRODUCTION hosted adapter skeleton (spec section 2.1).
//
// It exists solely to run the storage-seam contract suite against a real
// multi-connection Postgres fixture, proving the seam's domain contract is not
// accidentally dependent on PGlite's single-connection serialization. It is NOT
// wired into FirstMate runtime and is NOT a hosted deployment.
//
// It depends on `pg` via dynamic import so `pg` never becomes a production
// dependency (`pg` is a devDependency only). If `pg` is absent or no connection
// string is provided, `create` throws HostedAdapterUnavailable.
//
// Exclusivity here is achieved by a Postgres session-level advisory lock plus an
// explicit transaction - a genuinely different mechanism from flock - so a green
// run demonstrates seam-level portability, not PGlite-specific behavior.

export class HostedAdapterUnavailable extends ControlPlaneError {
  constructor(message) {
    super(message, 'hosted_adapter_unavailable');
  }
}

// Fixed advisory-lock key that serializes exclusive sections across connections.
const ADVISORY_LOCK_KEY = 4228; // arbitrary stable constant for ORD-228 S0.

export class PgHostedContractStore extends ControlPlaneStore {
  constructor(pool) {
    super();
    this._pool = pool;
  }

  static async create({ connString, env = process.env } = {}) {
    const url = connString || env.CP_HOSTED_TEST_URL;
    if (!url) {
      throw new HostedAdapterUnavailable('no hosted connection string (set CP_HOSTED_TEST_URL)');
    }
    let pg;
    try {
      pg = await import('pg');
    } catch {
      throw new HostedAdapterUnavailable('the `pg` package is not installed (test-only dependency)');
    }
    const Pool = pg.default?.Pool || pg.Pool;
    const pool = new Pool({ connectionString: url, max: 4 });
    return new PgHostedContractStore(pool);
  }

  async [RUN_EXCLUSIVE](fn) {
    const client = await this._pool.connect();
    try {
      await client.query('SELECT pg_advisory_lock($1)', [ADVISORY_LOCK_KEY]);
      const conn = {
        query: (sql, params) => client.query(sql, params),
        exec: (sql) => client.query(sql)
      };
      await client.query('BEGIN');
      let result;
      try {
        result = await fn(conn);
        await client.query('COMMIT');
      } catch (error) {
        try {
          await client.query('ROLLBACK');
        } catch {
          // fall through to advisory unlock + client release
        }
        throw error;
      }
      return result;
    } finally {
      try {
        await client.query('SELECT pg_advisory_unlock($1)', [ADVISORY_LOCK_KEY]);
      } catch {
        // best effort; releasing the client below drops the session lock anyway
      }
      client.release();
    }
  }

  async close() {
    await this._pool.end();
  }
}
