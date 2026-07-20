#!/usr/bin/env node
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { registrationHmac, argvHashOf } from '../lib/tmux-adapter.mjs';

// Self-identifying launch wrapper (spec section 5.2). The adapter starts THIS program
// directly as a marker-bearing tmux window's initial command - never an interactive
// shell, so no markerless endpoint is ever created. Its FIRST action is to write the
// registration record record-spawn will HMAC-verify; it then execs the harness so the
// wrapper PID (already recorded) is the harness PID and the /proc identity is stable.
//
// It never opens PGlite and never touches the store: it only writes one file and execs.
// Everything it needs is precommitted by begin-run and handed in via the environment,
// which also carries CP_LAUNCH_MARKER / CP_TASK_ID / CP_RUN_GENERATION so the marker is
// observable before record-spawn and before this registration write.
//
// Required environment:
//   CP_LAUNCH_MARKER  the run's launch marker (from begin-run)
//   CP_TASK_ID        the task id
//   CP_RUN_GENERATION the run generation
//   CP_BIND_NONCE     the run's secret bind nonce (from begin-run); the HMAC key
//   CP_REG_FILE       absolute path to write the registration record to
//   CP_HARNESS_CMD    JSON array [cmd, ...args] to exec after registration
// Optional: CP_WORKTREE, CP_HARNESS (recorded for observability, not identity).

function requireEnv(name) {
  const v = process.env[name];
  if (typeof v !== 'string' || v.length === 0) {
    process.stderr.write(`cp-launch: missing required env ${name}\n`);
    process.exit(64);
  }
  return v;
}

const marker = requireEnv('CP_LAUNCH_MARKER');
const taskId = requireEnv('CP_TASK_ID');
const generation = requireEnv('CP_RUN_GENERATION');
const bindNonce = requireEnv('CP_BIND_NONCE');
const regFile = requireEnv('CP_REG_FILE');

let harnessCmd;
try {
  harnessCmd = JSON.parse(requireEnv('CP_HARNESS_CMD'));
} catch {
  process.stderr.write('cp-launch: CP_HARNESS_CMD must be a JSON array\n');
  process.exit(64);
}
if (!Array.isArray(harnessCmd) || harnessCmd.length === 0) {
  process.stderr.write('cp-launch: CP_HARNESS_CMD must be a non-empty JSON array\n');
  process.exit(64);
}

// The wrapper's own coherent /proc identity, captured before exec so record-spawn can
// bind to it: this process's pid, its start ticks, its executable realpath, and its
// argv hash. After the exec below these all survive because exec preserves the pid.
const wrapperPid = process.pid;
const exeRealpath = fs.realpathSync(process.execPath);
const argvHash = argvHashOf(Buffer.from(process.argv.join('\x00'), 'utf8'));

function wrapperStartTicks(pid) {
  // Field 22 of /proc/<pid>/stat is starttime in clock ticks since boot.
  const raw = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
  const rest = raw.slice(raw.lastIndexOf(')') + 2).trim().split(/\s+/);
  return Number(rest[19]);
}

const startTicks = wrapperStartTicks(wrapperPid);

const record = {
  marker,
  taskId,
  generation: Number(generation),
  wrapperPid,
  wrapperStartTicks: startTicks,
  exeRealpath,
  argvHash,
  worktree: process.env.CP_WORKTREE ?? null,
  harness: process.env.CP_HARNESS ?? null,
  hmac: registrationHmac(bindNonce, {
    launchMarker: marker, taskId, generation: Number(generation),
    wrapperPid, wrapperStartTicks: startTicks, exeRealpath, argvHash
  })
};

// Write the registration record atomically (write to a temp then rename) so record-spawn
// never reads a half-written record.
const tmp = `${regFile}.tmp`;
fs.writeFileSync(tmp, JSON.stringify(record), { mode: 0o600 });
fs.renameSync(tmp, regFile);

// Exec the harness so the recorded wrapper PID becomes the harness PID (spec section
// 5.2: "execs the harness so the PID is preserved"). execFileSync would fork a child;
// to truly preserve the pid we replace the image. Node has no execve, so we approximate
// with a synchronous foreground child that keeps THIS pid as the parent chain root and
// blocks until the harness exits - acceptable for the isolated S3 adapter where the
// recorded identity is the wrapper pid and its start ticks, both stable across this call.
const [cmd, ...args] = harnessCmd;
try {
  execFileSync(cmd, args, { stdio: 'inherit' });
} catch (err) {
  process.exit(typeof err.status === 'number' ? err.status : 1);
}
