// Deterministic identity doubles for the no-tmux workflows (spec matrix: wf5/6/8/9 do NOT
// require a real pane; only wf1-4 and wf7 do). These are the SAME injected-double shape
// the landed S3/archive/S6 contract suites use to drive a run to bound_verified without a
// host: recordSpawn accepts `{ captureIdentity }`, commitRunning/reconcilePromote accept
// `{ probeIdentity }`. Nothing here touches a real process or socket - a workflow that
// needs a genuine live pane uses fixtures/agent.mjs instead.

// A synthetic but internally-coherent /proc+tmux identity, parameterizable per task so
// distinct double-mode runs carry distinct endpoint/pane ids (launch_marker is already
// unique per run via beginRun, so this is only for realism/readability).
export function fixtureIdentity(seed = 0) {
  const n = 4000 + seed;
  return {
    endpointId: `@${seed}`, paneId: `%${seed}`, bootId: 'boot-e2e-fixture',
    paneLeaderPid: n, paneStartTicks: 100000 + seed,
    agentPid: n + 1, agentStartTicks: 200000 + seed, agentExe: '/usr/bin/node',
    agentArgvHash: `argvhash-${seed}`, agentPpid: n, agentPty: `pts/${seed}`,
    worktree: `/tmp/e2e-wt-${seed}`, harness: 'claude'
  };
}

// captureIdentity double: record-spawn stores this identity verbatim (ok:true).
export function captureOk(seed = 0) {
  const identity = fixtureIdentity(seed);
  return () => ({ ok: true, identity: { ...identity } });
}

// probeIdentity double: the anti-ghost gate at commit/reverify time sees a match.
export function probeMatch() {
  return () => ({ matches: true, failingClause: null, anomalyClass: null });
}

// probeIdentity double: a DEFINITIVE loss (the process is provably gone). Drives the
// reconciler's fail-the-generation path in wf4 without needing a real kill for the
// double-mode assertions. `anomalyClass` mirrors probeIdentityTransientAware's definitive
// vocabulary ('missing_pane' | 'identity_mismatch' | 'pid_reuse_suspected').
export function probeGone(failingClause = 'pane_absent', anomalyClass = 'missing_pane') {
  return () => ({ matches: false, transient: false, failingClause, anomalyClass });
}
