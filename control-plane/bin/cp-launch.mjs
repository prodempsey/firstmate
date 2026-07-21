#!/usr/bin/env node
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { registrationHmac, readProcIdentity, readBootId } from '../lib/tmux-adapter.mjs';

// Self-identifying launch wrapper (spec section 5.2 / 5.1). The adapter starts THIS
// program directly as a marker-bearing tmux window's initial command - never an
// interactive shell, so no markerless endpoint is ever created. The wrapper's env
// carries CP_LAUNCH_MARKER / CP_TASK_ID / CP_RUN_GENERATION, so the marker is
// observable from the first instant, before this registration write.
//
// IDENTITY MODEL (spec section 5.1). A launched generation has two real processes: the
// PANE LEADER - this wrapper, the pane's own command - and the AGENT, the harness the
// wrapper launches, whose parent is the pane leader. The recorded /proc identity is the
// ACTUAL AGENT, never the wrapper (qa-s3-q58 finding 2): the wrapper launches the
// harness as its child (so agent PID/exe/argv/PTY are the harness's and agent_ppid is
// this wrapper/pane-leader, satisfying the section 5.1 parent-chain clause), captures
// the child's coherent /proc identity, writes the HMAC-signed registration over THAT
// agent identity, and then blocks on the child so the recorded process stays live for
// record-spawn to verify. Pure Node cannot execve to literally replace its own image,
// so the harness is the wrapper's direct child rather than a re-exec of this pid; the
// recorded agent identity is nonetheless the real harness, which is what the contract
// requires.
//
// It never opens PGlite and never touches the store: it only launches one child and
// writes one file.
//
// Required environment:
//   CP_LAUNCH_MARKER  the run's launch marker (from begin-run)
//   CP_TASK_ID        the task id
//   CP_RUN_GENERATION the run generation
//   CP_BIND_NONCE     the run's secret bind nonce (from begin-run); the HMAC key
//   CP_REG_FILE       absolute path to write the registration record to
//   CP_HARNESS_CMD    JSON array [cmd, ...args] to run as the agent
// Optional: CP_WORKTREE, CP_HARNESS (recorded for observability, not identity).

function requireEnv(name) {
  const v = process.env[name];
  if (typeof v !== 'string' || v.length === 0) {
    process.stderr.write(`cp-launch: missing required env ${name}\n`);
    process.exit(64);
  }
  return v;
}

function fail(msg, code = 64) {
  process.stderr.write(`cp-launch: ${msg}\n`);
  process.exit(code);
}

const marker = requireEnv('CP_LAUNCH_MARKER');
const taskId = requireEnv('CP_TASK_ID');
const generation = Number(requireEnv('CP_RUN_GENERATION'));
const bindNonce = requireEnv('CP_BIND_NONCE');
const regFile = requireEnv('CP_REG_FILE');

let harnessCmd;
try {
  harnessCmd = JSON.parse(requireEnv('CP_HARNESS_CMD'));
} catch {
  fail('CP_HARNESS_CMD must be a JSON array');
}
if (!Array.isArray(harnessCmd) || harnessCmd.length === 0) {
  fail('CP_HARNESS_CMD must be a non-empty JSON array');
}

const [cmd, ...args] = harnessCmd;

// Launch the harness as the wrapper's direct child, sharing the pane's stdio so the
// agent's controlling PTY is the pane's PTY.
const child = spawn(cmd, args, { stdio: 'inherit' });
child.on('error', (err) => fail(`failed to launch harness: ${err.message}`, 65));

const delay = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

// Poll (bounded) until the child's /proc identity is coherently readable: the child
// has fully exec'd into the harness and its start ticks are stable across two reads.
let agent = null;
for (let i = 0; i < 200 && agent === null; i += 1) {
  if (child.exitCode !== null || child.signalCode !== null) {
    fail(`harness exited before it could be identified (code ${child.exitCode}, signal ${child.signalCode})`, 66);
  }
  agent = readProcIdentity(child.pid);
  if (agent === null) await delay(25); // eslint-disable-line no-await-in-loop
}
if (agent === null) {
  fail('could not capture a coherent agent identity for the launched harness', 66);
}

const bootId = readBootId();
if (bootId === null) fail('could not read the host boot id', 66);

const signed = {
  marker, taskId, generation,
  agentPid: child.pid,
  agentStartTicks: agent.startTicks,
  agentExe: agent.exe,
  agentArgvHash: agent.argvHash,
  agentPpid: agent.ppid,
  agentPty: agent.pty
};

const record = {
  ...signed,
  bootId,
  worktree: process.env.CP_WORKTREE ?? null,
  harness: process.env.CP_HARNESS ?? null,
  hmac: registrationHmac(bindNonce, signed)
};

// Write the registration record atomically (write to a temp then rename) so record-spawn
// never reads a half-written record.
const tmp = `${regFile}.tmp`;
fs.writeFileSync(tmp, JSON.stringify(record), { mode: 0o600 });
fs.renameSync(tmp, regFile);

// Block on the agent so the recorded process stays live for record-spawn/commit-running
// to verify; propagate its exit status.
child.on('exit', (code, signal) => {
  process.exit(signal ? 128 : (code ?? 0));
});
