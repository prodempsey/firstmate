import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ValidationError } from './errors.mjs';
import { StateTransitionError } from './errors-s1.mjs';
import { TerminalConflictError } from './errors-s2.mjs';
import { isDeliverable } from './delivery-policy.mjs';
import {
  executeCommand, ConflictSignal, insertEvent, upsertHighwater,
  canonicalJson, sha256hex, readTask
} from './domain-store.mjs';

// S2 domain layer: the outbox, the terminal verbs (complete/fail), and queued
// cancellation (spec-amend-s4 section 12, S2 row).
//
// This module adds NO new access path to the database. It reuses S1's command
// envelope (executeCommand) exactly as S1 uses it, which means it inherits, rather
// than reimplements: the required command-id, idempotent replay by
// command_id + request_hash, the SAVEPOINT-guarded conflict audit, the audit
// counter contract, and the atomic bundle of domain write + counter bumps +
// command_results in ONE transaction. The only generalization made to that envelope
// for S2 is the defaulted `conflictErrors` map, which lets S2 register its own
// terminal class without touching S1's behavior (ruling RISK#1).
//
// THE HEART OF S2 IS ATOMICITY. A terminal outcome is not three writes that usually
// land together: the terminal task_events row, the runs closure, and the outbox row
// are one indivisible commit. There is no window in which a run is closed but its
// delivery is missing, and none in which an outbox row names a terminal that did not
// commit. A writer that dies anywhere in the middle leaves the generation exactly as
// open as it was before.

const SQL_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'sql');
const DOMAIN_SCHEMA_S2 = fs.readFileSync(path.join(SQL_DIR, 'domain-schema-s2.sql'), 'utf8');

const DOMAIN_SCHEMA_S2_KEY = 'domain_schema_s2';
const DOMAIN_SCHEMA_S2_VERSION = 's2';

// S2 registers ONLY its own conflict class; idempotency/causal are inherited from
// the envelope's defaults, so their messages and types stay S1's.
const S2_CONFLICT_ERRORS = {
  terminal: (detail) =>
    new TerminalConflictError('generation already has a terminal outcome', detail)
};

// Task states each terminal verb may commit from (spec section 4 transition table).
// `fail` additionally accepts `spawning` as the partial-launch path; `complete` does
// not, because a generation that never reached running has nothing to have completed.
const COMPLETE_FROM = new Set(['running', 'waiting_firstmate']);
const FAIL_FROM = new Set(['spawning', 'running', 'blocked', 'waiting_firstmate', 'needs_human']);

// Allowed outcomes for `complete`: exactly 'success' (the DDL's outcome_tied CHECK
// ties a completed event to it); requiring the caller to SAY so - rather than
// defaulting it - is what makes `complete --outcome failure` a loud rejection
// instead of a silent success (qa-s2-q54 finding 2). `fail` has no outcome set at
// all: its outcome is hard-coded 'failure' (the DDL's 'superseded' failed outcome
// is reserved for internal reconciler use in a later slice, never caller-selected).
const COMPLETE_OUTCOMES = new Set(['success']);

// Mirrors the task_events.producer_id CHECK vocabulary in domain-schema-s1.sql.
// Defined locally rather than exported from S1 so the sanctioned domain-store.mjs
// diff stays exactly the ruling RISK#1 export edit.
const TERMINAL_PRODUCERS = new Set(['coordinator', 'adapter', 'crewmate', 'firstmate', 'reconciler']);

function nowIso() {
  return new Date().toISOString();
}

// Terminal provenance is caller-supplied and REQUIRED (spec section 6: complete and
// fail both take --producer/--seq). It is validated here and then stored verbatim as
// the event's provenance - never rewritten to a coordinator-derived sequence, which
// would falsify the audit trail (qa-s2-q54 finding 2).
function validateTerminalProvenance(verb, params) {
  if (!TERMINAL_PRODUCERS.has(params.producer)) {
    throw new ValidationError(
      `${verb} --producer must be one of ${[...TERMINAL_PRODUCERS].join(', ')}`,
      { producer: params.producer ?? null }
    );
  }
  if (!Number.isInteger(params.seq) || params.seq < 1) {
    throw new ValidationError(`${verb} requires an integer --seq >= 1`);
  }
}

function requireReason(verb, reason) {
  if (typeof reason !== 'string' || reason.length === 0) {
    throw new ValidationError(`${verb} requires a non-empty --reason`, { reason: reason ?? null });
  }
  return reason;
}

// Apply the S2 schema idempotently at the start of an S2 domain mutation. S2 applies
// ONLY its own file (ruling RISK#6): every verb here requires an existing task, so
// the S1 tables the outbox FKs into are guaranteed present, and there is deliberately
// no defensive cross-slice schema import.
async function applyS2Schema(conn) {
  await conn.exec(DOMAIN_SCHEMA_S2);
  await conn.query(
    `INSERT INTO schema_meta (key, value) VALUES ($1, $2)
       ON CONFLICT (key) DO NOTHING`,
    [DOMAIN_SCHEMA_S2_KEY, DOMAIN_SCHEMA_S2_VERSION]
  );
}

// The next strictly-advancing producer sequence for a producer within a generation
// namespace (run_generation = -1 is the task-scope namespace, mirroring
// ux_event_producer_seq). Used only by `cancel`, whose two events are
// coordinator-generated (spec section 6 gives cancel no --producer/--seq); the
// terminal verbs store the caller's validated provenance instead.
async function nextProducerSeq(conn, taskId, generationNamespace, producer) {
  const hw = await conn.query(
    'SELECT last_seq FROM producer_highwater WHERE task_id = $1 AND run_generation = $2 AND producer_id = $3',
    [taskId, generationNamespace, producer]
  );
  return (hw.rows.length > 0 ? Number(hw.rows[0].last_seq) : 0) + 1;
}

// Secondary within-generation delivery ordering (ruling RISK#3): MAX(task_seq)+1 per
// (task_id, generation_key). Global delivery order remains the outbox_id IDENTITY.
async function nextOutboxTaskSeq(conn, taskId, generationKey) {
  const r = await conn.query(
    'SELECT COALESCE(MAX(task_seq), 0) AS max_seq FROM outbox WHERE task_id = $1 AND generation_key = $2',
    [taskId, generationKey]
  );
  return Number(r.rows[0].max_seq) + 1;
}

// Insert the outbox row as an exact COPY of the just-written event's identifying
// 5-tuple. Never re-derives the type or hash from the caller's intent: it copies what
// actually landed in task_events, which is what fk_outbox_event_copy enforces at the
// DDL level. Delivery is decided by the store-owned policy map, never by a caller.
async function deliverEvent(conn, e) {
  if (!isDeliverable(e.eventType)) {
    throw new Error(
      `deliverEvent called for audit-only event type '${e.eventType}'; ` +
      'delivery policy is store-owned (spec section 6.1)'
    );
  }
  const taskSeq = await nextOutboxTaskSeq(conn, e.taskId, e.generationKey);
  await conn.query(
    `INSERT INTO outbox
       (event_id, task_id, run_generation, generation_key, task_seq, event_type, payload_hash, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
    [e.eventId, e.taskId, e.runGeneration, e.generationKey, taskSeq, e.eventType, e.payloadHash, e.now]
  );
  return taskSeq;
}

function isUniqueViolation(err) {
  return err && (err.code === '23505' || /duplicate key value|unique constraint/i.test(err.message || ''));
}

// Insert the terminal task_events row, remapping the ux_terminal_per_gen unique
// violation to the audited terminal-conflict signal. That index is the DDL-level
// guarantee of one terminal per generation; if it fires, a terminal already exists
// for this generation even though the run read as open, and that is a
// terminal conflict, not an unhandled driver fault.
async function insertTerminalEvent(conn, e, conflictDetail) {
  try {
    return await insertEvent(conn, e);
  } catch (err) {
    if (!isUniqueViolation(err)) throw err;
    throw new ConflictSignal('terminal', {
      anomalyClass: 'terminal_conflict',
      taskId: e.taskId,
      runGeneration: e.runGeneration,
      terminalFingerprint: `${e.taskId}:${e.runGeneration}`,
      detail: { ...conflictDetail, reason: 'terminal_event_already_exists' }
    });
  }
}

// Shared implementation of `complete` and `fail`. Both commit the SAME atomic
// bundle and differ only in the event type/outcome, the run status, the resulting
// task status, and the set of task states they may commit from.
async function commitTerminal(store, params, { now = nowIso(), fault, faultBeforeDelivery } = {}, spec) {
  if (!params.taskId) throw new ValidationError(`${spec.verb} requires a <task_id>`);
  if (!Number.isInteger(params.generation) || params.generation < 1) {
    throw new ValidationError(`${spec.verb} requires an integer --generation >= 1`);
  }
  if (!Number.isInteger(params.expectedRevision)) {
    throw new ValidationError(`${spec.verb} requires an integer --expected-revision`);
  }
  validateTerminalProvenance(spec.verb, params);
  const outcome = spec.resolveOutcome(params);
  const payload = spec.buildPayload(params);
  // expected_revision is part of the request identity, matching S1's begin-run/event:
  // a replay that changes the causal token it acted on is a DIFFERENT request, not an
  // idempotent replay. Producer and seq are part of it too: a retry that claims
  // different provenance is a DIFFERENT request and must surface as an idempotency
  // conflict, never silently replay the stored result (qa-s2-q54 finding 2).
  const requestHash = sha256hex(canonicalJson({
    verb: spec.verb, task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision, outcome,
    producer: params.producer, seq: params.seq, payload
  }));

  return executeCommand(store, {
    verb: spec.verb, commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S2_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      await applyS2Schema(conn);

      const task = await readTask(conn, params.taskId);
      if (!task) {
        throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      }
      const runQ = await conn.query(
        'SELECT status, closed_at, endpoint_id FROM runs WHERE task_id = $1 AND run_generation = $2',
        [params.taskId, params.generation]
      );
      if (runQ.rows.length === 0) {
        throw new StateTransitionError(
          `no such run generation ${params.generation} for task ${params.taskId}`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      const run = runQ.rows[0];

      const conflictDetail = {
        command_id: ctx.commandId, verb: spec.verb,
        task_id: params.taskId, generation: params.generation
      };

      // TERMINAL-CONFLICT GUARD, ahead of the causal check: a second terminal for a
      // closed generation is illegal regardless of how current the caller's revision
      // token is, and reporting it as a stale-revision causal conflict would
      // mis-describe it. The idempotent-replay pre-check in the envelope already
      // returned before here for a true replay, so reaching this with a closed
      // generation means a genuinely different command is trying to re-terminate it.
      if (run.closed_at !== null) {
        throw new ConflictSignal('terminal', {
          anomalyClass: 'terminal_conflict', taskId: params.taskId, runGeneration: params.generation,
          terminalFingerprint: `${params.taskId}:${params.generation}`,
          detail: {
            ...conflictDetail, reason: 'generation_already_closed',
            existing_run_status: run.status, attempted_status: spec.runStatus
          }
        });
      }

      // Causal token check, ahead of the state guard, so a writer acting on a stale
      // revision is a causal conflict rather than a state-transition error (S1 ruling
      // Q4, preserved here).
      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId,
          runGeneration: params.generation, terminalFingerprint: ctx.commandId,
          detail: {
            ...conflictDetail, reason: 'stale_revision',
            expected_revision: params.expectedRevision, actual_revision: Number(task.revision)
          }
        });
      }

      if (!spec.fromStates.has(task.status)) {
        throw new StateTransitionError(
          `${spec.verb} not allowed from status '${task.status}'`,
          { task_id: params.taskId, status: task.status, verb: spec.verb }
        );
      }

      // The caller's producer sequence must strictly advance its own high-water
      // within the generation, exactly as generic `event` enforces (ruling Q5:
      // reject seq <= last_seq; gaps tolerated). This is what makes the supplied
      // --seq a CHECKED causal claim rather than decoration.
      const hw = await conn.query(
        'SELECT last_seq FROM producer_highwater WHERE task_id = $1 AND run_generation = $2 AND producer_id = $3',
        [params.taskId, params.generation, params.producer]
      );
      const lastSeq = hw.rows.length > 0 ? Number(hw.rows[0].last_seq) : 0;
      if (params.seq <= lastSeq) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId,
          runGeneration: params.generation, terminalFingerprint: `${params.producer}:${params.seq}`,
          detail: {
            ...conflictDetail, reason: 'nonmonotonic_producer_seq',
            producer: params.producer, seq: params.seq, last_seq: lastSeq
          }
        });
      }

      // ---- the atomic bundle: event + run closure + outbox, one commit ----
      // The event's provenance is the CALLER's, stored verbatim (qa-s2-q54
      // finding 2): the producer that observed the outcome owns the terminal claim.
      const payloadHash = sha256hex(canonicalJson(payload));
      const eventId = await insertTerminalEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation,
        generationKey: params.generation, producer: params.producer, producerSeq: params.seq,
        eventType: spec.eventType, isTerminal: true, outcome, payload, now: ctx.now
      }, conflictDetail);

      // A terminal run keeps binding cleanup_pending while it still has a stored
      // endpoint for S3's cleanup saga to reconcile; with no endpoint there is
      // nothing to clean and the binding closes immediately (spec section 4).
      const bindingState = run.endpoint_id === null ? 'closed' : 'cleanup_pending';
      await conn.query(
        'UPDATE runs SET status = $1, closed_at = $2, binding_state = $3 WHERE task_id = $4 AND run_generation = $5',
        [spec.runStatus, ctx.now, bindingState, params.taskId, params.generation]
      );

      // Test-only crash injection at the sharpest cut in this slice: the terminal
      // event is written and the run is closed, but the delivery is NOT yet inserted.
      // A writer that dies here must leave NONE of the three - if the run closure
      // could outlive the missing outbox row, a terminal outcome would silently never
      // reach FirstMate (t_recovers_when_terminal_writer_exits_before_outbox). Mirrors
      // S1's existing `fault` hook; never invoked by any production caller.
      if (typeof faultBeforeDelivery === 'function') faultBeforeDelivery();

      const taskSeq = await deliverEvent(conn, {
        eventId, taskId: params.taskId, runGeneration: params.generation,
        generationKey: params.generation, eventType: spec.eventType,
        payloadHash, now: ctx.now
      });

      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: params.producer,
        seq: params.seq, commandId: ctx.commandId, now: ctx.now
      });

      // Authoritative commit guard. The leading comparison above rejects a stale token
      // early with a precise reason; this CAS is what actually commits the transition,
      // so the revision can never advance on a token that no longer matches.
      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        'UPDATE tasks SET status = $1, revision = $2, updated_at = $3 WHERE task_id = $4 AND revision = $5 RETURNING revision',
        [spec.taskStatus, newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId,
          runGeneration: params.generation, terminalFingerprint: ctx.commandId,
          detail: {
            ...conflictDetail, reason: 'stale_revision',
            expected_revision: params.expectedRevision, actual_revision: Number(task.revision)
          }
        });
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, event_id: eventId,
          event_type: spec.eventType, outcome, status: spec.taskStatus,
          run_status: spec.runStatus, binding_state: bindingState,
          revision: newRevision, delivered: true, task_seq: taskSeq
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// complete: {running|waiting_firstmate} -> completed. Terminal event, run closure,
// and outbox row commit together.
export async function completeRun(store, params, opts = {}) {
  return commitTerminal(store, params, opts, {
    verb: 'complete',
    eventType: 'completed',
    runStatus: 'completed',
    taskStatus: 'completed',
    fromStates: COMPLETE_FROM,
    // --outcome is REQUIRED and validated against the allowed set (exactly
    // 'success', per the outcome_tied CHECK). A caller asserting any other outcome
    // through `complete` is using the wrong verb and is rejected loudly rather than
    // silently converted (qa-s2-q54 finding 2).
    resolveOutcome: (p) => {
      if (p.outcome === undefined) {
        throw new ValidationError(
          `complete requires --outcome (allowed: ${[...COMPLETE_OUTCOMES].join(', ')})`
        );
      }
      if (!COMPLETE_OUTCOMES.has(p.outcome)) {
        throw new ValidationError(
          `complete --outcome must be one of ${[...COMPLETE_OUTCOMES].join(', ')}`, { outcome: p.outcome }
        );
      }
      return p.outcome;
    },
    // The evidence named by --evidence-file is REQUIRED and rides durably in the
    // owned terminal event's payload; losing it silently was finding 2's harm.
    buildPayload: (p) => {
      if (p.evidence === undefined) {
        throw new ValidationError('complete requires --evidence-file');
      }
      return { evidence: p.evidence };
    }
  });
}

// fail: {spawning|running|blocked|waiting_firstmate|needs_human} -> failed. The
// `spawning` entry is the partial-launch path (spec section 4).
export async function failRun(store, params, opts = {}) {
  return commitTerminal(store, params, opts, {
    verb: 'fail',
    eventType: 'failed',
    runStatus: 'failed',
    taskStatus: 'failed',
    fromStates: FAIL_FROM,
    // A failed run's outcome is 'failure', full stop (spec section 6 gives fail no
    // --outcome). The dispatcher already rejects the flag; this guard keeps the
    // domain seam equally closed so no in-package caller can author a
    // caller-selected failed outcome either (qa-s2r2-q55).
    resolveOutcome: (p) => {
      if (p.outcome !== undefined) {
        throw new ValidationError(
          "fail records outcome 'failure'; an outcome is not part of its surface", { outcome: p.outcome }
        );
      }
      return 'failure';
    },
    // --reason is REQUIRED and persisted in the failed event's payload; --artifacts-file
    // is the spec's one optional terminal input and rides along when supplied.
    buildPayload: (p) => {
      const reason = requireReason('fail', p.reason);
      return p.artifacts === undefined ? { reason } : { reason, artifacts: p.artifacts };
    }
  });
}

// cancel: queued -> archived (ruling RISK#4, option ii). Cancellation is a
// TASK-SCOPE archive path before any run exists, not a run terminal outcome - there
// is no `abandoned` run status (spec section 3.1 R2-4). It emits two task-scope
// events in one commit: a coordinator-generated `cancelled` that IS delivered
// through the outbox with generation_key = -1 (the R3-1 case the spec makes an S2
// contract test), and an `archived` that is audit-only per the delivery policy.
export async function cancelTask(store, params, { now = nowIso(), fault } = {}) {
  if (!params.taskId) throw new ValidationError('cancel requires a <task_id>');
  if (!Number.isInteger(params.expectedRevision)) {
    throw new ValidationError('cancel requires an integer --expected-revision');
  }
  // --reason is REQUIRED (spec section 6) and is the cancelled event's durable
  // payload: queued work must never disappear without a recorded why (qa-s2-q54
  // finding 2).
  const reason = requireReason('cancel', params.reason);
  const payload = { reason };
  const requestHash = sha256hex(canonicalJson({
    verb: 'cancel', task_id: params.taskId,
    expected_revision: params.expectedRevision, reason
  }));

  return executeCommand(store, {
    verb: 'cancel', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S2_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      await applyS2Schema(conn);

      const task = await readTask(conn, params.taskId);
      if (!task) {
        throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      }
      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId,
          terminalFingerprint: ctx.commandId,
          detail: {
            command_id: ctx.commandId, verb: 'cancel', reason: 'stale_revision',
            expected_revision: params.expectedRevision, actual_revision: Number(task.revision)
          }
        });
      }
      // Queued-only. Cancellation and terminal archive are separate guards, and
      // `cancel` is legal only before any run exists (spec section 4, R2-5/R3-3).
      // Archiving a task that already ran is the distinct `archive` verb, which S2
      // does not own.
      if (task.status !== 'queued') {
        throw new StateTransitionError(
          `cancel is allowed only while a task is still queued (status '${task.status}')`,
          { task_id: params.taskId, status: task.status }
        );
      }

      // Task-scope producer sequence namespace is run_generation = -1, continuing the
      // high-water create-task already advanced to 1: cancelled = 2, archived = 3.
      // Derived, not hardcoded, so it cannot collide under ux_event_producer_seq.
      const cancelSeq = await nextProducerSeq(conn, params.taskId, -1, 'coordinator');
      const cancelPayloadHash = sha256hex(canonicalJson(payload));
      const cancelledEventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'task', runGeneration: null, generationKey: -1,
        producer: 'coordinator', producerSeq: cancelSeq, eventType: 'cancelled',
        isTerminal: false, outcome: null, payload, now: ctx.now
      });
      const taskSeq = await deliverEvent(conn, {
        eventId: cancelledEventId, taskId: params.taskId, runGeneration: null,
        generationKey: -1, eventType: 'cancelled', payloadHash: cancelPayloadHash, now: ctx.now
      });

      // Audit-only by the delivery policy: durable in task_events, no outbox row.
      const archivedEventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'task', runGeneration: null, generationKey: -1,
        producer: 'coordinator', producerSeq: cancelSeq + 1, eventType: 'archived',
        isTerminal: false, outcome: null, payload: {}, now: ctx.now
      });

      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: -1, producer: 'coordinator',
        seq: cancelSeq + 1, commandId: ctx.commandId, now: ctx.now
      });

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        `UPDATE tasks SET status = 'archived', revision = $1, archived_at = $2, updated_at = $2
           WHERE task_id = $3 AND revision = $4 RETURNING revision`,
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId,
          terminalFingerprint: ctx.commandId,
          detail: {
            command_id: ctx.commandId, verb: 'cancel', reason: 'stale_revision',
            expected_revision: params.expectedRevision, actual_revision: Number(task.revision)
          }
        });
      }

      return {
        result: {
          task_id: params.taskId, status: 'archived', revision: newRevision,
          cancelled_event_id: cancelledEventId, archived_event_id: archivedEventId,
          delivered: true, task_seq: taskSeq
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}
