#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { registrationHmac, argvHashOf, readProcIdentity, readBootId } from '../lib/tmux-adapter.mjs';

// One-shot registration writer for cp-launch (spec section 5.2). cp-launch is a POSIX
// sh script that, as its FIRST action, invokes this helper to write the HMAC-signed
// registration record, then `exec`s the harness so the shell's PID is preserved and
// BECOMES the harness PID.
//
// The wrapper shell PID ($$) is passed in as argv[1]; exec preserves that PID, its start
// ticks, its parent, and its controlling PTY, so those are read here from the LIVE shell
// /proc and are exactly what the harness will have after `exec`. The executable realpath
// and argv hash, by contrast, CHANGE at exec, so they are computed for the HARNESS the
// shell is about to exec into (argv[3..]) - which is precisely what record-spawn will
// read back from /proc once the exec completes. Signing that post-exec identity is what
// makes this a registration-first, PID-preserving self-identifying launch.
//
// It never opens PGlite and never touches the store: it reads /proc, resolves the
// harness executable, and writes one file.
//
//   node cp-reg-write.mjs <shell_pid> <reg_file> <harness_cmd> [harness_args...]
// env: CP_LAUNCH_MARKER, CP_TASK_ID, CP_RUN_GENERATION, CP_BIND_NONCE
//      optional CP_WORKTREE, CP_HARNESS

function fail(msg, code = 64) {
  process.stderr.write(`cp-reg-write: ${msg}\n`);
  process.exit(code);
}

function requireEnv(name) {
  const v = process.env[name];
  if (typeof v !== 'string' || v.length === 0) fail(`missing required env ${name}`);
  return v;
}

const [pidArg, regFile, ...harnessArgv] = process.argv.slice(2);
const shellPid = Number(pidArg);
if (!Number.isInteger(shellPid) || shellPid <= 0) fail('shell pid argument must be a positive integer');
if (!regFile) fail('registration file argument is required');
if (harnessArgv.length === 0) fail('harness command is required');

const marker = requireEnv('CP_LAUNCH_MARKER');
const taskId = requireEnv('CP_TASK_ID');
const generation = Number(requireEnv('CP_RUN_GENERATION'));
const bindNonce = requireEnv('CP_BIND_NONCE');

// Read the shell's coherent /proc identity for the fields exec PRESERVES: start ticks,
// parent pid, and controlling PTY. (Its own exe/argv are discarded - they change at exec.)
const shell = readProcIdentity(shellPid);
if (!shell) fail('could not read a coherent /proc identity for the launch wrapper', 66);

// Resolve the executable realpath the kernel will record at /proc/<pid>/exe after
// `exec`ing the harness: an absolute/relative path is realpath'd directly, otherwise the
// first executable match on PATH is used - the same resolution `exec` itself performs.
function resolveExe(cmd) {
  if (cmd.includes('/')) return fs.realpathSync(cmd);
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, cmd);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return fs.realpathSync(candidate);
    } catch {
      // keep searching PATH
    }
  }
  fail(`could not resolve harness executable on PATH: ${cmd}`, 66);
  return null; // unreachable
}

// The argv hash the kernel will expose at /proc/<pid>/cmdline after exec: each argument
// NUL-terminated (including the last), exactly the file's byte layout.
const cmdlineBytes = Buffer.from(harnessArgv.map((a) => `${a}\0`).join(''), 'utf8');

const agentExe = resolveExe(harnessArgv[0]);
const agentArgvHash = argvHashOf(cmdlineBytes);

const bootId = readBootId();
if (bootId === null) fail('could not read the host boot id', 66);

const signed = {
  marker, taskId, generation,
  agentPid: shellPid,
  agentStartTicks: shell.startTicks,
  agentExe,
  agentArgvHash,
  agentPpid: shell.ppid,
  agentPty: shell.pty
};

const record = {
  ...signed,
  bootId,
  worktree: process.env.CP_WORKTREE ?? null,
  harness: process.env.CP_HARNESS ?? null,
  hmac: registrationHmac(bindNonce, signed)
};

// Write atomically (temp then rename) so record-spawn never reads a half-written record.
const tmp = `${regFile}.tmp`;
fs.writeFileSync(tmp, JSON.stringify(record), { mode: 0o600 });
fs.renameSync(tmp, regFile);
