import fs from 'node:fs';
import path from 'node:path';
import { runExclusive } from './internal-runtime.mjs';
import { withFlock } from './flock.mjs';
import { ValidationError } from './errors.mjs';
import { CausalOrderingError, StateTransitionError } from './errors-s1.mjs';
import { TerminalConflictError } from './errors-s2.mjs';
import { IdentityMismatchError } from './errors-s3.mjs';
import { ensureInitialized } from './domain-store.mjs';
import { failRun } from './domain-store-s2.mjs';
import { cleanupTargetMatches as realCleanupTargetMatches } from './tmux-adapter.mjs';
import { scanIsolatedSocket, probeIdentityTransientAware } from './backend-scan-s5.mjs';
import {
  reconcilePromote, reconcileMarkLost, reconcileMarkUnverified, reconcileReverify,
  recordReconcilerAnomaly, RECONCILER
} from './domain-store-s5.mjs';

// The reconciler PASS (spec 789-840, 491-492). One bounded, idempotent, flock-serialized
// sweep that reconciles the persisted control-plane state against live backend identity
// and audits every divergence. There is NO daemon and NO timer in-slice: the production
// 30s cadence is FirstMate-owned wiring at cutover (spec 791). A pass:
//
//   (a) promotes a verified spawning generation to running (the reconciler's idempotent
//       commit-running, anti-ghost gate at commit time);
//   (b) fails a partial launch past its launch deadline via the sanctioned S2 fail path;
//   (c) demotes a transiently-unreachable binding to bound_unverified, re-verifies a
//       recovered one, marks a provably-gone binding lost + emits identity_lost, and
//       escalates a still-lost generation to a terminal S2 fail;
//   (d) audits every anomaly class - orphan_pane, missing_pane, identity_mismatch,
//       pid_reuse_suspected, binding_lost_under_active, running_without_verification,
//       terminal_without_cleanup, launch_marker_duplicate, launch_marker_missing,
//       datadir_size_tripwire - coalescing reobservations by fingerprint;
//   (e) NEVER kills, deletes, adopts an orphan, or reads projections (spec 797).
//
// STRUCTURE. The pass runs in three phases so its per-item commits stay small and its
// crash recovery is trivial. It (1) SNAPSHOTS every candidate run under one locked read,
// (2) DECIDES each item's action by probing LIVE identity through the injected seam
// OUTSIDE any lock (the real tmux/proc probe by default; deterministic fixtures in
// tests), and (3) COMMITS each decided action as its OWN ordinary envelope mutation with
// a deterministic per-pass command-id and a CAS on the run's snapshot revision. Each
// promotion re-probes INSIDE its transaction (the anti-ghost gate), so a stale outside
// read can never ghost a dead endpoint. A committed change is exactly the S1 envelope's
// +1 tasks.revision / +1 domain / +1 commit; an anomaly-only observation is +1 domain/
// commit through the audit path; a pass that changes nothing commits nothing. Because
// each action is its own atomic transaction with a deterministic command-id, a crash
// mid-pass leaves earlier commits durable and a rerun replays them idempotently and
// finishes the rest - never a duplicate.

const DEFAULT_TERMINAL_CLEANUP_GRACE_MS = 300000; // 5 min: a just-terminal run is not yet "without cleanup"
const DEFAULT_DATADIR_LIMIT_BYTES = 1024 * 1024 * 1024; // 1 GiB tripwire (spec 817)

function nowIso() {
  return new Date().toISOString();
}

// The snapshot row already carries every column the S3 probes read (boot_id,
// pane_leader_pid, pane_start_ticks, agent_*, endpoint_id, pane_id, launch_marker) plus
// task_id and run_generation, so a probe input is the row itself. Kept as a named seam so
// a probe never sees pass-internal fields it should not.
function probeRun(run) {
  return run;
}

function defaultSocket() {
  return process.env.CP_TMUX_SOCKET || 'cp-default';
}
// The production identity probe is transient-AWARE (qa-s5-q64 finding 4): it reports a
// transient/backend-unverified result when the isolated tmux server is unreachable,
// distinct from a definitive absence the server proves. That distinction is what lets the
// reconciler demote to bound_unverified rather than declaring a live binding lost.
function defaultProbeIdentity(arg) {
  return probeIdentityTransientAware({ ...arg, socket: defaultSocket() });
}
function defaultCleanupProbe(arg) {
  return realCleanupTargetMatches({ ...arg, socket: defaultSocket() });
}
// The PRODUCTION marker scan reads the isolated cp tmux socket for marker-bearing launch
// endpoints (qa-s5-q64 finding 1; spec 795), reading each pane leader's CP_LAUNCH_MARKER
// live from /proc environ. It returns null when the backend is unreachable - "no scan
// available" - DELIBERATELY distinct from an empty array ("scanned, found zero panes"): a
// null scan skips marker reconciliation entirely, so an unreachable socket never mistakes
// an un-performed scan for "every known run's marker has vanished" and never flags a
// spurious launch_marker_missing. A markerless or unknown-marker pane a reachable server
// DOES list becomes a real orphan. The real scan is exercised end to end in the
// tmux-guarded s5 smoke; domain tests inject deterministic arrays.
function defaultScanMarkers() {
  return scanIsolatedSocket(defaultSocket());
}
function defaultDatadirSize(store) {
  try {
    const stat = fs.statSync(store.dataDir);
    return stat.isDirectory() ? dirSize(store.dataDir) : stat.size;
  } catch {
    return 0;
  }
}
function dirSize(dir) {
  let total = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = `${dir}/${entry.name}`;
    try {
      if (entry.isDirectory()) total += dirSize(full);
      else total += fs.statSync(full).size;
    } catch {
      // a file that vanished mid-walk contributes nothing
    }
  }
  return total;
}

// A raced-away action: the world moved under the pass between snapshot and commit (the
// coordinator promoted the run, a terminal already landed, the identity flipped). These
// are EXPECTED and benign - the pass records the item as skipped and the next pass
// reconciles it - so they never abort the whole sweep. A genuine fault does.
function isRaceConflict(err) {
  return err instanceof CausalOrderingError
    || err instanceof StateTransitionError
    || err instanceof TerminalConflictError
    || err instanceof IdentityMismatchError;
}

// Map the S3 identity-probe result to a reconciler disposition for an OPEN generation.
// A transient failure (the probe could not reach the backend, or the stored binding is
// incomplete) is recoverable -> bound_unverified; a definitive failure (pane/agent gone,
// a foreign identity, a reused pid) is a provable loss -> lost + identity_lost.
function openDisposition(probe) {
  if (probe && probe.matches === true) return { disp: 'alive' };
  if (probe && probe.transient === true) {
    return { disp: 'transient', anomalyClass: 'running_without_verification', failingClause: probe.failingClause || 'backend_unreachable' };
  }
  if (probe && probe.anomalyClass === 'running_without_verification') {
    // An incomplete stored binding cannot be proven dead: treat it as transient/unverified.
    return { disp: 'transient', anomalyClass: 'running_without_verification', failingClause: probe.failingClause || 'incomplete_binding' };
  }
  return {
    disp: 'gone',
    anomalyClass: (probe && probe.anomalyClass) || 'missing_pane',
    failingClause: (probe && probe.failingClause) || 'endpoint_absent'
  };
}

// SNAPSHOT: one locked read of every candidate run plus the task status/revision and the
// reconciler's own producer high-water for the generation (used to derive the seq of a
// reconciler-authored terminal fail, which is caller-supplied on the S2 fail path). A
// candidate is any run that is still spawning, still open, or terminal-but-still-pending
// cleanup; a fully closed generation is nothing to reconcile.
async function snapshotCandidates(store, taskId) {
  return runExclusive(store, async (conn) => {
    await ensureInitialized(conn);
    const present = await conn.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'runs'"
    );
    if (present.rows.length === 0) return [];
    const params = [];
    let filter = "(r.status = 'spawning' OR r.status = 'open' OR r.binding_state = 'cleanup_pending')";
    if (taskId) {
      params.push(taskId);
      filter = `r.task_id = $1 AND ${filter}`;
    }
    const r = await conn.query(
      `SELECT r.task_id, r.run_generation, r.status AS run_status, r.binding_state, r.cleanup_state,
              r.endpoint_id, r.pane_id, r.pane_leader_pid, r.pane_start_ticks, r.boot_id,
              r.agent_pid, r.agent_start_ticks, r.agent_exe, r.agent_argv_hash, r.agent_ppid, r.agent_pty,
              r.launch_marker, r.launch_deadline_at, r.closed_at,
              t.status AS task_status, t.revision AS task_revision,
              COALESCE(hw.last_seq, 0) AS reconciler_seq
         FROM runs r
         JOIN tasks t ON t.task_id = r.task_id
         LEFT JOIN producer_highwater hw
           ON hw.task_id = r.task_id AND hw.run_generation = r.run_generation AND hw.producer_id = '${RECONCILER}'
         WHERE ${filter}
         ORDER BY r.task_id, r.run_generation`,
      params
    );
    return r.rows.map((row) => ({
      ...row,
      run_generation: Number(row.run_generation),
      task_revision: Number(row.task_revision),
      reconciler_seq: Number(row.reconciler_seq)
    }));
  });
}

// reconcilePass: run one bounded, idempotent, flock-serialized reconcile pass. `nonce` is
// REQUIRED and is the pass's deterministic identity: every command-id it derives is
// `<nonce>:<...>`, so re-running a crashed pass with the SAME nonce replays each already-
// committed action idempotently and completes the rest, while two concurrent passes with
// the same nonce dedupe on the envelope's command-id and two with different nonces resolve
// on the revision CAS - exactly one promotion either way. Every probe seam is injectable;
// the production defaults use the isolated cp tmux socket and never touch a production one.
export async function reconcilePass(store, {
  taskId = null,
  now = nowIso(),
  deadlineNow = now,
  nonce,
  probeIdentity = defaultProbeIdentity,
  cleanupProbe = defaultCleanupProbe,
  scanMarkers = defaultScanMarkers,
  datadirSize = defaultDatadirSize,
  datadirLimitBytes = DEFAULT_DATADIR_LIMIT_BYTES,
  terminalCleanupGraceMs = DEFAULT_TERMINAL_CLEANUP_GRACE_MS,
  passLockPath = null,
  passLockTimeoutMs = 30000,
  onPhase = null,
  faultAfterCommit = null
} = {}) {
  if (typeof nonce !== 'string' || nonce.length === 0) {
    throw new ValidationError('reconcile pass requires a non-empty nonce (its deterministic per-pass command-id root)');
  }
  const fleetWide = !taskId;
  // WHOLE-PASS SERIALIZATION (qa-s5-q64 finding 2; spec 792 "the flock makes passes
  // non-overlapping"). A dedicated pass-level flock is held from snapshot through the last
  // commit, so two reconcile passes can never run their probe/decide phases concurrently.
  // It is a SEPARATE lock file from the per-command store flock (`<pgdata>.lock`), so the
  // per-item transactions inside the pass acquire the store lock without deadlocking on
  // this one, and coordinator commands - which take only the store lock - still interleave
  // per-operation. Two passes contend on THIS lock and serialize as whole passes.
  const passLock = passLockPath || path.join(path.dirname(store.dataDir), 'cp-reconcile-pass.lock');
  return withFlock(passLock, () => runPassBody(), { timeoutMs: passLockTimeoutMs, exclusive: true });

  async function runPassBody() {
  if (typeof onPhase === 'function') await onPhase('snapshot');
  const snapshot = await snapshotCandidates(store, taskId);
  if (typeof onPhase === 'function') await onPhase('decide');

  // ---- DECIDE (probe live identity OUTSIDE any lock) ----
  const actions = [];
  for (const run of snapshot) {
    const tag = `${run.task_id}:${run.run_generation}`;
    if (run.run_status === 'spawning') {
      const deadlineExpired = new Date(deadlineNow).getTime() > new Date(run.launch_deadline_at).getTime();
      if (run.endpoint_id === null) {
        // A spawning generation that never recorded a spawn is a partial launch once its
        // launch window has elapsed; within the window it is still legitimately launching.
        if (deadlineExpired) actions.push(failAction(run, `${nonce}:${tag}:partial-launch`, 'never_recorded_spawn'));
        continue;
      }
      const probe = await probeIdentity({ run: probeRun(run), now });
      if (probe && probe.matches === true) {
        actions.push(promoteAction(run, `${nonce}:${tag}:promote`, probeIdentity));
      } else if (deadlineExpired) {
        actions.push(failAction(run, `${nonce}:${tag}:partial-launch`, 'identity_unverified_past_deadline'));
      }
      // else: unmatched but still inside the launch window -> leave it spawning.
      continue;
    }
    if (run.run_status === 'open') {
      const probe = await probeIdentity({ run: probeRun(run), now });
      const { disp, anomalyClass, failingClause } = openDisposition(probe);
      if (disp === 'alive') {
        // A live match RE-VERIFIES a binding that is not currently verified - recovering
        // both a transiently-demoted binding AND a stranded 'lost' one back to
        // bound_verified, so open/lost is never a permanent stable state (finding 6).
        if (run.binding_state === 'bound_unverified' || run.binding_state === 'lost') {
          actions.push(reverifyAction(run, `${nonce}:${tag}:reverify`, probeIdentity));
        }
        // bound_verified + alive: nothing to commit.
      } else if (disp === 'transient') {
        // A transient probe failure demotes a live binding to bound_unverified AND authors
        // a running_without_verification anomaly explaining why the live binding became
        // unverified (finding 5). Anomaly first, then the transition.
        if (run.binding_state === 'bound_verified') {
          actions.push(anomalyAction(run, `${nonce}:${tag}:unverified-anomaly`, {
            anomalyClass: 'running_without_verification', failingClause
          }));
          actions.push(unverifyAction(run, `${nonce}:${tag}:unverify`));
        }
        // already bound_unverified / lost: no-op (a transient failure cannot prove death).
      } else { // gone: a provably dead open generation
        // The reconciler audits the specific identity failure AND the binding_lost_under_active
        // alert, then - in the SAME pass - emits identity_lost (binding -> lost) and terminally
        // fails the generation through the sanctioned S2 fail path, never leaving it open/lost
        // (finding 6, spec 491). A binding already lost from an interrupted prior pass just needs
        // the terminal escalation (its identity_lost already committed).
        actions.push(anomalyAction(run, `${nonce}:${tag}:loss-observed`, { anomalyClass, failingClause }));
        actions.push(anomalyAction(run, `${nonce}:${tag}:lost-under-active`, {
          anomalyClass: 'binding_lost_under_active', failingClause, probeClass: anomalyClass
        }));
        if (run.binding_state === 'lost') {
          actions.push(failAction(run, `${nonce}:${tag}:terminal`, `provably_dead:${failingClause}`, run.reconciler_seq + 1));
        } else {
          actions.push(failLostAction(run, `${nonce}:${tag}:lost-fail`, failingClause, anomalyClass));
        }
      }
      continue;
    }
    // cleanup_pending (terminal run still holding an endpoint to clean).
    if (run.binding_state === 'cleanup_pending') {
      if (run.cleanup_state === 'not_started' && terminalWithoutCleanup(run, deadlineNow, terminalCleanupGraceMs)) {
        actions.push(anomalyAction(run, `${nonce}:${tag}:terminal-without-cleanup`, {
          anomalyClass: 'terminal_without_cleanup', failingClause: 'cleanup_never_started'
        }));
      }
      const probe = await cleanupProbe({ run: probeRun(run) });
      if (probe && probe.present === true && probe.matches === false) {
        // The stored cleanup target is present but its identity disagrees. Coalesce with
        // the identity_mismatch class S3's cleanup-mismatch verb already owns (same class,
        // same fingerprint inputs) - do NOT duplicate it - and NEVER kill.
        actions.push(cleanupMismatchAnomalyAction(run, `${nonce}:${tag}:cleanup-mismatch`, probe.reason ?? null));
      }
    }
  }

  // ---- fleet-wide observations (only on an unfiltered pass) ----
  if (fleetWide) {
    const scanned = scanMarkers();
    // Only reconcile markers when a scan was actually performed (an array, possibly
    // empty). A null result means the cp socket could not be scanned - skip entirely.
    if (Array.isArray(scanned)) {
      for (const spec of markerScanSpecs(snapshot, scanned, nonce)) actions.push(anomalySpecAction(spec));
    }
    const size = await datadirSize(store);
    if (typeof size === 'number' && size > datadirLimitBytes) {
      actions.push(anomalySpecAction({
        key: `${nonce}:datadir`, kind: 'datadir_size_tripwire', taskId: null, generation: null,
        anomaly: {
          anomalyClass: 'datadir_size_tripwire', terminalFingerprint: 'datadir',
          detail: { size_bytes: size, limit_bytes: datadirLimitBytes }
        }
      }));
    }
  }

  // ---- COMMIT (each action its own atomic transaction, deterministic command-id) ----
  const committed = [];
  const skipped = [];
  for (let i = 0; i < actions.length; i += 1) {
    const act = actions[i];
    try {
      const result = await act.run(act.key);
      committed.push({ kind: act.kind, taskId: act.taskId, generation: act.generation, result });
    } catch (err) {
      if (!isRaceConflict(err)) throw err;
      skipped.push({ kind: act.kind, taskId: act.taskId, generation: act.generation, reason: err.code || err.name });
    }
    // Test-only crash injection BETWEEN per-item commits (already committed above): a
    // hard exit here proves a rerun with the same nonce replays committed items and
    // finishes the rest without duplicates.
    if (typeof faultAfterCommit === 'function') faultAfterCommit(i);
  }

  return { nonce, task_id: taskId, candidates: snapshot.length, committed, skipped };
  }

  // ---- action builders (closures over the pass's stores/probes) ----
  function promoteAction(run, key, probe) {
    return {
      key, kind: 'promote', taskId: run.task_id, generation: run.run_generation,
      run: (commandId) => reconcilePromote(store, {
        taskId: run.task_id, generation: run.run_generation, expectedRevision: run.task_revision, commandId
      }, { now, probeIdentity: probe })
    };
  }
  function failAction(run, key, reason, seq = run.reconciler_seq + 1) {
    return {
      key, kind: 'fail', taskId: run.task_id, generation: run.run_generation,
      run: (commandId) => failRun(store, {
        taskId: run.task_id, generation: run.run_generation, expectedRevision: run.task_revision,
        reason: `reconciler: ${reason}`, producer: RECONCILER, seq, commandId
      }, { now })
    };
  }
  // Compound one-pass loss-and-terminal (finding 6, spec 491): emit identity_lost (binding
  // -> lost, revision R -> R+1), then terminally fail the provably-dead generation through
  // the S2 fail path (R+1 -> R+2) with the reconciler's next two producer seqs. The two
  // sub-commands carry distinct deterministic command-ids so a crash between them replays
  // cleanly; and if a crash lands after the identity_lost but before the terminal, the next
  // pass sees binding 'lost' + still-gone and escalates via failAction. The failRun's
  // expected-revision is threaded from the mark-lost result, so a coordinator that raced in
  // between makes the terminal a benign skip that the next pass reconciles.
  function failLostAction(run, key, failingClause, anomalyClass) {
    return {
      key, kind: 'fail_lost', taskId: run.task_id, generation: run.run_generation,
      run: async (commandId) => {
        const lost = await reconcileMarkLost(store, {
          taskId: run.task_id, generation: run.run_generation, expectedRevision: run.task_revision,
          failingClause, anomalyClass, commandId: `${commandId}:lost`
        }, { now });
        const failed = await failRun(store, {
          taskId: run.task_id, generation: run.run_generation, expectedRevision: lost.revision,
          reason: `reconciler: provably_dead:${failingClause}`, producer: RECONCILER,
          seq: run.reconciler_seq + 2, commandId: `${commandId}:fail`
        }, { now });
        return { lost, failed };
      }
    };
  }
  function unverifyAction(run, key) {
    return {
      key, kind: 'mark_unverified', taskId: run.task_id, generation: run.run_generation,
      run: (commandId) => reconcileMarkUnverified(store, {
        taskId: run.task_id, generation: run.run_generation, expectedRevision: run.task_revision, commandId
      }, { now })
    };
  }
  function reverifyAction(run, key, probe) {
    return {
      key, kind: 'reverify', taskId: run.task_id, generation: run.run_generation,
      run: (commandId) => reconcileReverify(store, {
        taskId: run.task_id, generation: run.run_generation, expectedRevision: run.task_revision, commandId
      }, { now, probeIdentity: probe })
    };
  }
  function anomalyAction(run, key, { anomalyClass, failingClause, probeClass }) {
    return {
      key, kind: anomalyClass, taskId: run.task_id, generation: run.run_generation,
      run: (commandId) => recordReconcilerAnomaly(store, {
        anomalyClass, taskId: run.task_id, generation: run.run_generation,
        endpointId: run.endpoint_id, paneId: run.pane_id, agentPid: run.agent_pid,
        agentStartTicks: run.agent_start_ticks, terminalFingerprint: run.launch_marker,
        detail: { failing_clause: failingClause ?? null, probe_class: probeClass ?? null }, commandId
      }, { now })
    };
  }
  function anomalySpecAction(spec) {
    return {
      key: spec.key, kind: spec.kind, taskId: spec.taskId ?? null, generation: spec.generation ?? null,
      run: (commandId) => recordReconcilerAnomaly(store, { ...spec.anomaly, commandId }, { now })
    };
  }
  function cleanupMismatchAnomalyAction(run, key, reason) {
    return {
      key, kind: 'identity_mismatch', taskId: run.task_id, generation: run.run_generation,
      run: (commandId) => recordReconcilerAnomaly(store, {
        // Same class + fingerprint inputs as S3's cleanup-mismatch so this COALESCES with
        // it rather than creating a second identity_mismatch row.
        anomalyClass: 'identity_mismatch', taskId: run.task_id, generation: run.run_generation,
        endpointId: run.endpoint_id, paneId: run.pane_id, agentPid: run.agent_pid,
        agentStartTicks: run.agent_start_ticks, terminalFingerprint: run.launch_marker,
        detail: { reason: 'cleanup_target_mismatch', cleanup_reason: reason, observed_by: RECONCILER }, commandId
      }, { now })
    };
  }
}

// Only flag a terminal run as terminal_without_cleanup once it has been closed longer
// than the grace window: a run that just became terminal has not yet had its chance to
// clean, so an immediate flag would be premature noise every pass.
function terminalWithoutCleanup(run, deadlineNow, graceMs) {
  if (!run.closed_at) return false;
  return new Date(deadlineNow).getTime() - new Date(run.closed_at).getTime() > graceMs;
}

// Build the marker-scan anomaly SPECS (spec 553-562). Scans the isolated cp socket for
// marker-bearing endpoints and NEVER adopts or kills: a markerless or unknown-marker pane
// becomes an orphan_pane anomaly (captain-routed resolution, ruling Q4), a marker on more
// than one pane becomes launch_marker_duplicate, and a known run's marker absent from the
// scan becomes launch_marker_missing. Returns plain specs; reconcilePass binds each to the
// audit path.
function markerScanSpecs(snapshot, scanned, nonce) {
  const specs = [];
  const knownByMarker = new Map();
  for (const run of snapshot) {
    if (run.launch_marker && run.endpoint_id !== null) knownByMarker.set(run.launch_marker, run);
  }
  const seenMarkers = new Map(); // marker -> count among scanned panes
  for (const pane of scanned || []) {
    const endpointId = pane.endpointId ?? null;
    const paneId = pane.paneId ?? null;
    const marker = pane.marker ?? null;
    if (marker === null) {
      specs.push(orphanSpec(endpointId, paneId, null, 'markerless'));
      continue;
    }
    seenMarkers.set(marker, (seenMarkers.get(marker) || 0) + 1);
    if (!knownByMarker.has(marker)) {
      specs.push(orphanSpec(endpointId, paneId, marker, 'unknown_marker'));
    }
  }
  for (const [marker, count] of seenMarkers) {
    if (count > 1) {
      specs.push({
        key: `${nonce}:marker-dup:${marker}`, kind: 'launch_marker_duplicate', taskId: null, generation: null,
        anomaly: { anomalyClass: 'launch_marker_duplicate', terminalFingerprint: marker, detail: { marker, count } }
      });
    }
  }
  for (const [marker, run] of knownByMarker) {
    if (!seenMarkers.has(marker)) {
      specs.push({
        key: `${nonce}:marker-missing:${run.task_id}:${run.run_generation}`, kind: 'launch_marker_missing',
        taskId: run.task_id, generation: run.run_generation,
        anomaly: {
          anomalyClass: 'launch_marker_missing', taskId: run.task_id, generation: run.run_generation,
          endpointId: run.endpoint_id, paneId: run.pane_id, terminalFingerprint: marker, detail: { marker }
        }
      });
    }
  }
  return specs;

  function orphanSpec(endpointId, paneId, marker, reason) {
    return {
      key: `${nonce}:orphan:${endpointId}:${paneId}`, kind: 'orphan_pane', taskId: null, generation: null,
      anomaly: {
        anomalyClass: 'orphan_pane', endpointId, paneId, terminalFingerprint: marker,
        detail: { reason, endpoint_id: endpointId, pane_id: paneId, marker }
      }
    };
  }
}
