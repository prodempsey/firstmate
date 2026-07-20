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

// ---- registration HMAC (shared by cp-launch's writer and record-spawn's verifier) ----

// The wrapper's registration record proves the launched process is the one begin-run
// precommitted: an HMAC keyed by the run's secret bind_nonce over the immutable
// identity fields (spec section 5.2). Keying on the nonce is what makes the record
// unforgeable by anything that did not receive the nonce from begin-run.
export function registrationHmac(bindNonce, immutable) {
  const canonical = [
    immutable.launchMarker, immutable.taskId, String(immutable.generation),
    String(immutable.wrapperPid), String(immutable.wrapperStartTicks),
    immutable.exeRealpath, immutable.argvHash
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
    return fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
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
// argv hash, ppid, and pty. Returns null if the process is gone or the reads are
// incoherent (start ticks changed between the two reads => pid reuse mid-capture).
export function readProcIdentity(pid) {
  const first = parseProcStat(pid);
  if (!first) return null;
  const exe = realpathOrNull(`/proc/${pid}/exe`);
  const argvHash = readCmdlineHash(pid);
  const pty = realpathOrNull(`/proc/${pid}/fd/0`);
  const second = parseProcStat(pid);
  // Coherent /proc reads before and after identity capture (spec section 5.2): if the
  // start ticks moved, the pid was reused underneath us and the capture is invalid.
  if (!second || second.startTicks !== first.startTicks || second.ppid !== first.ppid) {
    return null;
  }
  return {
    startTicks: first.startTicks,
    ppid: first.ppid,
    exe,
    argvHash,
    pty: pty || (Number.isFinite(first.ttyNr) ? String(first.ttyNr) : null)
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

// Verify the wrapper's registration HMAC and capture the coherent /proc + tmux
// identity tuple for a freshly spawned run. Throws (via the caller's IdentityMismatch
// handling) when the launch cannot be coherently identified; the domain layer treats
// a thrown capture as an un-audited, whole-transaction-abandoning failure of the
// caller's own spawn.
//
// `run` carries the DB-side launch intent (bind_nonce, launch_marker,
// registration_path); `params` carries the caller's observed endpoint/pane; `socket`
// is the isolated control-plane tmux socket.
export function captureIdentity({ run, params, socket }) {
  const reg = readRegistration(params.regFile ?? run.registration_path);
  if (!reg) {
    return { ok: false, reason: 'registration_unreadable', clause: 'registration' };
  }
  // The wrapper's HMAC must recompute from the stored nonce over the record's own
  // immutable identity fields: a record that does not was not written by a process
  // holding this run's nonce.
  const expected = registrationHmac(run.bind_nonce, {
    launchMarker: run.launch_marker, taskId: run.task_id ?? params.taskId,
    generation: run.run_generation ?? params.generation,
    wrapperPid: reg.wrapperPid, wrapperStartTicks: reg.wrapperStartTicks,
    exeRealpath: reg.exeRealpath, argvHash: reg.argvHash
  });
  if (reg.marker !== run.launch_marker || reg.hmac !== expected) {
    return { ok: false, reason: 'registration_hmac_mismatch', clause: 'registration' };
  }
  const pane = tmuxListPane(socket, params.endpoint, params.pane);
  if (!pane.listed) {
    return { ok: false, reason: 'pane_not_listed', clause: 'tmux' };
  }
  const proc = readProcIdentity(reg.wrapperPid);
  if (!proc) {
    return { ok: false, reason: 'incoherent_proc', clause: 'proc' };
  }
  const paneLeader = readProcIdentity(pane.paneLeaderPid);
  return {
    ok: true,
    identity: {
      endpointId: params.endpoint,
      paneId: params.pane,
      bootId: readBootId(),
      paneLeaderPid: pane.paneLeaderPid,
      paneStartTicks: paneLeader ? paneLeader.startTicks : null,
      agentPid: reg.wrapperPid,
      agentStartTicks: proc.startTicks,
      agentExe: proc.exe,
      agentArgvHash: proc.argvHash,
      agentPpid: proc.ppid,
      agentPty: proc.pty,
      worktree: reg.worktree ?? null,
      harness: reg.harness ?? null
    }
  };
}

// ---- commit-running / verify-running probe (production default for probeIdentity) ----

// The `identity_matches` predicate (spec section 5.1) against the STORED identity in
// the run row. Returns { matches, failingClause, anomalyClass }: the first failing
// clause names why, and the anomaly class routes an audited commit-running rejection.
export function probeIdentity({ run, socket }) {
  const bootId = readBootId();
  if (run.boot_id && bootId && run.boot_id !== bootId) {
    return { matches: false, failingClause: 'boot_id', anomalyClass: 'identity_mismatch' };
  }
  const pane = tmuxListPane(socket, run.endpoint_id, run.pane_id);
  if (!pane.listed) {
    return { matches: false, failingClause: 'pane_absent', anomalyClass: 'missing_pane' };
  }
  if (run.pane_leader_pid !== null && pane.paneLeaderPid !== Number(run.pane_leader_pid)) {
    return { matches: false, failingClause: 'pane_leader_pid', anomalyClass: 'identity_mismatch' };
  }
  const proc = readProcIdentity(Number(run.agent_pid));
  if (!proc) {
    return { matches: false, failingClause: 'agent_pid', anomalyClass: 'missing_pane' };
  }
  if (run.agent_start_ticks !== null && proc.startTicks !== Number(run.agent_start_ticks)) {
    // start ticks differ though the pid is live: the pid was reused by a new process.
    return { matches: false, failingClause: 'agent_start_ticks', anomalyClass: 'pid_reuse_suspected' };
  }
  if (run.agent_exe && proc.exe !== run.agent_exe) {
    return { matches: false, failingClause: 'agent_exe', anomalyClass: 'identity_mismatch' };
  }
  if (run.agent_argv_hash && proc.argvHash !== run.agent_argv_hash) {
    return { matches: false, failingClause: 'agent_argv_hash', anomalyClass: 'identity_mismatch' };
  }
  return { matches: true, failingClause: null, anomalyClass: null };
}

// ---- cleanup effect (spec section 7 steps 2-4) ----

// cleanup_target_matches for a terminal run's stored target: stored boot ID still
// matches or the endpoint is already absent; if present, endpoint/pane/leader
// identity must match before any kill. Returns { present, matches, reason }.
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
  if (run.pane_leader_pid !== null && pane.paneLeaderPid !== Number(run.pane_leader_pid)) {
    return { present: true, matches: false, reason: 'pane_leader_mismatch' };
  }
  return { present: true, matches: true, reason: 'exact_match' };
}

// Kill ONLY the exact recorded pane on the isolated socket - never a pattern, never
// the server (spec section 7 step 3). Returns { killed, confirmed_absent }.
export function killExactPane({ socket, endpointId, paneId, run }) {
  const match = cleanupTargetMatches({ run: run ?? { endpoint_id: endpointId, pane_id: paneId }, socket });
  if (!match.present) {
    return { killed: false, confirmed_absent: true, reason: match.reason };
  }
  if (!match.matches) {
    // Identity mismatch: do not kill. The reconciler records the anomaly (S5); the
    // cleanup effect refuses to touch a pane it cannot prove is the recorded one.
    return { killed: false, confirmed_absent: false, reason: match.reason };
  }
  tmux(socket, ['kill-pane', '-t', paneId]);
  const after = tmuxListPane(socket, endpointId, paneId);
  return { killed: true, confirmed_absent: !after.listed, reason: 'killed_exact_pane' };
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
