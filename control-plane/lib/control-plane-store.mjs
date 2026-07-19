import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { runExclusive } from './internal-runtime.mjs';

const SQL_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'sql');
const CORE_SCHEMA = fs.readFileSync(path.join(SQL_DIR, 'core-schema.sql'), 'utf8');

const SCHEMA_VERSION = 's0';

// Engine-neutral control-plane store (S0 foundation).
//
// S0 owns only the two core tables (schema_meta, coordinator_state), the storage
// seam, the flock lifecycle, typed errors, and the hosted contract skeleton
// (spec-amend-s4 section 12, S0 row). Domain tables and their verbs ship in their
// owning slices (S1+); none exist here.
//
// PUBLIC SURFACE = the domain-level methods below only. The raw
// exclusive-transaction primitive (which hands out a connection with unrestricted
// query/exec) is NOT on the instance: it lives in a module-private WeakMap
// (internal-runtime.mjs) keyed by the store, so a public caller holding a store
// object cannot discover or invoke it (spec section 3.1; data/qa-s0r2-q23 finding
// 1). Adapters register their primitive in their constructor; in-package domain
// code reaches it via `runExclusive(this, fn)`. See internal-runtime.mjs for the
// sanctioned in-package extension path that S1 uses.
//
// Each adapter registers a primitive `(callback) => Promise` where callback gets
// the connection { query(sql, params), exec(sql) }; PgliteLocalStore uses flock +
// a fresh single connection per call, PgHostedContractStore uses a real Postgres
// connection with serializable/advisory-lock semantics. Because the domain never
// depends on how exclusivity is achieved, the seam is provably not tied to
// PGlite's single-connection serialization (spec section 2.1).
export class ControlPlaneStore {
  async close() {
    // Default: nothing long-lived to release.
  }

  // Initialize: apply ONLY the S0 core schema (schema_meta, coordinator_state) and
  // seed home_uuid. Idempotent (spec section 6). No domain tables are created here.
  async init({ homeLabel } = {}) {
    return runExclusive(this, async (conn) => {
      await conn.exec(CORE_SCHEMA);
      await conn.query('INSERT INTO coordinator_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING');

      // home_uuid is minted once and never rewritten.
      const existing = await conn.query("SELECT value FROM schema_meta WHERE key = 'home_uuid'");
      let homeUuid;
      if (existing.rows.length > 0) {
        homeUuid = existing.rows[0].value;
      } else {
        homeUuid = crypto.randomUUID();
        await conn.query('INSERT INTO schema_meta (key, value) VALUES ($1, $2)', ['home_uuid', homeUuid]);
      }
      await conn.query(
        `INSERT INTO schema_meta (key, value) VALUES ($1, $2)
           ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
        ['schema_version', SCHEMA_VERSION]
      );
      if (homeLabel !== undefined && homeLabel !== null) {
        await conn.query(
          `INSERT INTO schema_meta (key, value) VALUES ($1, $2)
             ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
          ['home_label', String(homeLabel)]
        );
      }
      return { homeUuid, schemaVersion: SCHEMA_VERSION };
    });
  }

  // Locked read of the seeded identity (home_uuid, schema_version, home_label).
  async schemaMeta() {
    return runExclusive(this, async (conn) => {
      const r = await conn.query('SELECT key, value FROM schema_meta');
      return Object.fromEntries(r.rows.map((row) => [row.key, row.value]));
    });
  }

  // Locked read of the coordinator revision counters.
  async coordinatorState() {
    return runExclusive(this, async (conn) => {
      const r = await conn.query(
        'SELECT domain_revision, projection_revision, commit_sequence FROM coordinator_state WHERE id = 1'
      );
      const row = r.rows[0];
      if (!row) return null;
      return {
        domainRevision: Number(row.domain_revision),
        projectionRevision: Number(row.projection_revision),
        commitSequence: Number(row.commit_sequence)
      };
    });
  }

  // Locked read of the public table names present (a read-only projection, not a
  // mutation surface). Used to assert "no domain tables" and by the contract.
  async tableNames() {
    return runExclusive(this, async (conn) => {
      const r = await conn.query(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name"
      );
      return r.rows.map((row) => row.table_name);
    });
  }

  // S0 seam contract probe (core tables only). Bumps commit_sequence inside a
  // transaction and reads it back, proving exclusive access, an explicit
  // transaction that commits, and a locked read - identically on every adapter,
  // without any domain table. Also the serialized-write used to prove the lock
  // serializes concurrent writers.
  async contractProbe() {
    return runExclusive(this, async (conn) => {
      const before = await conn.query('SELECT commit_sequence FROM coordinator_state WHERE id = 1');
      await conn.query('UPDATE coordinator_state SET commit_sequence = commit_sequence + 1 WHERE id = 1');
      const after = await conn.query('SELECT commit_sequence FROM coordinator_state WHERE id = 1');
      return {
        before: Number(before.rows[0].commit_sequence),
        after: Number(after.rows[0].commit_sequence)
      };
    });
  }
}
