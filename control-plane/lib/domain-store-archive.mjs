import { PgliteLocalStore } from './pglite-local-store.mjs';
import { parseArgs } from './coordinator.mjs';
import { ValidationError } from './errors.mjs';
import { StateTransitionError } from './errors-s1.mjs';
import {
  executeCommand, sha256hex, canonicalJson, readTask, insertEvent, upsertHighwater, ConflictSignal
} from './domain-store.mjs';

// `cp archive` (spec-amend-s4 section 4 transition table line 482; command surface
// line 585). The distinct terminal-archive verb: {completed|failed} -> archived.
//
// It is NOT `cancel`. `cancel` (S2) archives a task that is still `queued`, before any
// run exists (spec 487-488). `archive` archives a task whose CURRENT generation already
// reached a terminal outcome AND was fully wound down: the terminal outbox delivery is
// acknowledged (S4) and the generation's cleanup saga finished with cleanup_state
// 'cleaned' (S3). There is deliberately no `needs_human -> archived` path (spec 484):
// needs-human work must first resolve to running/waiting_firstmate/failed/completed.
//
// The `archived` event is audit-only per the store-owned delivery policy (spec 618-625,
// delivery-policy.mjs): it is durable in task_events and NEVER creates an outbox row.
// The verb is a single ordinary envelope mutation - CAS tasks.revision +1, domain_revision
// +1, commit_sequence +1, projection_revision untouched - run through the shared
// executeCommand, so idempotent replay by command-id returns the stored result unchanged.

function nowIso() {
  return new Date().toISOString();
}

// The next strictly-advancing coordinator producer sequence in the task-scope namespace
// (run_generation = -1, mirroring ux_event_producer_seq's COALESCE(run_generation,-1)).
// For a completed/failed task the task-scope coordinator high-water sits at `created`
// (seq 1), so the `archived` event derives seq 2 rather than hardcoding it - a hardcode
// would collide under ux_event_producer_seq the moment any other task-scope coordinator
// event exists.
async function nextTaskScopeSeq(conn, taskId) {
  const hw = await conn.query(
    'SELECT last_seq FROM producer_highwater WHERE task_id = $1 AND run_generation = -1 AND producer_id = $2',
    [taskId, 'coordinator']
  );
  return (hw.rows.length > 0 ? Number(hw.rows[0].last_seq) : 0) + 1;
}

const TERMINAL_TASK_STATES = new Set(['completed', 'failed']);

// archive: {completed|failed} -> archived. Three preconditions, each individually a loud
// StateTransitionError that names the missing precondition rather than a silent no-op:
//   1. the task is in a terminal state (completed|failed);
//   2. the CURRENT generation's terminal outbox row is ACKED (acked_at set by `cp ack`);
//   3. the CURRENT generation's cleanup finished (runs.cleanup_state = 'cleaned').
// A non-terminal status (queued/spawning/running/blocked/waiting_firstmate/needs_human)
// fails guard 1 - in particular there is no needs_human -> archived path (spec 484).
export async function archiveTask(store, params, { now = nowIso(), fault } = {}) {
  if (!params.taskId) throw new ValidationError('archive requires a <task_id>');
  if (!Number.isInteger(params.expectedRevision)) {
    throw new ValidationError('archive requires an integer --expected-revision');
  }

  const requestHash = sha256hex(canonicalJson({
    verb: 'archive', task_id: params.taskId, expected_revision: params.expectedRevision
  }));

  return executeCommand(store, {
    verb: 'archive', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) {
        throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      }
      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', {
          anomalyClass: 'causal_ordering_violation', taskId: params.taskId,
          terminalFingerprint: ctx.commandId,
          detail: {
            command_id: ctx.commandId, verb: 'archive', reason: 'stale_revision',
            expected_revision: params.expectedRevision, actual_revision: Number(task.revision)
          }
        });
      }

      // Guard 1: terminal task state. A queued task belongs to `cancel`; a needs_human
      // task must resolve to a terminal state first (spec 484-488).
      if (!TERMINAL_TASK_STATES.has(task.status)) {
        throw new StateTransitionError(
          `archive requires a terminal task (completed|failed); status is '${task.status}' ` +
          '(queued cancellation is the distinct `cancel` verb, and there is no needs_human -> archived path)',
          { task_id: params.taskId, status: task.status }
        );
      }

      const generation = Number(task.current_generation);

      // Guard 2: the current generation's terminal outbox delivery is acknowledged. The
      // terminal (completed/failed) event is run-scope; its outbox copy carries acked_at
      // once `cp ack` advanced the consumer cursor past it (S4).
      const tev = await conn.query(
        'SELECT event_id FROM task_events WHERE task_id = $1 AND run_generation = $2 AND is_terminal',
        [params.taskId, generation]
      );
      if (tev.rows.length !== 1) {
        throw new StateTransitionError(
          `archive requires exactly one terminal event for the current generation ${generation} ` +
          `(found ${tev.rows.length})`,
          { task_id: params.taskId, generation, terminal_events: tev.rows.length }
        );
      }
      const ob = await conn.query(
        'SELECT acked_at FROM outbox WHERE event_id = $1', [tev.rows[0].event_id]
      );
      if (ob.rows.length !== 1) {
        throw new StateTransitionError(
          'archive requires the terminal outbox delivery to exist for the current generation',
          { task_id: params.taskId, generation }
        );
      }
      if (ob.rows[0].acked_at === null || ob.rows[0].acked_at === undefined) {
        throw new StateTransitionError(
          'archive requires the current generation\'s terminal outbox row to be acked',
          { task_id: params.taskId, generation }
        );
      }

      // Guard 3: the current generation's cleanup saga finished (spec 489). cleanup-finish
      // sets cleanup_state 'cleaned' (and binding 'closed') together (S3); this verb pins
      // on the 'cleaned' cleanup state exactly as the dispatch brief requires.
      const runQ = await conn.query(
        'SELECT cleanup_state FROM runs WHERE task_id = $1 AND run_generation = $2',
        [params.taskId, generation]
      );
      if (runQ.rows.length !== 1 || runQ.rows[0].cleanup_state !== 'cleaned') {
        throw new StateTransitionError(
          "archive requires the current generation's cleanup to be complete (cleanup_state 'cleaned')",
          {
            task_id: params.taskId, generation,
            cleanup_state: runQ.rows.length === 1 ? runQ.rows[0].cleanup_state : null
          }
        );
      }

      // Effect: one audit-only task-scope `archived` event, no outbox row (delivery
      // policy). run_generation NULL / generation_key -1, high-water continued in the
      // task-scope coordinator namespace.
      const seq = await nextTaskScopeSeq(conn, params.taskId);
      const archivedEventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'task', runGeneration: null, generationKey: -1,
        producer: 'coordinator', producerSeq: seq, eventType: 'archived',
        isTerminal: false, outcome: null, payload: {}, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: -1, producer: 'coordinator',
        seq, commandId: ctx.commandId, now: ctx.now
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
            command_id: ctx.commandId, verb: 'archive', reason: 'stale_revision',
            expected_revision: params.expectedRevision, actual_revision: Number(task.revision)
          }
        });
      }

      return {
        result: {
          task_id: params.taskId, status: 'archived', revision: newRevision,
          generation, archived_event_id: archivedEventId, delivered: false
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// Thin verb dispatcher, mirroring the S1-S5 pattern: the S0 coordinator delegates here
// via a single registration branch. Runs the same storage lifecycle (flock + open + one
// BEGIN/COMMIT + close-before-unlock) through the sanctioned in-package seam.
export const ARCHIVE_VERBS = new Set(['archive']);

export async function runArchiveVerb(verb, rest, { env = process.env } = {}) {
  const { flags, positionals } = parseArgs(rest);
  const store = PgliteLocalStore.create({ dataDir: flags['data-dir'], env });
  try {
    const result = await dispatch(verb, flags, positionals, store);
    return { ok: true, result };
  } finally {
    await store.close();
  }
}

async function dispatch(verb, flags, positionals, store) {
  if (verb !== 'archive') throw new ValidationError(`unhandled archive verb: ${verb}`);
  // `archived` is audit-only; delivery is store-owned, so a --deliver/--no-deliver switch
  // is rejected loudly rather than ignored (spec section 6.1).
  if ('deliver' in flags || 'no-deliver' in flags) {
    throw new ValidationError(
      "'archive' has no --deliver/--no-deliver switch; delivery policy is store-owned (spec section 6.1)",
      { verb }
    );
  }
  const taskId = positionals[0];
  if (!taskId) throw new ValidationError('archive requires a <task_id> positional argument');
  const rev = flags['expected-revision'];
  if (rev === undefined || rev === true || !Number.isInteger(Number(rev))) {
    throw new ValidationError('archive requires an integer --expected-revision', { verb });
  }
  return archiveTask(store, {
    taskId,
    expectedRevision: Number(rev),
    commandId: flags['command-id']
  });
}
