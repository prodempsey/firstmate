import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { runExclusive } from './internal-runtime.mjs';
import { ValidationError } from './errors.mjs';
import { IdempotencyConflictError, CausalOrderingError, StateTransitionError } from './errors-s1.mjs';

// S1 domain layer: tasks, runs, task_events, producer high-water, command
// idempotency, and base anomalies (spec-amend-s4 section 12, S1 row).
//
// These are standalone functions that take a store and reach the exclusive
// transaction ONLY through the sanctioned in-package seam
// (`runExclusive(store, cb)`; internal-runtime.mjs). They never touch the S0
// files: the S0 base class, its store, and its errors module stay byte-identical.
// Every DB access is one BEGIN/COMMIT per lock acquisition; a command's domain
// write, its task/counter revision bumps, and its command_results row all commit
// in that SAME transaction, so a crash before the bookkeeping leaves no orphan
// domain row (t_recovers_when_writer_exits_before_revision_bump).

const SQL_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'sql');
const DOMAIN_SCHEMA_S1 = fs.readFileSync(path.join(SQL_DIR, 'domain-schema-s1.sql'), 'utf8');

// Distinct from S0's schema_version (which init() rewrites on every run). Marks
// that the S1 domain schema has been applied to this store (ruling Q7).
const DOMAIN_SCHEMA_KEY = 'domain_schema_version';
const DOMAIN_SCHEMA_VERSION = 's1';

// How long after begin-run a launch may still be committed (S3 owns real launch;
// S1 only precommits the deadline).
const LAUNCH_WINDOW_MS = 120000;

const TASK_KINDS = new Set(['ship', 'scout', 'secondmate']);
const TASK_ORIGINS = new Set(['captain_order', 'internal']);
const PRODUCERS = new Set(['coordinator', 'adapter', 'crewmate', 'firstmate', 'reconciler']);

// All event types the DDL permits.
const ALL_EVENT_TYPES = new Set([
  'created', 'cancelled', 'spawn_intent', 'spawned', 'running_verified', 'progress',
  'blocked', 'unblocked', 'waiting_firstmate', 'needs_human', 'rework', 'identity_lost',
  'completed', 'failed', 'cleanup_started', 'cleaned', 'archived', 'anomaly'
]);

// Event types a caller MAY append through generic `event` (spec section 3.1). All
// others are terminal (completed/failed), lifecycle-owned (spawn_intent, spawned,
// running_verified, cleanup_started, cleaned, archived, cancelled), or
// coordinator/reconciler-generated (created, anomaly, identity_lost) and must use
// their owning wrapper.
const CALLER_APPENDABLE = new Set([
  'progress', 'blocked', 'unblocked', 'waiting_firstmate', 'needs_human', 'rework'
]);

// Status-changing generic events and their legal (from -> to) task transitions
// (spec section 4). `progress` changes no status and is omitted. In pure S1 the
// task never reaches a running/blocked/waiting_firstmate/needs_human state
// (commit-running is S3), so these positive paths are unreachable here and the
// events reject with StateTransitionError; their mechanics are still encoded so a
// later slice that can produce a running task inherits them (ruling Q3).
const STATUS_EVENT_TRANSITIONS = {
  blocked: [{ from: 'running', to: 'blocked' }],
  unblocked: [{ from: 'blocked', to: 'running' }, { from: 'needs_human', to: 'running' }],
  waiting_firstmate: [{ from: 'running', to: 'waiting_firstmate' }, { from: 'needs_human', to: 'waiting_firstmate' }],
  rework: [{ from: 'waiting_firstmate', to: 'running' }],
  needs_human: [
    { from: 'running', to: 'needs_human' },
    { from: 'blocked', to: 'needs_human' },
    { from: 'waiting_firstmate', to: 'needs_human' }
  ]
};

// Task states begin-run may start a generation from (spec section 4). Non-queued
// starts additionally require the prior generation to be closed; in pure S1 no run
// is ever closed (complete/fail are S2), so only queued -> spawning is reachable.
const BEGIN_RUN_FROM = new Set(['queued', 'failed', 'blocked', 'needs_human']);

function nowIso() {
  return new Date().toISOString();
}

export function sha256hex(input) {
  return crypto.createHash('sha256').update(input).digest('hex');
}

// Authoritative launch-marker derivation (spec section 5):
//   launch_marker = sha256(home_uuid || task_id || generation || bind_nonce)
export function launchMarkerFor(homeUuid, taskId, generation, bindNonce) {
  return sha256hex(`${homeUuid}${taskId}${generation}${bindNonce}`);
}

// Deterministic JSON (recursively key-sorted) for request/payload hashing.
export function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
}

// jsonb columns come back parsed on most drivers; tolerate a text form too.
export function coerceJson(value) {
  return typeof value === 'string' ? JSON.parse(value) : value;
}

// Fingerprint over the spec's positional inputs (spec section 10). For the S1
// command-conflict classes the identity fields are null, so the offending command
// key is carried in terminal_fingerprint to keep distinct conflicts distinct while
// coalescing an identical retried conflict.
function anomalyFingerprint(f) {
  const parts = [
    f.homeUuid, f.anomalyClass, f.taskId, f.runGeneration, f.endpointId,
    f.paneId, f.agentPid, f.agentStartTicks, f.terminalFingerprint
  ];
  // Spec-amend-s4 lines 819-825 fingerprint formula: direct field concatenation with NO
  // delimiter, the same convention launchMarkerFor uses (spec section 5); a null/undefined
  // field contributes the empty string. (S5 QA qa-s5-q64 finding 7: the earlier
  // NUL-delimited join diverged from the ratified formula. Corrected so every slice -
  // S1/S2/S3/S5 - fingerprints identically and S5's cleanup-mismatch coalesces onto S3's
  // identity_mismatch row. No existing test pinned a digest; test/s5-contract.test.mjs now
  // pins a fixed vector.)
  return sha256hex(parts.map((p) => (p === null || p === undefined ? '' : String(p))).join(''));
}

export async function ensureInitialized(conn) {
  const r = await conn.query(
    "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'coordinator_state'"
  );
  if (r.rows.length === 0) {
    throw new ValidationError('control-plane store is not initialized (run `cp init` first)');
  }
}

// Apply the S1 domain schema idempotently at the start of a domain transaction
// (ruling Q7). Every object is IF NOT EXISTS, so this is a no-op after the first
// domain command. Deliberately does NOT run during `cp init`, so init still
// creates exactly the two S0 core tables and nothing else.
async function applyDomainSchema(conn) {
  await conn.exec(DOMAIN_SCHEMA_S1);
  await conn.query(
    `INSERT INTO schema_meta (key, value) VALUES ($1, $2)
       ON CONFLICT (key) DO NOTHING`,
    [DOMAIN_SCHEMA_KEY, DOMAIN_SCHEMA_VERSION]
  );
}

export async function readHomeUuid(conn) {
  const r = await conn.query("SELECT value FROM schema_meta WHERE key = 'home_uuid'");
  if (r.rows.length === 0) {
    throw new ValidationError('control-plane store is not initialized (home_uuid missing)');
  }
  return r.rows[0].value;
}

export async function readTask(conn, taskId) {
  const r = await conn.query(
    'SELECT task_id, status, revision, current_generation FROM tasks WHERE task_id = $1',
    [taskId]
  );
  return r.rows[0] || null;
}

export async function insertEvent(conn, e) {
  const eventId = crypto.randomUUID();
  const payload = e.payload ?? {};
  await conn.query(
    `INSERT INTO task_events
       (event_id, task_id, event_scope, run_generation, producer_id, producer_seq,
        event_type, generation_key, is_terminal, outcome, payload_json, payload_hash, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12,$13)`,
    [
      eventId, e.taskId, e.eventScope, e.runGeneration, e.producer, e.producerSeq,
      e.eventType, e.generationKey, e.isTerminal, e.outcome,
      JSON.stringify(payload), sha256hex(canonicalJson(payload)), e.now
    ]
  );
  return eventId;
}

export async function upsertHighwater(conn, h) {
  await conn.query(
    `INSERT INTO producer_highwater (task_id, run_generation, producer_id, last_seq, last_command_id, updated_at)
       VALUES ($1,$2,$3,$4,$5,$6)
       ON CONFLICT (task_id, run_generation, producer_id) DO UPDATE SET
         last_seq = EXCLUDED.last_seq,
         last_command_id = EXCLUDED.last_command_id,
         updated_at = EXCLUDED.updated_at`,
    [h.taskId, h.runGeneration, h.producer, h.seq, h.commandId ?? null, h.now]
  );
}

// Insert-or-coalesce an anomaly (spec section 6.2/10). Reobserving a fingerprint
// increments occurrence_count and last_seen_at; historical rows are never deleted.
export async function recordAnomaly(conn, a, now) {
  const fingerprint = anomalyFingerprint({
    homeUuid: a.homeUuid,
    anomalyClass: a.anomalyClass,
    taskId: a.taskId ?? null,
    runGeneration: a.runGeneration ?? null,
    endpointId: a.endpointId ?? null,
    paneId: a.paneId ?? null,
    agentPid: a.agentPid ?? null,
    agentStartTicks: a.agentStartTicks ?? null,
    terminalFingerprint: a.terminalFingerprint ?? null
  });
  await conn.query(
    `INSERT INTO anomalies
       (fingerprint, anomaly_class, home_uuid, task_id, run_generation, endpoint_id, pane_id,
        agent_pid, agent_start_ticks, terminal_fingerprint, status, occurrence_count,
        first_seen_at, last_seen_at, detail_json)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'active',1,$11,$11,$12::jsonb)
       ON CONFLICT (fingerprint) DO UPDATE SET
         occurrence_count = anomalies.occurrence_count + 1,
         last_seen_at = EXCLUDED.last_seen_at,
         detail_json = EXCLUDED.detail_json`,
    [
      fingerprint, a.anomalyClass, a.homeUuid, a.taskId ?? null, a.runGeneration ?? null,
      a.endpointId ?? null, a.paneId ?? null, a.agentPid ?? null, a.agentStartTicks ?? null,
      a.terminalFingerprint ?? null, now, JSON.stringify(a.detail ?? {})
    ]
  );
  return fingerprint;
}

// Internal control-flow signal for an auditable command conflict (idempotency or
// causal). A `mutate` raises it AFTER attempting whatever domain writes it needs;
// executeCommand rolls the mutation back to the savepoint, persists the anomaly,
// and advances the audit counters. It never escapes this module.
export class ConflictSignal extends Error {
  constructor(kind, anomaly) {
    super(`command conflict: ${kind}`);
    this.kind = kind; // 'idempotency' | 'causal' | (S2) 'terminal'
    this.anomaly = anomaly;
  }
}

// Conflict kind -> typed error, as data. S1's own two classes are the DEFAULT, so
// every existing S1 call site (which passes no conflictErrors) resolves exactly the
// pair it resolved before this map existed and its runtime behavior is unchanged.
// A later slice that owns a new conflict kind supplies only its own entry and
// inherits these two (S2 passes { terminal: ... } for TerminalConflictError). This
// is the ONLY generalization made to the S1 envelope for S2 reuse; see the
// executeCommand `conflictErrors` param (ORD-228 ruling RISK#1).
const DEFAULT_CONFLICT_ERRORS = Object.freeze({
  idempotency: (detail) =>
    new IdempotencyConflictError('command-id reused with a different request payload', detail),
  causal: (detail) =>
    new CausalOrderingError('mutation rejected on a stale causal token', detail)
});

// An anomaly audit is itself a canonical domain change: a committed write that
// advances domain_revision and commit_sequence exactly once, without touching the
// task revision or projection_revision (spec section 2.3; QA-s1-q49 finding 1).
export async function bumpAuditCounters(conn) {
  await conn.query(
    'UPDATE coordinator_state SET domain_revision = domain_revision + 1, commit_sequence = commit_sequence + 1 WHERE id = 1'
  );
}

// Shared executor for every mutating S1 command. Enforces: command-id required;
// idempotent replay by command_id + request_hash; conflict audit through a
// SAVEPOINT that rolls back the rejected mutation while its anomaly survives to
// COMMIT (ruling Q2); the audit counter contract above; and the atomic bundle of
// domain write + counter bumps + command_results in one transaction. `mutate`
// returns { result, committedRevision, domainChanged } on success and raises a
// ConflictSignal for an auditable conflict; a StateTransitionError/ValidationError
// is a non-audited rejection that abandons the whole transaction, persisting
// nothing.
export async function executeCommand(store, {
  verb, commandId, requestHash, taskId = null, now, mutate, fault, conflictErrors = {}
}) {
  if (typeof commandId !== 'string' || commandId.length === 0) {
    throw new ValidationError('--command-id is required for every mutating command', { verb });
  }
  const outcome = await runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    await applyDomainSchema(conn);
    const homeUuid = await readHomeUuid(conn);

    // Idempotency pre-check: a stored result for this command_id is either a clean
    // replay (same request) or an idempotency conflict (different request). A replay
    // is neither a write nor an audit, so it advances no counter; a conflict is an
    // audited domain write.
    const prior = await conn.query(
      'SELECT verb, request_hash, result_json FROM command_results WHERE command_id = $1',
      [commandId]
    );
    if (prior.rows.length > 0) {
      const row = prior.rows[0];
      if (row.request_hash === requestHash) {
        return { status: 'replay', result: coerceJson(row.result_json) };
      }
      const detail = {
        command_id: commandId, verb, stored_verb: row.verb,
        stored_request_hash: row.request_hash, incoming_request_hash: requestHash
      };
      await recordAnomaly(conn, {
        anomalyClass: 'idempotency_conflict', homeUuid, taskId, terminalFingerprint: commandId, detail
      }, now);
      await bumpAuditCounters(conn);
      return { status: 'conflict', kind: 'idempotency', detail };
    }

    // Attempt the domain mutation under a savepoint. An auditable ConflictSignal is
    // caught here: the savepoint is rolled back (discarding any partial domain
    // write the mutation made before detecting the conflict), then the anomaly is
    // persisted and the audit counters advance, all inside the same outer
    // transaction. Any other throw (a non-audited StateTransition/Validation
    // rejection, or a genuine error) escapes the callback so the S0 primitive rolls
    // the whole transaction back, persisting nothing.
    await conn.query('SAVEPOINT cp_cmd');
    let m;
    try {
      m = await mutate(conn, { now, commandId, homeUuid });
    } catch (err) {
      await conn.query('ROLLBACK TO SAVEPOINT cp_cmd');
      if (!(err instanceof ConflictSignal)) throw err;
      await recordAnomaly(conn, { homeUuid, ...err.anomaly }, now);
      await bumpAuditCounters(conn);
      return { status: 'conflict', kind: err.kind, detail: err.anomaly.detail };
    }
    await conn.query('RELEASE SAVEPOINT cp_cmd');

    // Test-only crash injection: a writer that exits here has already written the
    // domain rows but not the counter bump or command_results. Throwing (or a real
    // process exit) rolls the whole transaction back, proving the atomic bundle
    // (t_recovers_when_writer_exits_before_revision_bump).
    if (typeof fault === 'function') fault();

    await conn.query(
      `UPDATE coordinator_state
         SET commit_sequence = commit_sequence + 1${m.domainChanged ? ', domain_revision = domain_revision + 1' : ''}
         WHERE id = 1`
    );
    await conn.query(
      `INSERT INTO command_results (command_id, verb, request_hash, result_json, committed_revision, created_at)
         VALUES ($1,$2,$3,$4::jsonb,$5,$6)`,
      [commandId, verb, requestHash, JSON.stringify(m.result), m.committedRevision ?? null, now]
    );
    return { status: 'ok', result: m.result };
  });

  if (outcome.status === 'conflict') {
    // Caller-supplied entries override/extend the S1 defaults; a caller that
    // supplies none (every S1 verb) resolves the identical pair as before.
    const make = { ...DEFAULT_CONFLICT_ERRORS, ...conflictErrors }[outcome.kind];
    if (!make) {
      // An audited conflict kind with no typed error is a programming error. Fail
      // loudly rather than degrading to a generic throw that a caller would then
      // have to classify by string.
      throw new Error(
        `no typed error registered for conflict kind '${outcome.kind}' (verb ${verb})`
      );
    }
    throw make(outcome.detail);
  }
  return outcome.result;
}

export function validateCreateTaskParams(p) {
  if (!p.taskId) throw new ValidationError('create-task requires a <task_id>');
  if (!TASK_KINDS.has(p.kind)) {
    throw new ValidationError(`--kind must be one of ${[...TASK_KINDS].join(', ')}`, { kind: p.kind ?? null });
  }
  if (!p.title) throw new ValidationError('create-task requires --title');
  if (!TASK_ORIGINS.has(p.origin)) {
    throw new ValidationError(`--origin must be one of ${[...TASK_ORIGINS].join(', ')}`, { origin: p.origin ?? null });
  }
  if (p.origin === 'captain_order') {
    if (!p.orderRef) throw new ValidationError('captain_order origin requires --order-ref');
    if (p.internalReason) throw new ValidationError('captain_order origin must not set --internal-reason');
  } else {
    if (!p.internalReason) throw new ValidationError('internal origin requires --internal-reason');
    if (p.orderRef) throw new ValidationError('internal origin must not set --order-ref');
  }
}

// create-task: none -> queued. No --expected-revision (it is a creation). Inserts
// the task at revision 1 and the task-scope `created` event (ruling Q6).
export async function createTask(store, params, { now = nowIso(), fault } = {}) {
  validateCreateTaskParams(params);
  const requestHash = sha256hex(canonicalJson({
    verb: 'create-task', task_id: params.taskId, kind: params.kind, title: params.title,
    repo: params.repo ?? null, origin: params.origin,
    order_ref: params.orderRef ?? null, internal_reason: params.internalReason ?? null
  }));
  return executeCommand(store, {
    verb: 'create-task', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    mutate: async (conn, ctx) => {
      const existing = await conn.query('SELECT task_id FROM tasks WHERE task_id = $1', [params.taskId]);
      if (existing.rows.length > 0) {
        throw new StateTransitionError(`task already exists: ${params.taskId}`, { task_id: params.taskId });
      }
      await conn.query(
        `INSERT INTO tasks
           (task_id, home_uuid, kind, title, repo, task_origin, order_ref, internal_reason,
            status, revision, current_generation, created_at, updated_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'queued',1,0,$9,$9)`,
        [
          params.taskId, ctx.homeUuid, params.kind, params.title, params.repo ?? null,
          params.origin, params.orderRef ?? null, params.internalReason ?? null, ctx.now
        ]
      );
      await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'task', runGeneration: null, generationKey: -1,
        producer: 'coordinator', producerSeq: 1, eventType: 'created', isTerminal: false,
        outcome: null, payload: {}, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: -1, producer: 'coordinator', seq: 1,
        commandId: ctx.commandId, now: ctx.now
      });
      return {
        result: { task_id: params.taskId, status: 'queued', revision: 1, generation: 0 },
        committedRevision: 1, domainChanged: true
      };
    }
  });
}

// begin-run: {queued|failed|blocked|needs_human} -> spawning. CAS on task
// revision; allocate generation N, nonce, launch marker/dir/registration path;
// insert the run (spawning/open-not-closed) and the run-scope `spawn_intent`.
export async function beginRun(store, params, { now = nowIso(), fault } = {}) {
  if (!params.taskId) throw new ValidationError('begin-run requires a <task_id>');
  if (!Number.isInteger(params.expectedRevision)) {
    throw new ValidationError('begin-run requires an integer --expected-revision');
  }
  const requestHash = sha256hex(canonicalJson({
    verb: 'begin-run', task_id: params.taskId, expected_revision: params.expectedRevision,
    backend: params.backend ?? null, launch_dir: params.launchDir ?? null,
    registration_path: params.registrationPath ?? null
  }));
  return executeCommand(store, {
    verb: 'begin-run', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      // CAS on the causal token takes precedence over the state guard, so a writer
      // acting on a stale revision is a causal conflict, not a state-transition
      // error (ruling Q4).
      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId, terminalFingerprint: ctx.commandId,
          detail: {
            command_id: ctx.commandId, verb: 'begin-run', reason: 'stale_revision',
            expected_revision: params.expectedRevision, actual_revision: Number(task.revision)
          }
        });
      }
      if (!BEGIN_RUN_FROM.has(task.status)) {
        throw new StateTransitionError(`begin-run not allowed from status '${task.status}'`, {
          task_id: params.taskId, status: task.status
        });
      }
      const currentGen = Number(task.current_generation);
      if (currentGen > 0) {
        const prior = await conn.query(
          'SELECT closed_at FROM runs WHERE task_id = $1 AND run_generation = $2',
          [params.taskId, currentGen]
        );
        if (prior.rows.length > 0 && prior.rows[0].closed_at === null) {
          throw new StateTransitionError('prior generation is still open; close it before respawn', {
            task_id: params.taskId, generation: currentGen
          });
        }
      }
      const generation = currentGen + 1;
      const bindNonce = crypto.randomBytes(24).toString('hex');
      // Authoritative launch-marker derivation (spec section 5): the marker binds
      // the precommitted home/task/generation/nonce identity, so S3 can expose it
      // from the first observable launch instant. NOT a random id (QA-s1-q49
      // finding 4).
      const launchMarker = launchMarkerFor(ctx.homeUuid, params.taskId, generation, bindNonce);
      const launchDir = params.launchDir ?? '';
      const registrationPath = params.registrationPath ?? `${launchMarker}.reg`;
      const backend = params.backend ?? 'tmux';
      const launchDeadlineAt = new Date(new Date(ctx.now).getTime() + LAUNCH_WINDOW_MS).toISOString();
      await conn.query(
        `INSERT INTO runs
           (task_id, run_generation, status, binding_state, backend, bind_nonce, launch_marker,
            launch_dir, registration_path, launch_deadline_at, cleanup_state, created_at)
           VALUES ($1,$2,'spawning','spawning',$3,$4,$5,$6,$7,$8,'not_started',$9)`,
        [params.taskId, generation, backend, bindNonce, launchMarker, launchDir, registrationPath, launchDeadlineAt, ctx.now]
      );
      await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: generation, generationKey: generation,
        producer: 'coordinator', producerSeq: 1, eventType: 'spawn_intent', isTerminal: false,
        outcome: null, payload: { launch_marker: launchMarker }, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: generation, producer: 'coordinator', seq: 1,
        commandId: ctx.commandId, now: ctx.now
      });
      const newRevision = Number(task.revision) + 1;
      await conn.query(
        'UPDATE tasks SET status = $1, revision = $2, current_generation = $3, updated_at = $4 WHERE task_id = $5',
        ['spawning', newRevision, generation, ctx.now, params.taskId]
      );
      return {
        result: {
          task_id: params.taskId, generation, status: 'spawning', revision: newRevision,
          bind_nonce: bindNonce, launch_marker: launchMarker, launch_dir: launchDir,
          registration_path: registrationPath, launch_deadline_at: launchDeadlineAt
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// event (generic, nonterminal): append a caller-allowed run-scope event to an
// open generation. `progress` changes no status and is allowed on any open
// generation regardless of workflow status (ruling Q3). Terminal and
// lifecycle-owned types are rejected; delivery is store-owned (no --deliver).
export async function appendEvent(store, params, { now = nowIso(), fault } = {}) {
  if (!params.taskId) throw new ValidationError('event requires a <task_id>');
  if (!ALL_EVENT_TYPES.has(params.eventType)) {
    throw new ValidationError(`unknown event type: ${params.eventType ?? null}`, { event_type: params.eventType ?? null });
  }
  if (!CALLER_APPENDABLE.has(params.eventType)) {
    throw new StateTransitionError(
      `event type '${params.eventType}' is not appendable through generic 'event'; it is terminal or lifecycle-owned and must use its owning wrapper`,
      { event_type: params.eventType }
    );
  }
  if (!PRODUCERS.has(params.producer)) {
    throw new ValidationError(`--producer must be one of ${[...PRODUCERS].join(', ')}`, { producer: params.producer ?? null });
  }
  if (!Number.isInteger(params.generation) || params.generation < 1) {
    throw new ValidationError('event requires an integer --generation >= 1');
  }
  if (!Number.isInteger(params.seq) || params.seq < 1) {
    throw new ValidationError('event requires an integer --seq >= 1');
  }
  if (!Number.isInteger(params.expectedRevision)) {
    throw new ValidationError('event requires an integer --expected-revision');
  }
  const payload = params.payload ?? {};
  // expected_revision is part of the request identity: a replay that changes the
  // causal token it acted on is a different request, not an idempotent replay
  // (QA-s1-q49 finding 2; matches beginRun).
  const requestHash = sha256hex(canonicalJson({
    verb: 'event', task_id: params.taskId, generation: params.generation, type: params.eventType,
    producer: params.producer, seq: params.seq, expected_revision: params.expectedRevision, payload
  }));
  return executeCommand(store, {
    verb: 'event', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const run = await conn.query(
        'SELECT closed_at FROM runs WHERE task_id = $1 AND run_generation = $2',
        [params.taskId, params.generation]
      );
      if (run.rows.length === 0) {
        throw new StateTransitionError(`no such run generation ${params.generation} for task ${params.taskId}`, {
          task_id: params.taskId, generation: params.generation
        });
      }
      if (run.rows[0].closed_at !== null) {
        throw new StateTransitionError(`run generation ${params.generation} is closed; cannot append`, {
          task_id: params.taskId, generation: params.generation
        });
      }
      // Producer sequence must strictly advance (ruling Q5: reject seq <= last_seq;
      // gaps tolerated).
      const hw = await conn.query(
        'SELECT last_seq FROM producer_highwater WHERE task_id = $1 AND run_generation = $2 AND producer_id = $3',
        [params.taskId, params.generation, params.producer]
      );
      const lastSeq = hw.rows.length > 0 ? Number(hw.rows[0].last_seq) : 0;
      if (params.seq <= lastSeq) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId, runGeneration: params.generation,
          terminalFingerprint: `${params.producer}:${params.seq}`,
          detail: {
            command_id: ctx.commandId, verb: 'event', reason: 'nonmonotonic_producer_seq',
            producer: params.producer, seq: params.seq, last_seq: lastSeq
          }
        });
      }
      let newStatus = task.status;
      if (params.eventType !== 'progress') {
        const match = (STATUS_EVENT_TRANSITIONS[params.eventType] || []).find((t) => t.from === task.status);
        if (!match) {
          throw new StateTransitionError(
            `event '${params.eventType}' is not a legal transition from status '${task.status}'`,
            { event_type: params.eventType, status: task.status }
          );
        }
        newStatus = match.to;
      }
      // Write the event and advance the producer high-water, THEN commit the task
      // revision under a compare-and-set on the expected token. If the CAS matches
      // no row, the token was stale: raising ConflictSignal here rolls the savepoint
      // back, discarding the event row and high-water bump just written, while the
      // anomaly persists in the outer transaction (QA-s1-q49 finding 5.3 - this is
      // the directly-exercised SAVEPOINT rollback path).
      const eventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation, generationKey: params.generation,
        producer: params.producer, producerSeq: params.seq, eventType: params.eventType, isTerminal: false,
        outcome: null, payload, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: params.producer, seq: params.seq,
        commandId: ctx.commandId, now: ctx.now
      });
      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        'UPDATE tasks SET status = $1, revision = $2, updated_at = $3 WHERE task_id = $4 AND revision = $5 RETURNING revision',
        [newStatus, newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId, runGeneration: params.generation,
          terminalFingerprint: ctx.commandId,
          detail: {
            command_id: ctx.commandId, verb: 'event', reason: 'stale_revision',
            expected_revision: params.expectedRevision, actual_revision: Number(task.revision)
          }
        });
      }
      return {
        result: {
          task_id: params.taskId, generation: params.generation, event_id: eventId,
          event_type: params.eventType, status: newStatus, revision: newRevision
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// task-head: locked read of a task's status, current generation, task revision,
// and the coordinator's domain revision. Pure read - no schema creation, no
// command-id, no counter bump.
export async function taskHead(store, { taskId }) {
  if (!taskId) throw new ValidationError('task-head requires a <task_id>');
  return runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    const present = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'tasks'"
    );
    if (present.rows.length === 0) {
      throw new ValidationError(`task not found: ${taskId}`, { task_id: taskId });
    }
    const t = await conn.query(
      'SELECT status, current_generation, revision FROM tasks WHERE task_id = $1',
      [taskId]
    );
    if (t.rows.length === 0) {
      throw new ValidationError(`task not found: ${taskId}`, { task_id: taskId });
    }
    const cs = await conn.query('SELECT domain_revision FROM coordinator_state WHERE id = 1');
    const row = t.rows[0];
    return {
      task_id: taskId,
      status: row.status,
      current_generation: Number(row.current_generation),
      revision: Number(row.revision),
      domain_revision: Number(cs.rows[0].domain_revision)
    };
  });
}
