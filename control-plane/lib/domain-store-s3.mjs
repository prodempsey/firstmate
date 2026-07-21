import { runExclusive } from './internal-runtime.mjs';
import { ValidationError } from './errors.mjs';
import { StateTransitionError } from './errors-s1.mjs';
import { IdentityMismatchError } from './errors-s3.mjs';
import {
  captureIdentity as realCaptureIdentity,
  probeIdentity as realProbeIdentity,
  cleanupTargetMatches as realCleanupTargetMatches
} from './tmux-adapter.mjs';
import {
  executeCommand, ConflictSignal, insertEvent, upsertHighwater,
  canonicalJson, sha256hex, readTask, ensureInitialized
} from './domain-store.mjs';

// S3 domain layer: the spawn/running/cleanup lifecycle verbs (spec-amend-s4 section
// 12, S3 row): record-spawn, commit-running, verify-running, cleanup-intent, and
// cleanup-finish.
//
// This module adds NO new access path to the database and NO new schema. It reuses
// S1's command envelope (executeCommand) exactly as S1 and S2 do - inheriting the
// required command-id, idempotent replay, the SAVEPOINT-guarded conflict audit, the
// audit-counter contract, and the atomic bundle - and it writes only to S1-owned
// tables (`runs`, `task_events`) that executeCommand's own S1 schema apply guarantees
// present. It registers ONE new conflict class through the envelope's defaulted
// `conflictErrors` param (the `identity` kind -> IdentityMismatchError), exactly the
// generalization S2 used for its terminal class, so domain-store.mjs and
// domain-store-s2.mjs stay byte-identical.
//
// THE HEART OF S3 IS THE ANTI-GHOST GUARANTEE. Promotion to running/bound_verified is
// gated on a LIVE identity match at commit time (commit-running). A run whose endpoint
// died between record-spawn and commit-running can never surface as a live running
// card: commit-running rejects with IdentityMismatchError, persists the anomaly through
// the sanctioned audit path, and leaves the run exactly as spawning as it was. That
// structural gate is the antidote to the dead-crew-reported-alive class.
//
// Every S3 lifecycle event (spawned, running_verified, cleanup_started, cleaned) is
// AUDIT-ONLY (insertEvent, never deliverEvent): it is durable in task_events but
// creates NO outbox row (spec section 6.1). S3 therefore never touches the outbox.

// S3 registers ONLY its own conflict class; idempotency/causal are inherited from the
// envelope's defaults, so their messages and types stay S1's.
const S3_CONFLICT_ERRORS = {
  identity: (detail) =>
    new IdentityMismatchError('commit-running identity probe did not match a live endpoint', detail)
};

// The production probes need the isolated control-plane tmux socket; the domain layer
// stays deterministic by reading it from the environment and leaving all real probing
// to the injected/real adapter. Tests inject deterministic doubles that ignore it.
function defaultSocket() {
  return process.env.CP_TMUX_SOCKET || 'cp-default';
}
function defaultCaptureIdentity(arg) {
  return realCaptureIdentity({ ...arg, socket: defaultSocket() });
}
function defaultProbeIdentity(arg) {
  return realProbeIdentity({ ...arg, socket: defaultSocket() });
}
function defaultCleanupProbe(arg) {
  return realCleanupTargetMatches({ ...arg, socket: defaultSocket() });
}

function nowIso() {
  return new Date().toISOString();
}

// The next strictly-advancing coordinator sequence within the run-generation
// namespace, derived from the producer high-water (ruling RISK#3) and NEVER hardcoded
// (ruling RISK#3/Q3). begin-run left spawn_intent at seq 1, so the S3 coordinator
// chain continues spawned=2, running_verified=3, cleanup_started=4, cleaned=5 - but a
// partial-launch path that skips commit-running derives smaller seqs, which is exactly
// why this is computed rather than pinned.
async function nextProducerSeq(conn, taskId, generation, producer) {
  const hw = await conn.query(
    'SELECT last_seq FROM producer_highwater WHERE task_id = $1 AND run_generation = $2 AND producer_id = $3',
    [taskId, generation, producer]
  );
  return (hw.rows.length > 0 ? Number(hw.rows[0].last_seq) : 0) + 1;
}

function requireIntFlag(verb, value, name, { min } = {}) {
  if (!Number.isInteger(value) || (min !== undefined && value < min)) {
    throw new ValidationError(
      `${verb} requires an integer --${name}${min !== undefined ? ` >= ${min}` : ''}`,
      { [name]: value ?? null }
    );
  }
}

function requireStr(verb, value, name) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new ValidationError(`${verb} requires --${name}`, { [name]: value ?? null });
  }
}

// record-spawn: {spawning} -> spawning (revision bump only). Verify the caller's
// launch marker against the run's stored marker, capture the coherent /proc + tmux
// identity through the injected probe, write the endpoint and identity tuple, and emit
// the audit-only `spawned` event. Binding stays 'spawning' (ruling Q4): verification
// is commit-running's job. The request hash covers ONLY the caller's inputs, never the
// captured /proc values, which are nondeterministic outputs that would break replay.
export async function recordSpawn(store, params, { now = nowIso(), fault, captureIdentity = defaultCaptureIdentity } = {}) {
  requireStr('record-spawn', params.taskId, 'task_id');
  requireIntFlag('record-spawn', params.generation, 'generation', { min: 1 });
  requireIntFlag('record-spawn', params.expectedRevision, 'expected-revision');
  requireStr('record-spawn', params.launchMarker, 'launch-marker');
  requireStr('record-spawn', params.endpoint, 'endpoint');
  requireStr('record-spawn', params.pane, 'pane');
  requireStr('record-spawn', params.regFile, 'reg-file');

  const requestHash = sha256hex(canonicalJson({
    verb: 'record-spawn', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision, launch_marker: params.launchMarker,
    endpoint: params.endpoint, pane: params.pane, reg_file: params.regFile
  }));

  return executeCommand(store, {
    verb: 'record-spawn', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S3_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        `SELECT status, closed_at, launch_marker, bind_nonce, registration_path, endpoint_id, run_generation
           FROM runs WHERE task_id = $1 AND run_generation = $2`,
        [params.taskId, params.generation]
      );
      if (runQ.rows.length === 0) {
        throw new StateTransitionError(
          `no such run generation ${params.generation} for task ${params.taskId}`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      const run = runQ.rows[0];

      // Causal token check precedes the state guards (S1 ruling Q4): a writer on a
      // stale revision is a causal conflict, not a state-transition error.
      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'record-spawn', params, Number(task.revision)));
      }
      if (run.closed_at !== null) {
        throw new StateTransitionError(
          `record-spawn not allowed; generation ${params.generation} is terminal`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      if (task.status !== 'spawning' || run.status !== 'spawning') {
        throw new StateTransitionError(
          `record-spawn requires a spawning generation (task '${task.status}', run '${run.status}')`,
          { task_id: params.taskId, status: task.status, run_status: run.status }
        );
      }
      // The caller's marker must match the run's precommitted launch marker: a
      // record-spawn aimed at a marker this run does not own is recording the wrong
      // launch and is refused (spec section 5.2 "matching marker").
      if (params.launchMarker !== run.launch_marker) {
        throw new StateTransitionError(
          'record-spawn launch marker does not match the run\'s stored marker',
          { task_id: params.taskId, generation: params.generation }
        );
      }
      // No marker collision: the launch marker must identify exactly this one run. The
      // ux_launch_marker unique index guarantees it at begin-run; asserting it here is
      // the belt-and-braces guard the spec names (section 5.2 "no marker collision").
      const coll = await conn.query(
        'SELECT count(*)::int AS n FROM runs WHERE launch_marker = $1', [run.launch_marker]
      );
      if (Number(coll.rows[0].n) !== 1) {
        throw new StateTransitionError(
          'record-spawn found a launch-marker collision; the marker must identify exactly one run',
          { task_id: params.taskId, generation: params.generation, count: Number(coll.rows[0].n) }
        );
      }

      // Capture the coherent /proc + tmux identity through the injected probe (real
      // adapter by default, deterministic double in tests). A capture that cannot
      // coherently identify the launch is an environmental/out-of-order failure of the
      // caller's OWN spawn - un-audited: it aborts the whole transaction, persisting
      // nothing (not even an anomaly), unlike commit-running's audited identity
      // conflict.
      const cap = await captureIdentity({ run: { ...run, task_id: params.taskId }, params, now: ctx.now });
      if (!cap || cap.ok !== true) {
        throw new IdentityMismatchError(
          'record-spawn could not capture a coherent launch identity',
          { task_id: params.taskId, generation: params.generation, reason: cap?.reason ?? 'capture_failed', failing_clause: cap?.clause ?? null }
        );
      }
      const id = cap.identity;

      // Write the endpoint and the /proc identity tuple. binding_state and run status
      // deliberately STAY 'spawning' (ruling Q4).
      await conn.query(
        `UPDATE runs SET
           endpoint_id = $3, pane_id = $4, pane_leader_pid = $5, pane_start_ticks = $6, boot_id = $7,
           agent_pid = $8, agent_start_ticks = $9, agent_exe = $10, agent_argv_hash = $11,
           agent_ppid = $12, agent_pty = $13, worktree = $14, harness = $15
         WHERE task_id = $1 AND run_generation = $2`,
        [
          params.taskId, params.generation,
          id.endpointId, id.paneId, id.paneLeaderPid ?? null, id.paneStartTicks ?? null, id.bootId ?? null,
          id.agentPid ?? null, id.agentStartTicks ?? null, id.agentExe ?? null, id.agentArgvHash ?? null,
          id.agentPpid ?? null, id.agentPty ?? null, id.worktree ?? null, id.harness ?? null
        ]
      );

      // AUDIT-ONLY: durable in task_events, NO outbox row (insertEvent, not deliverEvent).
      const seq = await nextProducerSeq(conn, params.taskId, params.generation, 'coordinator');
      const eventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation, generationKey: params.generation,
        producer: 'coordinator', producerSeq: seq, eventType: 'spawned', isTerminal: false, outcome: null,
        payload: { launch_marker: run.launch_marker, endpoint_id: id.endpointId, pane_id: id.paneId }, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: 'coordinator',
        seq, commandId: ctx.commandId, now: ctx.now
      });

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        'UPDATE tasks SET revision = $1, updated_at = $2 WHERE task_id = $3 AND revision = $4 RETURNING revision',
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'record-spawn', params, Number(task.revision)));
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, status: 'spawning', run_status: 'spawning',
          binding_state: 'spawning', endpoint_id: id.endpointId, event_id: eventId, event_type: 'spawned',
          revision: newRevision
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// commit-running: spawning -> running. Re-probe the STORED identity; on a live match
// promote to running/open/bound_verified and emit the audit-only `running_verified`.
// On a probe FAIL, reject with IdentityMismatchError through the sanctioned audit path
// (anomaly persists, mutation rolled back) and leave the run spawning and the binding
// unchanged (ruling RISK#1): the identity_lost event, binding='lost', and the
// deadline-gated partial-launch fail are ALL S5, never built here.
export async function commitRunning(store, params, { now = nowIso(), fault, probeIdentity = defaultProbeIdentity } = {}) {
  requireStr('commit-running', params.taskId, 'task_id');
  requireIntFlag('commit-running', params.generation, 'generation', { min: 1 });
  requireIntFlag('commit-running', params.expectedRevision, 'expected-revision');

  const requestHash = sha256hex(canonicalJson({
    verb: 'commit-running', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision
  }));

  return executeCommand(store, {
    verb: 'commit-running', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S3_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        `SELECT status, closed_at, endpoint_id, pane_id, pane_leader_pid, pane_start_ticks, boot_id,
                agent_pid, agent_start_ticks, agent_exe, agent_argv_hash, agent_ppid, agent_pty, launch_marker
           FROM runs WHERE task_id = $1 AND run_generation = $2`,
        [params.taskId, params.generation]
      );
      if (runQ.rows.length === 0) {
        throw new StateTransitionError(
          `no such run generation ${params.generation} for task ${params.taskId}`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      const run = runQ.rows[0];

      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'commit-running', params, Number(task.revision)));
      }
      if (run.closed_at !== null) {
        throw new StateTransitionError(
          `commit-running not allowed; generation ${params.generation} is terminal`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      // commit-running requires a spawning task (ruling; spec section 4 spawning ->
      // running). A non-spawning task (already running, blocked, etc.) is a routing
      // error, not a promotion.
      if (task.status !== 'spawning') {
        throw new StateTransitionError(
          `commit-running requires a spawning task (status '${task.status}')`,
          { task_id: params.taskId, status: task.status }
        );
      }
      // A spawning generation with no recorded endpoint has not had record-spawn: there
      // is nothing to verify. That is an out-of-order routing error, not a dead endpoint.
      if (run.endpoint_id === null) {
        throw new StateTransitionError(
          'commit-running requires a recorded spawn (run record-spawn first)',
          { task_id: params.taskId, generation: params.generation }
        );
      }

      // Re-probe the stored identity at commit time. This is the anti-ghost gate.
      const probe = await probeIdentity({ run: { ...run, task_id: params.taskId, run_generation: params.generation }, now: ctx.now });
      if (!probe || probe.matches !== true) {
        // Audited identity conflict: executeCommand rolls the (empty) mutation back to
        // the savepoint, persists the anomaly, advances domain+commit by one, and
        // re-raises IdentityMismatchError. The run STAYS spawning, binding unchanged.
        throw new ConflictSignal('identity', {
          anomalyClass: probe?.anomalyClass ?? 'identity_mismatch',
          taskId: params.taskId, runGeneration: params.generation,
          endpointId: run.endpoint_id, paneId: run.pane_id,
          agentPid: run.agent_pid, agentStartTicks: run.agent_start_ticks,
          terminalFingerprint: run.launch_marker,
          detail: {
            command_id: ctx.commandId, verb: 'commit-running', task_id: params.taskId,
            generation: params.generation, reason: 'identity_mismatch',
            failing_clause: probe?.failingClause ?? null
          }
        });
      }

      // Live match: promote run + task and emit the audit-only running_verified event.
      await conn.query(
        "UPDATE runs SET status = 'open', binding_state = 'bound_verified', verified_at = $3 WHERE task_id = $1 AND run_generation = $2",
        [params.taskId, params.generation, ctx.now]
      );
      const seq = await nextProducerSeq(conn, params.taskId, params.generation, 'coordinator');
      const eventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation, generationKey: params.generation,
        producer: 'coordinator', producerSeq: seq, eventType: 'running_verified', isTerminal: false, outcome: null,
        payload: { endpoint_id: run.endpoint_id, pane_id: run.pane_id }, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: 'coordinator',
        seq, commandId: ctx.commandId, now: ctx.now
      });

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        "UPDATE tasks SET status = 'running', revision = $1, updated_at = $2 WHERE task_id = $3 AND revision = $4 RETURNING revision",
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'commit-running', params, Number(task.revision)));
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, status: 'running', run_status: 'open',
          binding_state: 'bound_verified', event_id: eventId, event_type: 'running_verified', revision: newRevision
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// verify-running: locked READ of the running_verified predicate and, when it fails,
// the failing clause. No command-id, no expected-revision, no counter bump (spec
// section 6 command surface; matches taskHead's read-only shape).
export async function verifyRunning(store, params, { probeIdentity = defaultProbeIdentity } = {}) {
  requireStr('verify-running', params.taskId, 'task_id');
  requireIntFlag('verify-running', params.generation, 'generation', { min: 1 });
  return runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    const present = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'runs'"
    );
    if (present.rows.length === 0) {
      throw new ValidationError(`run not found: ${params.taskId}/${params.generation}`, { task_id: params.taskId });
    }
    const t = await conn.query('SELECT status FROM tasks WHERE task_id = $1', [params.taskId]);
    if (t.rows.length === 0) throw new ValidationError(`task not found: ${params.taskId}`, { task_id: params.taskId });
    const runQ = await conn.query(
      `SELECT status, binding_state, closed_at, endpoint_id, pane_id, pane_leader_pid, pane_start_ticks,
              boot_id, agent_pid, agent_start_ticks, agent_exe, agent_argv_hash, agent_ppid, agent_pty
         FROM runs WHERE task_id = $1 AND run_generation = $2`,
      [params.taskId, params.generation]
    );
    if (runQ.rows.length === 0) {
      throw new ValidationError(`run not found: ${params.taskId}/${params.generation}`, { task_id: params.taskId, generation: params.generation });
    }
    const run = runQ.rows[0];
    const probe = await probeIdentity({ run: { ...run, task_id: params.taskId, run_generation: params.generation } });
    const identityMatches = !!(probe && probe.matches);
    const runningVerified =
      t.rows[0].status === 'running' && run.status === 'open' &&
      run.binding_state === 'bound_verified' && identityMatches;
    return {
      task_id: params.taskId, generation: params.generation,
      running_verified: runningVerified, identity_matches: identityMatches,
      failing_clause: probe?.failingClause ?? null,
      task_status: t.rows[0].status, run_status: run.status, binding_state: run.binding_state
    };
  });
}

// cleanup-intent: commit the exact stored cleanup target and cleanup_state
// 'intent_committed', emit the audit-only `cleanup_started`, and return the exact
// target for the adapter's cleanup effect. Requires binding_state 'cleanup_pending'
// (ruling Q5): on any other binding it is a StateTransitionError ("no endpoint to
// clean"), never a silent no-op.
export async function cleanupIntent(store, params, { now = nowIso(), fault } = {}) {
  requireStr('cleanup-intent', params.taskId, 'task_id');
  requireIntFlag('cleanup-intent', params.generation, 'generation', { min: 1 });
  requireIntFlag('cleanup-intent', params.expectedRevision, 'expected-revision');

  const requestHash = sha256hex(canonicalJson({
    verb: 'cleanup-intent', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision
  }));

  return executeCommand(store, {
    verb: 'cleanup-intent', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S3_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        `SELECT status, closed_at, binding_state, cleanup_state, endpoint_id, pane_id, pane_leader_pid,
                pane_start_ticks, boot_id, agent_pid, agent_start_ticks, agent_exe, agent_argv_hash,
                agent_ppid, agent_pty
           FROM runs WHERE task_id = $1 AND run_generation = $2`,
        [params.taskId, params.generation]
      );
      if (runQ.rows.length === 0) {
        throw new StateTransitionError(
          `no such run generation ${params.generation} for task ${params.taskId}`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      const run = runQ.rows[0];

      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'cleanup-intent', params, Number(task.revision)));
      }
      // Ruling Q5: cleanup-intent is legal only on a terminal run that still holds an
      // endpoint to clean (binding_state 'cleanup_pending'). On closed/spawning/open it
      // is a StateTransitionError, not a silent no-op.
      if (run.binding_state !== 'cleanup_pending') {
        throw new StateTransitionError(
          `cleanup-intent requires a terminal run with an endpoint to clean (binding_state 'cleanup_pending', got '${run.binding_state}')`,
          { task_id: params.taskId, generation: params.generation, binding_state: run.binding_state }
        );
      }
      if (run.cleanup_state !== 'not_started') {
        throw new StateTransitionError(
          `cleanup-intent already committed (cleanup_state '${run.cleanup_state}')`,
          { task_id: params.taskId, generation: params.generation, cleanup_state: run.cleanup_state }
        );
      }

      const target = {
        endpoint_id: run.endpoint_id, pane_id: run.pane_id, pane_leader_pid: run.pane_leader_pid,
        pane_start_ticks: run.pane_start_ticks, boot_id: run.boot_id, agent_pid: run.agent_pid,
        agent_start_ticks: run.agent_start_ticks, agent_exe: run.agent_exe, agent_argv_hash: run.agent_argv_hash,
        agent_ppid: run.agent_ppid, agent_pty: run.agent_pty
      };
      await conn.query(
        "UPDATE runs SET cleanup_state = 'intent_committed', cleanup_started_at = $3 WHERE task_id = $1 AND run_generation = $2",
        [params.taskId, params.generation, ctx.now]
      );
      const seq = await nextProducerSeq(conn, params.taskId, params.generation, 'coordinator');
      const eventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation, generationKey: params.generation,
        producer: 'coordinator', producerSeq: seq, eventType: 'cleanup_started', isTerminal: false, outcome: null,
        payload: { endpoint_id: run.endpoint_id, pane_id: run.pane_id }, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: 'coordinator',
        seq, commandId: ctx.commandId, now: ctx.now
      });

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        'UPDATE tasks SET revision = $1, updated_at = $2 WHERE task_id = $3 AND revision = $4 RETURNING revision',
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'cleanup-intent', params, Number(task.revision)));
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, revision: newRevision,
          cleanup_state: 'intent_committed', binding_state: 'cleanup_pending',
          event_id: eventId, event_type: 'cleanup_started', target
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// cleanup-finish: commit `cleaned`, cleanup_state 'cleaned', binding 'closed', and the
// cleanup timestamps, carrying the adapter's --effect-result verbatim in the audit-only
// `cleaned` event. Requires a committed cleanup intent; a same-command retry is an
// idempotent replay of the stored clean result (spec section 7 crash recovery).
export async function cleanupFinish(store, params, { now = nowIso(), fault } = {}) {
  requireStr('cleanup-finish', params.taskId, 'task_id');
  requireIntFlag('cleanup-finish', params.generation, 'generation', { min: 1 });
  requireIntFlag('cleanup-finish', params.expectedRevision, 'expected-revision');
  if (params.effectResult === undefined) {
    throw new ValidationError('cleanup-finish requires --effect-result-file', { task_id: params.taskId });
  }
  // The effect result must PROVE the endpoint is gone before cleanup may be recorded as
  // done (spec section 7 step 4/5): a `cleaned` commit means the pane is confirmed
  // absent. An effect that killed nothing, hit an identity mismatch, or otherwise leaves
  // the endpoint present is refused loudly and surfaced, NEVER silently written as
  // cleaned/closed - that would orphan a live endpoint while the DB claims it is gone
  // (qa-s3-q58 finding 4). The refusal is a non-audited routing/environment error: the
  // run stays intent_committed/cleanup_pending for a real cleanup or the reconciler.
  if (params.effectResult === null || typeof params.effectResult !== 'object'
      || Array.isArray(params.effectResult) || params.effectResult.confirmed_absent !== true) {
    throw new StateTransitionError(
      'cleanup-finish requires an effect result proving the endpoint is gone (confirmed_absent === true)',
      { task_id: params.taskId, generation: params.generation, effect_result: params.effectResult ?? null }
    );
  }

  const requestHash = sha256hex(canonicalJson({
    verb: 'cleanup-finish', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision, effect_result: params.effectResult
  }));

  return executeCommand(store, {
    verb: 'cleanup-finish', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S3_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        `SELECT status, closed_at, binding_state, cleanup_state, endpoint_id, pane_id
           FROM runs WHERE task_id = $1 AND run_generation = $2`,
        [params.taskId, params.generation]
      );
      if (runQ.rows.length === 0) {
        throw new StateTransitionError(
          `no such run generation ${params.generation} for task ${params.taskId}`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      const run = runQ.rows[0];

      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'cleanup-finish', params, Number(task.revision)));
      }
      if (run.cleanup_state !== 'intent_committed' || run.binding_state !== 'cleanup_pending') {
        throw new StateTransitionError(
          `cleanup-finish requires a committed cleanup intent (cleanup_state 'intent_committed', binding_state 'cleanup_pending'; got '${run.cleanup_state}'/'${run.binding_state}')`,
          { task_id: params.taskId, generation: params.generation, cleanup_state: run.cleanup_state, binding_state: run.binding_state }
        );
      }

      // DDL has no unused intermediate cleanup state (spec section 7 R3-4): intent
      // committed -> cleaned, binding cleanup_pending -> closed, in one commit.
      await conn.query(
        "UPDATE runs SET cleanup_state = 'cleaned', binding_state = 'closed', cleanup_finished_at = $3 WHERE task_id = $1 AND run_generation = $2",
        [params.taskId, params.generation, ctx.now]
      );
      const seq = await nextProducerSeq(conn, params.taskId, params.generation, 'coordinator');
      const eventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation, generationKey: params.generation,
        producer: 'coordinator', producerSeq: seq, eventType: 'cleaned', isTerminal: false, outcome: null,
        payload: { effect_result: params.effectResult }, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: 'coordinator',
        seq, commandId: ctx.commandId, now: ctx.now
      });

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        'UPDATE tasks SET revision = $1, updated_at = $2 WHERE task_id = $3 AND revision = $4 RETURNING revision',
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'cleanup-finish', params, Number(task.revision)));
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, revision: newRevision,
          cleanup_state: 'cleaned', binding_state: 'closed', event_id: eventId, event_type: 'cleaned'
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// cleanup-mismatch: the adapter's cleanup effect found the stored target present but
// its identity materially disagrees, so it REFUSED to kill (tmux-adapter.killExactPane).
// Refusing is only half the contract (spec section 7 step 2): the mismatch must also be
// PERSISTED so the reconciler (S5) can see it. This routes an `identity_mismatch` anomaly
// through the SAME sanctioned audit path commit-running uses - ConflictSignal('identity')
// -> savepoint rollback -> anomaly persisted + audit counters advanced -> IdentityMismatch
// Error - so a cleanup mismatch is durably auditable, coalesced by fingerprint, and never
// mistaken for a successful cleanup. It performs NO kill and makes NO domain change beyond
// the audit; the run stays exactly cleanup_pending/intent_committed for a real cleanup or
// the reconciler.
//
// The mismatch is re-confirmed against the injected cleanup probe (real tmux/proc by
// default) rather than trusted blindly: a caller cannot fabricate an anomaly for a target
// that actually matches.
export async function recordCleanupMismatch(store, params, { now = nowIso(), fault, cleanupProbe = defaultCleanupProbe } = {}) {
  requireStr('cleanup-mismatch', params.taskId, 'task_id');
  requireIntFlag('cleanup-mismatch', params.generation, 'generation', { min: 1 });
  requireIntFlag('cleanup-mismatch', params.expectedRevision, 'expected-revision');

  const requestHash = sha256hex(canonicalJson({
    verb: 'cleanup-mismatch', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision
  }));

  return executeCommand(store, {
    verb: 'cleanup-mismatch', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S3_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        `SELECT status, closed_at, binding_state, cleanup_state, endpoint_id, pane_id, pane_leader_pid,
                pane_start_ticks, boot_id, agent_pid, agent_start_ticks, agent_exe, agent_argv_hash,
                agent_ppid, agent_pty, launch_marker
           FROM runs WHERE task_id = $1 AND run_generation = $2`,
        [params.taskId, params.generation]
      );
      if (runQ.rows.length === 0) {
        throw new StateTransitionError(
          `no such run generation ${params.generation} for task ${params.taskId}`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      const run = runQ.rows[0];

      if (Number(task.revision) !== params.expectedRevision) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'cleanup-mismatch', params, Number(task.revision)));
      }
      // A mismatch is only meaningful while the run still has an endpoint to clean.
      if (run.binding_state !== 'cleanup_pending') {
        throw new StateTransitionError(
          `cleanup-mismatch requires a run still pending cleanup (binding_state 'cleanup_pending', got '${run.binding_state}')`,
          { task_id: params.taskId, generation: params.generation, binding_state: run.binding_state }
        );
      }
      // Re-confirm the mismatch against the probe; refuse to fabricate an anomaly for a
      // target that actually matches (or is already absent - that is a clean cleanup, not
      // a mismatch).
      const probe = await cleanupProbe({ run: { ...run, task_id: params.taskId, run_generation: params.generation } });
      if (!probe || probe.present !== true || probe.matches !== false) {
        throw new StateTransitionError(
          'cleanup-mismatch found no identity mismatch to record (the target matches or is absent)',
          { task_id: params.taskId, generation: params.generation, probe: probe ?? null }
        );
      }
      // Persist the anomaly through the sanctioned audit path (rolled back mutation,
      // surviving anomaly, +1 domain/commit), NO kill, NO domain change.
      throw new ConflictSignal('identity', {
        anomalyClass: 'identity_mismatch',
        taskId: params.taskId, runGeneration: params.generation,
        endpointId: run.endpoint_id, paneId: run.pane_id,
        agentPid: run.agent_pid, agentStartTicks: run.agent_start_ticks,
        terminalFingerprint: run.launch_marker,
        detail: {
          command_id: ctx.commandId, verb: 'cleanup-mismatch', task_id: params.taskId,
          generation: params.generation, reason: 'cleanup_target_mismatch',
          cleanup_reason: probe.reason ?? null
        }
      });
    }
  });
}

// Shared stale-revision causal anomaly builder for the S3 verbs, mirroring S1/S2.
function causalAnomaly(commandId, verb, params, actualRevision) {
  return {
    anomalyClass: 'causal_ordering_violation', taskId: params.taskId,
    runGeneration: params.generation ?? null, terminalFingerprint: commandId,
    detail: {
      command_id: commandId, verb, reason: 'stale_revision',
      expected_revision: params.expectedRevision, actual_revision: actualRevision
    }
  };
}
