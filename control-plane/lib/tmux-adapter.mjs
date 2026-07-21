import fs from 'node:fs';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

// S3 backend adapter: the REAL tmux + /proc identity probes and the exact-pane
// cleanup effect (spec section 5 and 7). This module is the injectable seam's
// production default: the domain layer (domain-store-s3.mjs) calls these probes to
// capture and verify launch identity, and tests inject deterministic doubles in
// their place. The domain layer therefore stays deterministic and atomic; all real,
// nondeterministic probing lives here.
//
// This adapter NEVER opens PGlite (owner guard, spec section 2.2) and never reaches
// the store: it uses only /proc reads, an isolated `tmux -L <cp-socket>` namespace,
// and file reads of the wrapper's registration record. Every tmux call is scoped to
// the caller-supplied isolated socket; the cleanup effect kills only the exact
// recorded pane, never a pattern and never a server (spec section 7 step 3).
//
// IDENTITY MODEL (spec section 5.1). A launched generation has two distinct real
// processes: the PANE LEADER (the wrapper cp-launch, the pane's own command) and the
// AGENT (the harness the wrapper spawns, whose parent is the pane leader). The full
// predicate pins BOTH: pane leader PID + start ticks, and the agent's PID + start
// ticks + executable realpath + argv hash + parent chain + PTY. The registration
// record signs the AGENT identity so record-spawn can verify the signed identity
// equals the LIVE agent /proc, closing the PID-reuse gap at record time.

// ---- registration HMAC (shared by cp-launch's writer and record-spawn's verifier) ----

// The registration record proves the launched AGENT is the one begin-run precommitted:
// an HMAC keyed by the run's secret bind_nonce over the marker and the EXEC-PRESERVED
// identity facts (spec section 5.2). It signs ONLY facts that survive `exec` unchanged -
// the marker, task/generation, and the wrapper PID plus its start ticks, parent, and PTY
// (all preserved when the shell execs the harness in place). It deliberately does NOT
// sign the executable realpath or argv hash: those are REWRITTEN by exec (a shebang
// script becomes its interpreter, e.g. `#!/usr/bin/env node` -> /usr/bin/node with a
// rewritten argv), so they cannot be predicted before exec and are instead OBSERVED live
// by record-spawn (captureIdentity). Keying on the nonce makes the record unforgeable by
// anything that did not receive the nonce from begin-run; the signed start-ticks/parent/
// PTY tuple is what lets record-spawn reject a stale or PID-reused registration.
export function registrationHmac(bindNonce, s) {
  const canonical = [
    s.marker, s.taskId, String(s.generation),
    String(s.agentPid), String(s.agentStartTicks),
    String(s.agentPpid), s.agentPty
  ].join('\x00');
  return crypto.createHmac('sha256', bindNonce).update(canonical).digest('hex');
}

// argv hash over the NUL-delimited /proc/<pid>/cmdline bytes (spec section 5.2).
export function argvHashOf(cmdlineBuf) {
  return crypto.createHash('sha256').update(cmdlineBuf).digest('hex');
}

// ---- /proc reads (Linux). Each returns null when the pid is gone or unreadable, so
// a caller treats "cannot read identity" as "identity does not match", never as a
// throw that would escape the probe. ----

export function readBootId() {
  try {
    return fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim() || null;
  } catch {
    return null;
  }
}

// Parse /proc/<pid>/stat for the fields S3 pins as identity: field 22 is starttime
// (start ticks since boot), field 4 is ppid, field 7 is the controlling tty device.
// The comm field (in parens, field 2) can contain spaces and parens, so we split on
// the LAST ')' before parsing the space-delimited remainder, the standard robust parse.
function parseProcStat(pid) {
  let raw;
  try {
    raw = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
  } catch {
    return null;
  }
  const rparen = raw.lastIndexOf(')');
  if (rparen < 0) return null;
  const rest = raw.slice(rparen + 2).trim().split(/\s+/);
  // rest[0] is field 3 (state); field 4 (ppid) is rest[1]; field 7 (tty_nr) is rest[4];
  // field 22 (starttime) is rest[19].
  if (rest.length < 20) return null;
  return {
    ppid: Number(rest[1]),
    ttyNr: Number(rest[4]),
    startTicks: Number(rest[19])
  };
}

function realpathOrNull(p) {
  try {
    return fs.realpathSync(p);
  } catch {
    return null;
  }
}

function readCmdlineHash(pid) {
  try {
    return argvHashOf(fs.readFileSync(`/proc/${pid}/cmdline`));
  } catch {
    return null;
  }
}

// A coherent /proc identity snapshot for a pid: start ticks, executable realpath,
// argv hash, ppid, and pty. Returns null if the process is gone, unreadable, or the
// reads are incoherent (start ticks or ppid changed between the two stat reads =>
// pid reuse mid-capture), or if any pinned field cannot be read (a partial identity
// is never a match).
export function readProcIdentity(pid) {
  if (pid === null || pid === undefined) return null;
  const first = parseProcStat(pid);
  if (!first) return null;
  const exe = realpathOrNull(`/proc/${pid}/exe`);
  const argvHash = readCmdlineHash(pid);
  const pty = realpathOrNull(`/proc/${pid}/fd/0`);
  const second = parseProcStat(pid);
  // Coherent /proc reads before and after identity capture (spec section 5.2): if the
  // start ticks or ppid moved, the pid was reused underneath us and the capture is
  // invalid.
  if (!second || second.startTicks !== first.startTicks || second.ppid !== first.ppid) {
    return null;
  }
  // A pinned field that cannot be read is a partial identity, never a match: fail
  // closed rather than returning a nullable tuple a caller might treat as verified.
  if (exe === null || argvHash === null || pty === null) return null;
  return {
    startTicks: first.startTicks,
    ppid: first.ppid,
    exe,
    argvHash,
    pty
  };
}

// ---- tmux (isolated -L <socket> namespace only) ----

function tmux(socket, args) {
  return spawnSync('tmux', ['-L', socket, ...args], { encoding: 'utf8' });
}

// True when the isolated socket lists BOTH the endpoint (window) and the pane. The
// pane list format is "<window_id> <pane_id> <pane_pid>", so we can also read the
// pane leader pid back from the same call.
export function tmuxListPane(socket, endpointId, paneId) {
  const r = tmux(socket, ['list-panes', '-a', '-F', '#{window_id} #{pane_id} #{pane_pid}']);
  if (r.status !== 0 || typeof r.stdout !== 'string') {
    return { listed: false, paneLeaderPid: null };
  }
  for (const line of r.stdout.split('\n')) {
    const [win, pane, pid] = line.trim().split(/\s+/);
    if (win === endpointId && pane === paneId) {
      return { listed: true, paneLeaderPid: Number(pid) };
    }
  }
  return { listed: false, paneLeaderPid: null };
}

// ---- record-spawn capture (production default for captureIdentity) ----

// Verify the wrapper's registration HMAC AND that its signed agent identity equals the
// LIVE agent /proc, confirm tmux really lists the endpoint/pane, capture the pane
// leader, and return the COMPLETE non-null identity tuple for a freshly spawned run.
// Any weak or incoherent binding fails (ok:false); the domain layer treats a failed
// capture as an un-audited, whole-transaction-abandoning failure of the caller's own
// spawn.
//
// `run` carries the DB-side launch intent (bind_nonce, launch_marker); `params`
// carries the caller's observed endpoint/pane and reg file; `socket` is the isolated
// control-plane tmux socket.
export function captureIdentity({ run, params, socket }) {
  const reg = readRegistration(params.regFile ?? run.registration_path);
  if (!reg) {
    return { ok: false, reason: 'registration_unreadable', clause: 'registration' };
  }
  const taskId = run.task_id ?? params.taskId;
  const generation = run.run_generation ?? params.generation;
  // The record must be HMAC-valid over its OWN signed (exec-preserved) tuple and name
  // this run's marker; a record whose HMAC does not recompute was not written by a
  // process holding this run's nonce.
  const expected = registrationHmac(run.bind_nonce, {
    marker: run.launch_marker, taskId, generation,
    agentPid: reg.agentPid, agentStartTicks: reg.agentStartTicks,
    agentPpid: reg.agentPpid, agentPty: reg.agentPty
  });
  if (reg.marker !== run.launch_marker || reg.hmac !== expected) {
    return { ok: false, reason: 'registration_hmac_mismatch', clause: 'registration' };
  }
  // Tie the SIGNED (exec-preserved) identity back to the LIVE agent /proc. A stale
  // registration (the agent already exited) or a reused PID (a different process now
  // holds reg.agentPid) is rejected here: the signed start ticks, parent, and PTY - all
  // preserved unchanged across exec - must equal what the live process has right now. The
  // executable realpath and argv hash are NOT predicted/signed (exec rewrites them,
  // including for shebang interpreters); they are OBSERVED live below and become the
  // authoritative stored identity that commit-running and cleanup later verify against.
  const liveAgent = readProcIdentity(reg.agentPid);
  if (!liveAgent) {
    return { ok: false, reason: 'agent_not_live', clause: 'agent' };
  }
  if (reg.agentStartTicks !== liveAgent.startTicks
      || reg.agentPpid !== liveAgent.ppid
      || reg.agentPty !== liveAgent.pty) {
    return { ok: false, reason: 'signed_identity_not_live', clause: 'agent' };
  }
  // tmux must really list the marker-bound endpoint/pane, and the pane leader must be a
  // coherently readable process.
  const pane = tmuxListPane(socket, params.endpoint, params.pane);
  if (!pane.listed) {
    return { ok: false, reason: 'pane_not_listed', clause: 'tmux' };
  }
  const paneLeader = readProcIdentity(pane.paneLeaderPid);
  if (!paneLeader) {
    return { ok: false, reason: 'pane_leader_not_live', clause: 'pane_leader' };
  }
  const bootId = readBootId();
  if (bootId === null) {
    return { ok: false, reason: 'boot_id_unreadable', clause: 'boot_id' };
  }
  // Require the COMPLETE immutable tuple: no nullable clause, no weak binding.
  const identity = {
    endpointId: params.endpoint,
    paneId: params.pane,
    bootId,
    paneLeaderPid: pane.paneLeaderPid,
    paneStartTicks: paneLeader.startTicks,
    agentPid: reg.agentPid,
    agentStartTicks: liveAgent.startTicks,
    agentExe: liveAgent.exe,
    agentArgvHash: liveAgent.argvHash,
    agentPpid: liveAgent.ppid,
    agentPty: liveAgent.pty,
    worktree: reg.worktree ?? null,
    harness: reg.harness ?? null
  };
  for (const k of ['endpointId', 'paneId', 'bootId', 'paneLeaderPid', 'paneStartTicks',
    'agentPid', 'agentStartTicks', 'agentExe', 'agentArgvHash', 'agentPpid', 'agentPty']) {
    if (identity[k] === null || identity[k] === undefined) {
      return { ok: false, reason: `incomplete_identity:${k}`, clause: k };
    }
  }
  return { ok: true, identity };
}

// ---- commit-running / verify-running probe (production default for probeIdentity) ----

// The FULL `identity_matches` predicate (spec section 5.1) against the STORED identity
// in the run row. Returns { matches, failingClause, anomalyClass }: the first failing
// clause names why, and the anomaly class routes an audited commit-running rejection.
// A stored identity that is not complete is a weak binding and fails closed - a missing
// stored clause is never a clause to SKIP.
export function probeIdentity({ run, socket }) {
  // Fail closed on any incomplete stored identity: every pinned field must be present
  // before a live match can even be attempted.
  const required = ['boot_id', 'pane_leader_pid', 'pane_start_ticks', 'agent_pid',
    'agent_start_ticks', 'agent_exe', 'agent_argv_hash', 'agent_ppid', 'agent_pty'];
  for (const f of required) {
    if (run[f] === null || run[f] === undefined) {
      return { matches: false, failingClause: `incomplete_binding:${f}`, anomalyClass: 'running_without_verification' };
    }
  }
  const bootId = readBootId();
  if (bootId === null || bootId !== run.boot_id) {
    return { matches: false, failingClause: 'boot_id', anomalyClass: 'identity_mismatch' };
  }
  const pane = tmuxListPane(socket, run.endpoint_id, run.pane_id);
  if (!pane.listed) {
    return { matches: false, failingClause: 'pane_absent', anomalyClass: 'missing_pane' };
  }
  if (pane.paneLeaderPid !== Number(run.pane_leader_pid)) {
    return { matches: false, failingClause: 'pane_leader_pid', anomalyClass: 'identity_mismatch' };
  }
  const paneLeader = readProcIdentity(pane.paneLeaderPid);
  if (!paneLeader) {
    return { matches: false, failingClause: 'pane_leader_absent', anomalyClass: 'missing_pane' };
  }
  if (paneLeader.startTicks !== Number(run.pane_start_ticks)) {
    return { matches: false, failingClause: 'pane_start_ticks', anomalyClass: 'pid_reuse_suspected' };
  }
  const agent = readProcIdentity(Number(run.agent_pid));
  if (!agent) {
    return { matches: false, failingClause: 'agent_pid', anomalyClass: 'missing_pane' };
  }
  if (agent.startTicks !== Number(run.agent_start_ticks)) {
    // start ticks differ though the pid is live: the pid was reused by a new process.
    return { matches: false, failingClause: 'agent_start_ticks', anomalyClass: 'pid_reuse_suspected' };
  }
  if (agent.exe !== run.agent_exe) {
    return { matches: false, failingClause: 'agent_exe', anomalyClass: 'identity_mismatch' };
  }
  if (agent.argvHash !== run.agent_argv_hash) {
    return { matches: false, failingClause: 'agent_argv_hash', anomalyClass: 'identity_mismatch' };
  }
  if (agent.ppid !== Number(run.agent_ppid)) {
    // Parent chain: the agent's parent must still be the recorded pane leader/wrapper.
    return { matches: false, failingClause: 'agent_ppid', anomalyClass: 'identity_mismatch' };
  }
  if (agent.pty !== run.agent_pty) {
    return { matches: false, failingClause: 'agent_pty', anomalyClass: 'identity_mismatch' };
  }
  return { matches: true, failingClause: null, anomalyClass: null };
}

// ---- cleanup effect (spec section 7 steps 2-4) ----

// cleanup_target_matches for a terminal run's stored target (spec section 7 step 2):
// stored boot ID still matches or the endpoint is already absent; if the pane is
// present, the pane leader PID AND start ticks must match; and if the agent still
// exists, its full agent identity must match too. Any mismatch means NO kill. Returns
// { present, matches, reason }.
export function cleanupTargetMatches({ run, socket }) {
  const bootId = readBootId();
  if (run.boot_id && bootId && run.boot_id !== bootId) {
    // A reboot means the stored pane cannot still be the same one: it is provably
    // absent, which is a clean cleanup target (nothing to kill).
    return { present: false, matches: true, reason: 'boot_changed_absent' };
  }
  const pane = tmuxListPane(socket, run.endpoint_id, run.pane_id);
  if (!pane.listed) {
    return { present: false, matches: true, reason: 'already_absent' };
  }
  // Present: the full pane-leader identity must agree before any kill.
  if (run.pane_leader_pid === null || run.pane_leader_pid === undefined
      || pane.paneLeaderPid !== Number(run.pane_leader_pid)) {
    return { present: true, matches: false, reason: 'pane_leader_mismatch' };
  }
  const paneLeader = readProcIdentity(pane.paneLeaderPid);
  if (!paneLeader) {
    // The listed pane's leader vanished mid-check: refuse rather than kill a pane whose
    // identity we can no longer confirm.
    return { present: true, matches: false, reason: 'pane_leader_unreadable' };
  }
  if (run.pane_start_ticks !== null && run.pane_start_ticks !== undefined
      && paneLeader.startTicks !== Number(run.pane_start_ticks)) {
    return { present: true, matches: false, reason: 'pane_start_mismatch' };
  }
  // If the agent still exists, its full identity must match too (spec section 7 step 2).
  // If the agent is already gone, the pane leader match above is sufficient to kill the
  // pane it belongs to.
  if (run.agent_pid !== null && run.agent_pid !== undefined) {
    const agent = readProcIdentity(Number(run.agent_pid));
    if (agent) {
      if ((run.agent_start_ticks !== null && agent.startTicks !== Number(run.agent_start_ticks))
          || (run.agent_exe && agent.exe !== run.agent_exe)
          || (run.agent_argv_hash && agent.argvHash !== run.agent_argv_hash)
          || (run.agent_ppid !== null && agent.ppid !== Number(run.agent_ppid))
          || (run.agent_pty && agent.pty !== run.agent_pty)) {
        return { present: true, matches: false, reason: 'agent_mismatch' };
      }
    }
  }
  return { present: true, matches: true, reason: 'exact_match' };
}

// Kill ONLY the exact recorded pane on the isolated socket - never a pattern, never
// the server (spec section 7 step 3) - and only after cleanup_target_matches proves the
// present target is the recorded one. Checks the kill result rather than assuming it
// happened. Returns { killed, confirmed_absent, reason }.
export function killExactPane({ socket, endpointId, paneId, run }) {
  const target = run ?? { endpoint_id: endpointId, pane_id: paneId };
  const match = cleanupTargetMatches({ run: target, socket });
  if (!match.present) {
    return { killed: false, confirmed_absent: true, reason: match.reason };
  }
  if (!match.matches) {
    // Identity mismatch: do NOT kill. The reconciler records the anomaly (S5); the
    // cleanup effect never touches a pane it cannot prove is the recorded one.
    return { killed: false, confirmed_absent: false, reason: match.reason };
  }
  const killed = tmux(socket, ['kill-pane', '-t', paneId]);
  // Verify the kill actually removed the pane rather than assuming it did.
  const after = tmuxListPane(socket, endpointId, paneId);
  return {
    killed: killed.status === 0,
    confirmed_absent: !after.listed,
    reason: killed.status === 0 ? 'killed_exact_pane' : 'kill_pane_failed'
  };
}

// ---- registration record I/O ----

// The wrapper writes this JSON record; record-spawn reads and HMAC-verifies it.
export function readRegistration(regPath) {
  if (!regPath) return null;
  let text;
  try {
    text = fs.readFileSync(regPath, 'utf8');
  } catch {
    return null;
  }
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
