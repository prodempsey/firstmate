import { runExclusive } from './internal-runtime.mjs';
import { ValidationError } from './errors.mjs';
import { StateTransitionError } from './errors-s1.mjs';
import { IdentityMismatchError } from './errors-s3.mjs';
import { AnomalyResolutionError } from './errors-s5.mjs';
import { probeIdentity as realProbeIdentity } from './tmux-adapter.mjs';
import {
  executeCommand, ConflictSignal, insertEvent, upsertHighwater, recordAnomaly,
  canonicalJson, sha256hex, readTask, ensureInitialized
} from './domain-store.mjs';

// S5 domain layer: the reconciler-committed domain mutations, the reconciler's
// audit-only anomaly authorship, and resolve-anomaly (spec 789-840, 491-492, 455-456).
//
// Like S2 and S3 this module adds NO new access path to the database and NO new
// schema. Every table it touches - runs, task_events, producer_highwater, anomalies,
// coordinator_state, command_results - is S1-owned and already present; the
// identity_lost event type and the lost/bound_unverified binding states are already in
// the S1 DDL CHECKs (builder VERIFIED: ruling Q3 is a no-op, no S1 edit). It reuses
// S1's command envelope (executeCommand) exactly as S2/S3 do, inheriting the required
// command-id, idempotent replay, the SAVEPOINT-guarded conflict audit, the audit
// counter contract, and the atomic bundle.
//
// PRODUCER IDENTITY (ruling Q2). Every event the reconciler authors carries producer
// `reconciler` in its own run-scope high-water namespace - a DISTINCT authority from
// the coordinator, exactly what spec 578's producer field exists to attribute. The
// reconciler never writes under the coordinator's producer id, so its promotions,
// losses, and re-verifications are always attributable to the reconciler.
//
// THE RECONCILER NEVER KILLS, DELETES, OR ADOPTS (spec 797). It only reads live
// identity through the injected probe seam (the S3 tmux/proc probe by default) and
// commits canonical state: it promotes a verified spawning generation, marks a lost
// binding, demotes to bound_unverified on a transient failure, re-verifies a recovered
// binding, and audits anomalies. The partial-launch/terminal `fail` it reaches for is
// the sanctioned S2 fail path, driven from reconciler.mjs - never a bespoke terminal
// here.

const RECONCILER = 'reconciler';

// resolution-kind vocabulary for resolve-anomaly. The markerless/ambiguous-orphan
// class (`orphan_pane`, spec 553-562/835) is captain-routed and may be resolved ONLY
// with `human_approved` (ruling Q4); the rest are agent-level dispositions. The exact
// per-class resolution predicates are owned by spec 830-840; this enforces the one
// gate the ruling names explicitly and rejects any kind outside the vocabulary.
const RESOLUTION_KINDS = new Set([
  'human_approved', 'agent_verified', 'auto_recovered', 'duplicate', 'benign'
]);

function defaultSocket() {
  return process.env.CP_TMUX_SOCKET || 'cp-default';
}
function defaultProbeIdentity(arg) {
  return realProbeIdentity({ ...arg, socket: defaultSocket() });
}

function nowIso() {
  return new Date().toISOString();
}

// The next strictly-advancing coordinator/reconciler sequence within a run-generation
// namespace, derived from the producer high-water and NEVER hardcoded (mirrors S3).
// The reconciler writes its FIRST event for a generation at seq 1 because its producer
// namespace is empty until it does (begin-run advanced only the `coordinator` id).
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

// Shared stale-revision causal anomaly builder for the S5 verbs, mirroring S1/S2/S3.
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

const S5_CONFLICT_ERRORS = {
  identity: (detail) =>
    new IdentityMismatchError('reconcile identity probe did not match a live endpoint', detail)
};

// reconcilePromote: spawning -> running under RECONCILER authority. This is the
// reconciler's idempotent commit-running (spec 491/791 (c)): re-probe the STORED
// identity at commit time - the anti-ghost gate - and on a live match promote to
// running/open/bound_verified, emitting the audit-only `running_verified` under
// producer `reconciler`. It is byte-for-byte the SAME anti-ghost guarantee S3's
// commit-running gives, only reached by the reconciler and attributed to it: a run
// whose endpoint died is never promoted. On an inside-probe FAIL it raises through the
// sanctioned audit path (anomaly persisted, mutation rolled back, run stays spawning),
// so a reconciler that decided to promote from a stale outside read can never ghost a
// dead endpoint into a running card.
export async function reconcilePromote(store, params, { now = nowIso(), fault, probeIdentity = defaultProbeIdentity } = {}) {
  requireStr('reconcile-promote', params.taskId, 'task_id');
  requireIntFlag('reconcile-promote', params.generation, 'generation', { min: 1 });
  requireIntFlag('reconcile-promote', params.expectedRevision, 'expected-revision');

  const requestHash = sha256hex(canonicalJson({
    verb: 'reconcile-promote', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision
  }));

  return executeCommand(store, {
    verb: 'reconcile-promote', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S5_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        `SELECT status, closed_at, binding_state, endpoint_id, pane_id, pane_leader_pid, pane_start_ticks, boot_id,
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
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'reconcile-promote', params, Number(task.revision)));
      }
      if (run.closed_at !== null) {
        throw new StateTransitionError(
          `reconcile-promote not allowed; generation ${params.generation} is terminal`,
          { task_id: params.taskId, generation: params.generation }
        );
      }
      // A promotion is only meaningful for a spawning generation that recorded a spawn.
      // Anything else (already running, no endpoint) is a routing mismatch the caller
      // should not have reached; refuse without an audit so a lost pass-race is silent.
      if (task.status !== 'spawning' || run.status !== 'spawning') {
        throw new StateTransitionError(
          `reconcile-promote requires a spawning generation (task '${task.status}', run '${run.status}')`,
          { task_id: params.taskId, status: task.status, run_status: run.status }
        );
      }
      if (run.endpoint_id === null) {
        throw new StateTransitionError(
          'reconcile-promote requires a recorded spawn (no endpoint to verify)',
          { task_id: params.taskId, generation: params.generation }
        );
      }

      // The anti-ghost gate: re-probe the STORED identity at commit time.
      const probe = await probeIdentity({ run: { ...run, task_id: params.taskId, run_generation: params.generation }, now: ctx.now });
      if (!probe || probe.matches !== true) {
        throw new ConflictSignal('identity', {
          anomalyClass: probe?.anomalyClass ?? 'identity_mismatch',
          taskId: params.taskId, runGeneration: params.generation,
          endpointId: run.endpoint_id, paneId: run.pane_id,
          agentPid: run.agent_pid, agentStartTicks: run.agent_start_ticks,
          terminalFingerprint: run.launch_marker,
          detail: {
            command_id: ctx.commandId, verb: 'reconcile-promote', task_id: params.taskId,
            generation: params.generation, reason: 'identity_mismatch',
            failing_clause: probe?.failingClause ?? null
          }
        });
      }

      await conn.query(
        "UPDATE runs SET status = 'open', binding_state = 'bound_verified', verified_at = $3 WHERE task_id = $1 AND run_generation = $2",
        [params.taskId, params.generation, ctx.now]
      );
      const seq = await nextProducerSeq(conn, params.taskId, params.generation, RECONCILER);
      const eventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation, generationKey: params.generation,
        producer: RECONCILER, producerSeq: seq, eventType: 'running_verified', isTerminal: false, outcome: null,
        payload: { endpoint_id: run.endpoint_id, pane_id: run.pane_id, by: RECONCILER }, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: RECONCILER,
        seq, commandId: ctx.commandId, now: ctx.now
      });

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        "UPDATE tasks SET status = 'running', revision = $1, updated_at = $2 WHERE task_id = $3 AND revision = $4 RETURNING revision",
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'reconcile-promote', params, Number(task.revision)));
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, status: 'running', run_status: 'open',
          binding_state: 'bound_verified', event_id: eventId, event_type: 'running_verified', by: RECONCILER,
          revision: newRevision
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// reconcileMarkLost: an OPEN generation whose live identity is provably gone/dead ->
// binding 'lost' + the audit-only `identity_lost` event (spec 491 "provably gone ->
// binding lost + identity_lost", the S3-deferred set). The generation stays open
// (status unchanged): losing the binding is NOT a terminal outcome - a later pass may
// escalate a still-lost generation to terminal `fail` (reconciler.mjs), or a respawn
// may supersede it. Requires an open generation still holding a live binding
// (bound_verified/bound_unverified); refuses on a run already lost, closed, or spawning
// so a double-loss pass-race is a silent no-op rather than a duplicate audit.
export async function reconcileMarkLost(store, params, { now = nowIso(), fault } = {}) {
  requireStr('reconcile-mark-lost', params.taskId, 'task_id');
  requireIntFlag('reconcile-mark-lost', params.generation, 'generation', { min: 1 });
  requireIntFlag('reconcile-mark-lost', params.expectedRevision, 'expected-revision');
  requireStr('reconcile-mark-lost', params.failingClause, 'failing-clause');

  const requestHash = sha256hex(canonicalJson({
    verb: 'reconcile-mark-lost', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision, failing_clause: params.failingClause,
    anomaly_class: params.anomalyClass ?? null
  }));

  return executeCommand(store, {
    verb: 'reconcile-mark-lost', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S5_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        'SELECT status, closed_at, binding_state, endpoint_id, pane_id FROM runs WHERE task_id = $1 AND run_generation = $2',
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
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'reconcile-mark-lost', params, Number(task.revision)));
      }
      if (run.status !== 'open' || run.closed_at !== null) {
        throw new StateTransitionError(
          `reconcile-mark-lost requires an open generation (run '${run.status}')`,
          { task_id: params.taskId, generation: params.generation, run_status: run.status }
        );
      }
      if (run.binding_state !== 'bound_verified' && run.binding_state !== 'bound_unverified') {
        throw new StateTransitionError(
          `reconcile-mark-lost requires a live binding (bound_verified/bound_unverified, got '${run.binding_state}')`,
          { task_id: params.taskId, generation: params.generation, binding_state: run.binding_state }
        );
      }

      await conn.query(
        "UPDATE runs SET binding_state = 'lost' WHERE task_id = $1 AND run_generation = $2",
        [params.taskId, params.generation]
      );
      const seq = await nextProducerSeq(conn, params.taskId, params.generation, RECONCILER);
      const eventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation, generationKey: params.generation,
        producer: RECONCILER, producerSeq: seq, eventType: 'identity_lost', isTerminal: false, outcome: null,
        payload: {
          endpoint_id: run.endpoint_id, pane_id: run.pane_id,
          failing_clause: params.failingClause, anomaly_class: params.anomalyClass ?? null
        },
        now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: RECONCILER,
        seq, commandId: ctx.commandId, now: ctx.now
      });

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        'UPDATE tasks SET revision = $1, updated_at = $2 WHERE task_id = $3 AND revision = $4 RETURNING revision',
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'reconcile-mark-lost', params, Number(task.revision)));
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, binding_state: 'lost',
          event_id: eventId, event_type: 'identity_lost', failing_clause: params.failingClause,
          revision: newRevision
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// reconcileMarkUnverified: an open, bound_verified generation whose probe failed
// TRANSIENTLY (the backend could not be reached, not a definitive absence) -> binding
// 'bound_unverified' (spec 491 "transient probe failure -> binding bound_unverified").
// A conservative demotion, not a loss: the endpoint may still be alive, so the run
// stays open and no identity_lost is emitted. A later pass re-verifies (reconcileReverify)
// on a live match or escalates to lost on a definitive failure. Requires a currently
// bound_verified open run; a run already bound_unverified is a silent no-op (idempotent
// pass, no counter noise).
export async function reconcileMarkUnverified(store, params, { now = nowIso(), fault } = {}) {
  requireStr('reconcile-mark-unverified', params.taskId, 'task_id');
  requireIntFlag('reconcile-mark-unverified', params.generation, 'generation', { min: 1 });
  requireIntFlag('reconcile-mark-unverified', params.expectedRevision, 'expected-revision');

  const requestHash = sha256hex(canonicalJson({
    verb: 'reconcile-mark-unverified', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision
  }));

  return executeCommand(store, {
    verb: 'reconcile-mark-unverified', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S5_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        'SELECT status, closed_at, binding_state FROM runs WHERE task_id = $1 AND run_generation = $2',
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
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'reconcile-mark-unverified', params, Number(task.revision)));
      }
      if (run.status !== 'open' || run.closed_at !== null || run.binding_state !== 'bound_verified') {
        throw new StateTransitionError(
          `reconcile-mark-unverified requires an open bound_verified generation (run '${run.status}', binding '${run.binding_state}')`,
          { task_id: params.taskId, generation: params.generation, run_status: run.status, binding_state: run.binding_state }
        );
      }

      await conn.query(
        "UPDATE runs SET binding_state = 'bound_unverified' WHERE task_id = $1 AND run_generation = $2",
        [params.taskId, params.generation]
      );

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        'UPDATE tasks SET revision = $1, updated_at = $2 WHERE task_id = $3 AND revision = $4 RETURNING revision',
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'reconcile-mark-unverified', params, Number(task.revision)));
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, binding_state: 'bound_unverified',
          revision: newRevision
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// reconcileReverify: an open, non-verified generation (bound_unverified OR lost) whose
// probe now matches -> back to 'bound_verified', emitting an audit-only `running_verified`
// under producer `reconciler`. The recovery half of the ladder: a transient blip must not
// permanently strand a live run at bound_unverified, and a binding that momentarily read
// 'lost' (e.g. a transient failure misclassified, or an interrupted loss pass) must be able
// to recover if the EXACT stored identity reappears (qa-s5-q64 finding 6 - no unhandled
// open/lost stable state). Re-probes the STORED identity at commit time - the same
// anti-ghost gate as promote - so a run is only re-verified against a genuine live match.
export async function reconcileReverify(store, params, { now = nowIso(), fault, probeIdentity = defaultProbeIdentity } = {}) {
  requireStr('reconcile-reverify', params.taskId, 'task_id');
  requireIntFlag('reconcile-reverify', params.generation, 'generation', { min: 1 });
  requireIntFlag('reconcile-reverify', params.expectedRevision, 'expected-revision');

  const requestHash = sha256hex(canonicalJson({
    verb: 'reconcile-reverify', task_id: params.taskId, generation: params.generation,
    expected_revision: params.expectedRevision
  }));

  return executeCommand(store, {
    verb: 'reconcile-reverify', commandId: params.commandId, requestHash, taskId: params.taskId, now, fault,
    conflictErrors: S5_CONFLICT_ERRORS,
    mutate: async (conn, ctx) => {
      const task = await readTask(conn, params.taskId);
      if (!task) throw new StateTransitionError(`unknown task: ${params.taskId}`, { task_id: params.taskId });
      const runQ = await conn.query(
        `SELECT status, closed_at, binding_state, endpoint_id, pane_id, pane_leader_pid, pane_start_ticks, boot_id,
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
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'reconcile-reverify', params, Number(task.revision)));
      }
      if (run.status !== 'open' || run.closed_at !== null
          || (run.binding_state !== 'bound_unverified' && run.binding_state !== 'lost')) {
        throw new StateTransitionError(
          `reconcile-reverify requires an open bound_unverified or lost generation (run '${run.status}', binding '${run.binding_state}')`,
          { task_id: params.taskId, generation: params.generation, run_status: run.status, binding_state: run.binding_state }
        );
      }

      const probe = await probeIdentity({ run: { ...run, task_id: params.taskId, run_generation: params.generation }, now: ctx.now });
      if (!probe || probe.matches !== true) {
        throw new ConflictSignal('identity', {
          anomalyClass: probe?.anomalyClass ?? 'identity_mismatch',
          taskId: params.taskId, runGeneration: params.generation,
          endpointId: run.endpoint_id, paneId: run.pane_id,
          agentPid: run.agent_pid, agentStartTicks: run.agent_start_ticks,
          terminalFingerprint: run.launch_marker,
          detail: {
            command_id: ctx.commandId, verb: 'reconcile-reverify', task_id: params.taskId,
            generation: params.generation, reason: 'identity_mismatch',
            failing_clause: probe?.failingClause ?? null
          }
        });
      }

      await conn.query(
        "UPDATE runs SET binding_state = 'bound_verified', verified_at = $3 WHERE task_id = $1 AND run_generation = $2",
        [params.taskId, params.generation, ctx.now]
      );
      const seq = await nextProducerSeq(conn, params.taskId, params.generation, RECONCILER);
      const eventId = await insertEvent(conn, {
        taskId: params.taskId, eventScope: 'run', runGeneration: params.generation, generationKey: params.generation,
        producer: RECONCILER, producerSeq: seq, eventType: 'running_verified', isTerminal: false, outcome: null,
        payload: { endpoint_id: run.endpoint_id, pane_id: run.pane_id, by: RECONCILER, reverify: true }, now: ctx.now
      });
      await upsertHighwater(conn, {
        taskId: params.taskId, runGeneration: params.generation, producer: RECONCILER,
        seq, commandId: ctx.commandId, now: ctx.now
      });

      const newRevision = params.expectedRevision + 1;
      const cas = await conn.query(
        'UPDATE tasks SET revision = $1, updated_at = $2 WHERE task_id = $3 AND revision = $4 RETURNING revision',
        [newRevision, ctx.now, params.taskId, params.expectedRevision]
      );
      if (cas.rows.length === 0) {
        throw new ConflictSignal('causal', causalAnomaly(ctx.commandId, 'reconcile-reverify', params, Number(task.revision)));
      }

      return {
        result: {
          task_id: params.taskId, generation: params.generation, binding_state: 'bound_verified',
          event_id: eventId, event_type: 'running_verified', by: RECONCILER, revision: newRevision
        },
        committedRevision: newRevision, domainChanged: true
      };
    }
  });
}

// recordReconcilerAnomaly: persist (or coalesce) one reconciler observation through the
// audit path. An anomaly is a canonical domain change that advances domain_revision and
// commit_sequence by exactly one WITHOUT touching any task revision (S1 finding-1
// contract), and coalesces by fingerprint on reobservation - occurrence_count + 1 and
// last_seen_at (spec 827). Unlike S3's ConflictSignal audit path (which writes NO
// command_results and so re-bumps on every replay), this is an ORDINARY committed
// mutation: it writes a command_results row keyed by the pass's deterministic command-id,
// so re-observing the SAME anomaly WITHIN a pass (same command-id) is an idempotent
// replay that bumps nothing, while re-observing it in a LATER pass (a fresh command-id)
// coalesces and bumps once - exactly the +1-domain/commit-per-persisted-or-coalesced
// contract with no counter noise on a crash-replayed pass.
//
// The reconciler NEVER kills or adopts: this only records what it observed. It optionally
// re-confirms the run's presence/state inside the transaction when `expectRunStatus` is
// given, so a stale outside read cannot fabricate an anomaly against a run that has
// already moved on.
export async function recordReconcilerAnomaly(store, params, { now = nowIso(), fault } = {}) {
  requireStr('record-anomaly', params.anomalyClass, 'anomaly-class');
  return executeCommand(store, {
    verb: 'reconcile-anomaly', commandId: params.commandId, requestHash: sha256hex(canonicalJson({
      verb: 'reconcile-anomaly', anomaly_class: params.anomalyClass, task_id: params.taskId ?? null,
      generation: params.generation ?? null, endpoint_id: params.endpointId ?? null, pane_id: params.paneId ?? null,
      agent_pid: params.agentPid ?? null, agent_start_ticks: params.agentStartTicks ?? null,
      terminal_fingerprint: params.terminalFingerprint ?? null, detail: params.detail ?? {}
    })), taskId: params.taskId ?? null, now, fault,
    mutate: async (conn, ctx) => {
      const fingerprint = await recordAnomaly(conn, {
        homeUuid: ctx.homeUuid, anomalyClass: params.anomalyClass, taskId: params.taskId ?? null,
        runGeneration: params.generation ?? null, endpointId: params.endpointId ?? null,
        paneId: params.paneId ?? null, agentPid: params.agentPid ?? null,
        agentStartTicks: params.agentStartTicks ?? null, terminalFingerprint: params.terminalFingerprint ?? null,
        detail: params.detail ?? {}
      }, ctx.now);
      return {
        result: { fingerprint, anomaly_class: params.anomalyClass, by: RECONCILER },
        committedRevision: null, domainChanged: true
      };
    }
  });
}

// Classes whose resolution predicate depends on a canonical surface this slice does NOT
// own (S4 consumer/ack/lease, S6 projections). S5 cannot verify their spec-830-840
// predicate, so it refuses to resolve them rather than falsely blessing them; the owning
// slice's resolver handles them.
const OUT_OF_SLICE_ANOMALY_CLASSES = new Set([
  'stale_projection', 'duplicate_projection', 'sink_idempotency_unknown', 'consumer_lease_conflict'
]);

// The spec-830-840 resolution predicate dispatcher (qa-s5-q64 finding 3). Given the FULL
// anomaly row and the requested resolution, it verifies - in the SAME transaction, against
// the canonical rows - that the class-specific precondition actually holds before the row
// may be marked resolved. Returns { ok } or { ok:false, message, detail }. It never
// mutates; resolveAnomaly performs the update only when ok. A class with no spec predicate
// (the reconciler's own remediable observations: missing_pane, identity_mismatch,
// pid_reuse_suspected, binding_lost_under_active, running_without_verification,
// launch_marker_*, datadir_size_tripwire) resolves on agent authority with a reason.
// detail_json comes back parsed on most drivers; tolerate a text form too. Never throws -
// an unparseable detail simply yields {} so a predicate that needs a fact treats it absent.
function coerceDetail(detailJson) {
  if (detailJson === null || detailJson === undefined) return {};
  if (typeof detailJson !== 'string') return detailJson;
  try {
    return JSON.parse(detailJson);
  } catch {
    return {};
  }
}

async function resolutionPredicate(conn, anomaly, params) {
  const cls = anomaly.anomaly_class;

  if (cls === 'orphan_pane') {
    // spec 834/835. terminal_fingerprint holds the pane's marker (null == markerless).
    if (anomaly.terminal_fingerprint === null || anomaly.terminal_fingerprint === undefined) {
      // markerless/ambiguous orphan: captain-routed, human-approved ONLY (ruling Q4). This
      // slice never kills it.
      if (params.resolutionKind !== 'human_approved') {
        return { ok: false, message: "markerless/ambiguous orphan_pane is captain-routed; resolve only with resolution-kind 'human_approved'", detail: { resolution_kind: params.resolutionKind } };
      }
      return { ok: true };
    }
    // marker-bearing orphan (spec 834): resolved by SAFE ADOPTION into the matching run, or
    // by EXACT CLEANUP after TERMINAL FAILURE. Safe adoption requires the marker's run to be
    // bound_verified with the FULL endpoint+pane identity the orphan named (not endpoint_id
    // alone); the cleanup alternative requires a FAILED (not completed) run that is cleaned.
    const r = await conn.query(
      'SELECT status, binding_state, cleanup_state, endpoint_id, pane_id FROM runs WHERE launch_marker = $1',
      [anomaly.terminal_fingerprint]
    );
    if (r.rows.length === 0) {
      return { ok: false, message: 'marker-bearing orphan_pane has no matching run to adopt or clean; not safely resolvable in this slice', detail: { marker: anomaly.terminal_fingerprint } };
    }
    const run = r.rows[0];
    const adopted = run.binding_state === 'bound_verified'
      && run.endpoint_id !== null && run.endpoint_id === anomaly.endpoint_id
      && run.pane_id !== null && run.pane_id === anomaly.pane_id;
    const exactlyCleanedAfterFailure = run.status === 'failed' && run.cleanup_state === 'cleaned';
    if (!adopted && !exactlyCleanedAfterFailure) {
      return { ok: false, message: 'marker-bearing orphan_pane is neither safely adopted (bound_verified with matching endpoint+pane) nor exactly cleaned after terminal failure', detail: { run_status: run.status, binding_state: run.binding_state, cleanup_state: run.cleanup_state, endpoint_match: run.endpoint_id === anomaly.endpoint_id, pane_match: run.pane_id === anomaly.pane_id } };
    }
    return { ok: true };
  }

  if (cls === 'terminal_without_cleanup') {
    // spec 836: resolved by cleanup-finish OR confirmed already-absent under a committed
    // cleanup intent. Verify the run reached a cleaned/closed state; a run still
    // cleanup_pending with cleanup not finished is NOT resolvable.
    const r = await conn.query(
      'SELECT binding_state, cleanup_state FROM runs WHERE task_id = $1 AND run_generation = $2',
      [anomaly.task_id, anomaly.run_generation]
    );
    if (r.rows.length === 0) {
      return { ok: false, message: 'terminal_without_cleanup names no such run', detail: { task_id: anomaly.task_id, generation: anomaly.run_generation } };
    }
    const run = r.rows[0];
    const cleaned = run.cleanup_state === 'cleaned' || run.binding_state === 'closed';
    if (!cleaned) {
      return { ok: false, message: 'terminal_without_cleanup cannot be resolved while cleanup is unfinished (require cleanup-finish or confirmed-absent under a committed intent)', detail: { binding_state: run.binding_state, cleanup_state: run.cleanup_state } };
    }
    return { ok: true };
  }

  if (cls === 'terminal_conflict') {
    // spec 832: the WHOLE canonical chain must hold - one canonical terminal event, its
    // outbox row ACKED, cleanup cleaned, AND the conflicting command deterministically
    // rejected with no domain mutation. Not merely "a terminal event exists".
    const tev = await conn.query(
      "SELECT event_id FROM task_events WHERE task_id = $1 AND run_generation = $2 AND is_terminal",
      [anomaly.task_id, anomaly.run_generation]
    );
    if (tev.rows.length !== 1) {
      return { ok: false, message: 'terminal_conflict requires exactly one canonical terminal event for the generation', detail: { terminal_events: tev.rows.length } };
    }
    const ob = await conn.query(
      'SELECT acked_at FROM outbox WHERE event_id = $1', [tev.rows[0].event_id]
    );
    if (ob.rows.length !== 1) {
      return { ok: false, message: 'terminal_conflict: the canonical terminal has no outbox delivery row', detail: {} };
    }
    if (ob.rows[0].acked_at === null || ob.rows[0].acked_at === undefined) {
      return { ok: false, message: 'terminal_conflict: the canonical terminal delivery is not yet acked', detail: {} };
    }
    const run = await conn.query(
      'SELECT binding_state, cleanup_state FROM runs WHERE task_id = $1 AND run_generation = $2',
      [anomaly.task_id, anomaly.run_generation]
    );
    if (run.rows.length !== 1 || !(run.rows[0].cleanup_state === 'cleaned' || run.rows[0].binding_state === 'closed')) {
      return { ok: false, message: 'terminal_conflict: cleanup for the generation is not complete', detail: run.rows[0] || {} };
    }
    // The conflicting command must be deterministically rejected with NO domain mutation:
    // a rejected/audited command leaves NO command_results row (an idempotency/replay row
    // would mean it committed something).
    const detail = coerceDetail(anomaly.detail_json);
    const conflictingId = detail.command_id;
    if (!conflictingId) {
      return { ok: false, message: 'terminal_conflict anomaly lacks the conflicting command_id; the rejected-command fact cannot be verified', detail: {} };
    }
    const cr = await conn.query('SELECT 1 FROM command_results WHERE command_id = $1', [conflictingId]);
    if (cr.rows.length !== 0) {
      return { ok: false, message: 'terminal_conflict: the conflicting command left a committed result (a domain mutation), so it was not a clean rejection', detail: { command_id: conflictingId } };
    }
    return { ok: true };
  }

  if (cls === 'idempotency_conflict') {
    // spec 833: the offending command key must have a DETERMINISTIC STORED result and the
    // conflict must be real (a different incoming payload), and the offending reuse caused
    // no new domain mutation (the stored result is the FIRST use's, unchanged).
    const detail = coerceDetail(anomaly.detail_json);
    if (!detail.command_id || !detail.stored_request_hash || !detail.incoming_request_hash) {
      return { ok: false, message: 'idempotency_conflict anomaly lacks the command key/request-hash facts; not verifiable', detail: {} };
    }
    if (detail.stored_request_hash === detail.incoming_request_hash) {
      return { ok: false, message: 'idempotency_conflict is not a real conflict (stored and incoming request hashes match)', detail: {} };
    }
    const cr = await conn.query('SELECT request_hash FROM command_results WHERE command_id = $1', [detail.command_id]);
    if (cr.rows.length !== 1) {
      return { ok: false, message: 'idempotency_conflict: the command key has no stored deterministic result', detail: { command_id: detail.command_id } };
    }
    if (cr.rows[0].request_hash !== detail.stored_request_hash) {
      return { ok: false, message: 'idempotency_conflict: the stored result no longer matches the recorded stored_request_hash; not deterministically replaying', detail: { command_id: detail.command_id } };
    }
    return { ok: true };
  }

  if (cls === 'causal_ordering_violation') {
    // spec 833: the offending command must have a DETERMINISTIC REJECTED result (a replay
    // re-rejects on the same stale causal fact) and have caused NO domain mutation (no
    // command_results row for it).
    const detail = coerceDetail(anomaly.detail_json);
    if (!detail.command_id || !detail.reason) {
      return { ok: false, message: 'causal_ordering_violation anomaly lacks the command key/causal facts; a fabricated or unverifiable row is not resolvable', detail: {} };
    }
    const cr = await conn.query('SELECT 1 FROM command_results WHERE command_id = $1', [detail.command_id]);
    if (cr.rows.length !== 0) {
      return { ok: false, message: 'causal_ordering_violation: the offending command left a committed result (a domain mutation occurred)', detail: { command_id: detail.command_id } };
    }
    if (detail.reason === 'stale_revision') {
      if (!Number.isInteger(detail.expected_revision) || anomaly.task_id === null) {
        return { ok: false, message: 'causal_ordering_violation (stale_revision) lacks the expected_revision/task facts', detail: {} };
      }
      const t = await conn.query('SELECT revision FROM tasks WHERE task_id = $1', [anomaly.task_id]);
      if (t.rows.length !== 1 || Number(t.rows[0].revision) <= detail.expected_revision) {
        return { ok: false, message: 'causal_ordering_violation (stale_revision) is not deterministically rejecting: the task revision has not advanced past the offending token', detail: { task_id: anomaly.task_id, expected_revision: detail.expected_revision, current_revision: t.rows[0] ? Number(t.rows[0].revision) : null } };
      }
      return { ok: true };
    }
    if (detail.reason === 'nonmonotonic_producer_seq') {
      if (!detail.producer || !Number.isInteger(detail.seq) || anomaly.task_id === null) {
        return { ok: false, message: 'causal_ordering_violation (nonmonotonic_producer_seq) lacks the producer/seq facts', detail: {} };
      }
      const hw = await conn.query(
        'SELECT last_seq FROM producer_highwater WHERE task_id = $1 AND run_generation = $2 AND producer_id = $3',
        [anomaly.task_id, anomaly.run_generation === null ? -1 : anomaly.run_generation, detail.producer]
      );
      if (hw.rows.length !== 1 || Number(hw.rows[0].last_seq) < detail.seq) {
        return { ok: false, message: 'causal_ordering_violation (nonmonotonic_producer_seq) is not deterministically rejecting: the producer high-water is not at/above the offending seq', detail: { producer: detail.producer, seq: detail.seq } };
      }
      return { ok: true };
    }
    return { ok: false, message: `causal_ordering_violation has an unrecognized reason '${detail.reason}'; not verifiable`, detail: {} };
  }

  if (OUT_OF_SLICE_ANOMALY_CLASSES.has(cls)) {
    return { ok: false, message: `anomaly class '${cls}' has a resolution predicate owned by another slice (S4 consumer/ack/lease or S6 projections); not resolvable in S5`, detail: { anomaly_class: cls } };
  }

  // A reconciler observation class with no spec-830-840 predicate: agent-level resolution
  // (a valid resolution-kind and a reason) suffices - the operator explains/remediates it.
  return { ok: true };
}

// resolveAnomaly: flip an active anomaly to 'resolved' in place (spec 597/828 - the row
// is preserved, never deleted). An ordinary audited mutation (+1 domain/commit, no task
// revision) guarded by the class-specific spec-830-840 resolution predicates
// (resolutionPredicate). The markerless/ambiguous-orphan human_approved gate (ruling Q4)
// is ONE of those predicates, applied ONLY to markerless orphans, never to every class.
// Every refusal is a non-audited AnomalyResolutionError that persists nothing.
export async function resolveAnomaly(store, params, { now = nowIso(), fault } = {}) {
  requireStr('resolve-anomaly', params.fingerprint, 'fingerprint');
  requireStr('resolve-anomaly', params.reason, 'reason');
  requireStr('resolve-anomaly', params.resolutionKind, 'resolution-kind');
  if (!RESOLUTION_KINDS.has(params.resolutionKind)) {
    throw new AnomalyResolutionError(
      `--resolution-kind must be one of ${[...RESOLUTION_KINDS].join(', ')}`,
      { resolution_kind: params.resolutionKind }
    );
  }

  const requestHash = sha256hex(canonicalJson({
    verb: 'resolve-anomaly', fingerprint: params.fingerprint,
    reason: params.reason, resolution_kind: params.resolutionKind
  }));

  return executeCommand(store, {
    verb: 'resolve-anomaly', commandId: params.commandId, requestHash, taskId: null, now, fault,
    mutate: async (conn, ctx) => {
      const q = await conn.query(
        `SELECT anomaly_class, status, task_id, run_generation, endpoint_id, pane_id,
                terminal_fingerprint, detail_json
           FROM anomalies WHERE fingerprint = $1`,
        [params.fingerprint]
      );
      if (q.rows.length === 0) {
        throw new AnomalyResolutionError(
          'unknown anomaly fingerprint; nothing to resolve', { fingerprint: params.fingerprint }
        );
      }
      const anomaly = q.rows[0];
      if (anomaly.status === 'resolved') {
        throw new AnomalyResolutionError(
          'anomaly is already resolved; resolved rows are preserved, never re-resolved',
          { fingerprint: params.fingerprint, anomaly_class: anomaly.anomaly_class }
        );
      }
      // Class-specific spec-830-840 predicate: the canonical precondition must actually
      // hold before the row may be resolved.
      const verdict = await resolutionPredicate(conn, anomaly, params);
      if (!verdict.ok) {
        throw new AnomalyResolutionError(verdict.message, {
          fingerprint: params.fingerprint, anomaly_class: anomaly.anomaly_class, ...verdict.detail
        });
      }

      await conn.query(
        "UPDATE anomalies SET status = 'resolved', resolution_kind = $2, resolved_reason = $3, resolved_at = $4 WHERE fingerprint = $1",
        [params.fingerprint, params.resolutionKind, params.reason, ctx.now]
      );
      return {
        result: {
          fingerprint: params.fingerprint, anomaly_class: anomaly.anomaly_class, status: 'resolved',
          resolution_kind: params.resolutionKind, resolved_reason: params.reason
        },
        committedRevision: null, domainChanged: true
      };
    }
  });
}

// listAnomalies: locked READ of the anomalies ledger (spec 596). No command-id, no
// counter bump. `--active` narrows to still-open anomalies.
export async function listAnomalies(store, { activeOnly = false } = {}) {
  return runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    const present = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'anomalies'"
    );
    if (present.rows.length === 0) return { anomalies: [] };
    const where = activeOnly ? "WHERE status = 'active'" : '';
    const r = await conn.query(
      `SELECT fingerprint, anomaly_class, task_id, run_generation, endpoint_id, pane_id, agent_pid,
              agent_start_ticks, terminal_fingerprint, status, resolution_kind, resolved_reason,
              occurrence_count, first_seen_at, last_seen_at, resolved_at, detail_json
         FROM anomalies ${where}
         ORDER BY status, last_seen_at DESC, fingerprint`
    );
    return {
      anomalies: r.rows.map((a) => ({
        ...a,
        run_generation: a.run_generation === null ? null : Number(a.run_generation),
        agent_pid: a.agent_pid === null ? null : Number(a.agent_pid),
        agent_start_ticks: a.agent_start_ticks === null ? null : Number(a.agent_start_ticks),
        occurrence_count: Number(a.occurrence_count),
        detail: typeof a.detail_json === 'string' ? JSON.parse(a.detail_json) : a.detail_json
      }))
    };
  });
}

export { RECONCILER, RESOLUTION_KINDS };
