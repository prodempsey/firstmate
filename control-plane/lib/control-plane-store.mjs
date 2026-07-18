import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { ValidationError, ConstraintError } from './errors.mjs';
import { payloadHash } from './hash.mjs';

const SQL_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'sql');
const CORE_SCHEMA = fs.readFileSync(path.join(SQL_DIR, 'core-schema.sql'), 'utf8');
const DOMAIN_SCHEMA = fs.readFileSync(path.join(SQL_DIR, 'domain-schema.sql'), 'utf8');

const SCHEMA_VERSION = 's0';

// Engine-neutral control-plane store.
//
// This base owns the domain logic (schema application, seeding, create-task,
// task-head, and the S0 seam contract probe). All of it is expressed through the
// single seam primitive `runExclusive(fn)`, which each adapter implements with its
// own exclusivity mechanism: PgliteLocalStore uses flock + a fresh single
// connection per call; PgHostedContractStore uses a real Postgres connection with
// serializable/advisory-lock semantics. Because the domain never depends on how
// exclusivity is achieved, the seam's contract is provably not tied to PGlite's
// single-connection serialization (spec section 2.1).
//
// Subclasses MUST implement:
//   async runExclusive(fn)  -> acquire exclusive access, open one connection, run
//                              `await fn(conn)` inside an explicit transaction
//                              (BEGIN/COMMIT, ROLLBACK+rethrow on error), then
//                              close the connection and release access. `conn`
//                              exposes `query(sql, params) -> { rows }`.
//   async close()           -> release any long-lived resources (may be a no-op).
export class ControlPlaneStore {
  // eslint-disable-next-line no-unused-vars
  async runExclusive(fn) {
    throw new Error('runExclusive must be implemented by a ControlPlaneStore subclass');
  }

  async close() {
    // Default: nothing long-lived to release.
  }

  // Apply only the core schema (schema_meta, coordinator_state) and seed. Used by
  // the seam contract probe so it runs "without domain tables" on any adapter
  // (spec section 12, S0 acceptance).
  async initCore({ homeLabel } = {}) {
    return this.runExclusive(async (conn) => this._applyCore(conn, { homeLabel }));
  }

  // Full production init: core + complete domain schema, seeded and idempotent
  // (spec section 6: `cp init` seeds schema and home_uuid; idempotent).
  async init({ homeLabel } = {}) {
    return this.runExclusive(async (conn) => {
      const core = await this._applyCore(conn, { homeLabel });
      await conn.exec(DOMAIN_SCHEMA);
      return { ...core, domainSchema: true };
    });
  }

  async _applyCore(conn, { homeLabel } = {}) {
    await conn.exec(CORE_SCHEMA);
    await conn.query(
      'INSERT INTO coordinator_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING'
    );
    // home_uuid is minted once and never rewritten.
    const existing = await conn.query("SELECT value FROM schema_meta WHERE key = 'home_uuid'");
    let homeUuid;
    if (existing.rows.length > 0) {
      homeUuid = existing.rows[0].value;
    } else {
      homeUuid = crypto.randomUUID();
      await conn.query('INSERT INTO schema_meta (key, value) VALUES ($1, $2)', [
        'home_uuid',
        homeUuid
      ]);
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
  }

  // Locked read of the coordinator revision counters (spec: coordinator_state).
  async coordinatorState() {
    return this.runExclusive(async (conn) => {
      const r = await conn.query(
        'SELECT domain_revision, projection_revision, commit_sequence FROM coordinator_state WHERE id = 1'
      );
      return r.rows[0] || null;
    });
  }

  // S0 seam contract probe (core tables only). Bumps commit_sequence inside a
  // transaction and reads it back, proving: exclusive access, an explicit
  // transaction that commits, and a locked read - identically on every adapter,
  // without any domain table.
  async contractProbe() {
    return this.runExclusive(async (conn) => {
      const before = await conn.query('SELECT commit_sequence FROM coordinator_state WHERE id = 1');
      await conn.query('UPDATE coordinator_state SET commit_sequence = commit_sequence + 1 WHERE id = 1');
      const after = await conn.query('SELECT commit_sequence FROM coordinator_state WHERE id = 1');
      return {
        before: Number(before.rows[0].commit_sequence),
        after: Number(after.rows[0].commit_sequence)
      };
    });
  }

  // create-task (spec section 4 "none -> queued" transition; section 6 verb).
  // Validates origin/order-ref, inserts the task and its task-scope `created`
  // event, bumps coordinator_state, and returns the resulting task revision.
  // Idempotent when `commandId` is supplied: a replay returns the stored result.
  async createTask(input) {
    const task = normalizeCreateTask(input);
    return this.runExclusive(async (conn) => {
      if (task.commandId) {
        const prior = await conn.query(
          'SELECT result_json FROM command_results WHERE command_id = $1',
          [task.commandId]
        );
        if (prior.rows.length > 0) {
          return { ...prior.rows[0].result_json, replay: true };
        }
      }

      const nowIso = new Date().toISOString();
      const revision = 1; // creation increments revision from the DEFAULT 0.

      try {
        await conn.query(
          `INSERT INTO tasks
             (task_id, home_uuid, kind, title, repo, task_origin, order_ref,
              internal_reason, status, revision, current_generation, created_at, updated_at)
           VALUES ($1, (SELECT value FROM schema_meta WHERE key='home_uuid'),
                   $2, $3, $4, $5, $6, $7, 'queued', $8, 0, $9, $9)`,
          [
            task.taskId,
            task.kind,
            task.title,
            task.repo,
            task.origin,
            task.orderRef,
            task.internalReason,
            revision,
            nowIso
          ]
        );
      } catch (error) {
        if (isUniqueViolation(error)) {
          throw new ConstraintError(`task already exists: ${task.taskId}`, { taskId: task.taskId });
        }
        throw error;
      }

      // Task-scope `created` event: run_generation NULL, generation_key -1.
      const payload = {
        kind: task.kind,
        title: task.title,
        repo: task.repo,
        origin: task.origin,
        order_ref: task.orderRef,
        internal_reason: task.internalReason
      };
      const eventId = crypto.randomUUID();
      await conn.query(
        `INSERT INTO task_events
           (event_id, task_id, event_scope, run_generation, producer_id, producer_seq,
            event_type, generation_key, is_terminal, outcome, payload_json, payload_hash, created_at)
         VALUES ($1, $2, 'task', NULL, 'coordinator', 1, 'created', -1, false, NULL,
                 $3::jsonb, $4, $5)`,
        [eventId, task.taskId, JSON.stringify(payload), payloadHash(payload), nowIso]
      );

      // Canonical domain change: bump domain_revision and commit_sequence.
      await conn.query(
        `UPDATE coordinator_state
           SET domain_revision = domain_revision + 1,
               commit_sequence = commit_sequence + 1
         WHERE id = 1`
      );

      const result = { taskId: task.taskId, revision, eventId };
      if (task.commandId) {
        await conn.query(
          `INSERT INTO command_results (command_id, verb, request_hash, result_json, committed_revision, created_at)
           VALUES ($1, 'create-task', $2, $3::jsonb, $4, $5)`,
          [task.commandId, task.requestHash, JSON.stringify(result), revision, nowIso]
        );
      }
      return result;
    });
  }

  // task-head (spec section 6): locked read of status, current generation, task
  // revision, and domain revision.
  async taskHead(taskId) {
    if (!taskId) throw new ValidationError('task-head requires a task_id');
    return this.runExclusive(async (conn) => {
      const t = await conn.query(
        'SELECT status, current_generation, revision FROM tasks WHERE task_id = $1',
        [taskId]
      );
      if (t.rows.length === 0) return null;
      const cs = await conn.query('SELECT domain_revision FROM coordinator_state WHERE id = 1');
      return {
        taskId,
        status: t.rows[0].status,
        currentGeneration: Number(t.rows[0].current_generation),
        revision: Number(t.rows[0].revision),
        domainRevision: Number(cs.rows[0].domain_revision)
      };
    });
  }
}

function isUniqueViolation(error) {
  // Postgres/PGlite unique-violation SQLSTATE.
  return error && (error.code === '23505' || /duplicate key value/.test(error.message || ''));
}

const KINDS = new Set(['ship', 'scout', 'secondmate']);

// Validate and normalize create-task input, enforcing the origin/order-ref rule
// (locked decision: origin required; order_ref may be null only for `internal`
// tasks, which then require an internal_reason - matches the DDL origin_link
// CHECK). Rejecting here gives a typed ValidationError before the DB round-trip.
export function normalizeCreateTask(input) {
  const taskId = requireString(input.taskId, 'task_id');
  const kind = requireString(input.kind, 'kind');
  if (!KINDS.has(kind)) {
    throw new ValidationError(`invalid kind: ${kind}`, { allowed: [...KINDS] });
  }
  const title = requireString(input.title, 'title');
  const origin = requireString(input.origin, 'origin');
  if (origin !== 'captain_order' && origin !== 'internal') {
    throw new ValidationError(`invalid origin: ${origin}`, { allowed: ['captain_order', 'internal'] });
  }
  const repo = input.repo ?? null;
  let orderRef = input.orderRef ?? null;
  let internalReason = input.internalReason ?? null;

  if (origin === 'captain_order') {
    if (!orderRef) {
      throw new ValidationError('captain_order tasks require --order-ref');
    }
    if (internalReason) {
      throw new ValidationError('captain_order tasks must not carry --internal-reason');
    }
    internalReason = null;
  } else {
    // internal
    if (!internalReason) {
      throw new ValidationError('internal tasks require --internal-reason (provenance)');
    }
    if (orderRef) {
      throw new ValidationError('internal tasks must not carry --order-ref');
    }
    orderRef = null;
  }

  const normalized = {
    taskId,
    kind,
    title,
    repo,
    origin,
    orderRef,
    internalReason,
    commandId: input.commandId ?? null
  };
  normalized.requestHash = payloadHash({
    verb: 'create-task',
    taskId,
    kind,
    title,
    repo,
    origin,
    orderRef,
    internalReason
  });
  return normalized;
}

function requireString(value, name) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new ValidationError(`${name} is required`);
  }
  return value;
}
