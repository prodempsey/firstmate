#!/usr/bin/env node
import fs from 'node:fs';
import { registrationHmac, readProcIdentity, readBootId } from '../lib/tmux-adapter.mjs';

// One-shot registration writer for cp-launch (spec section 5.2). cp-launch is a POSIX
// sh script that, as its FIRST action, invokes this helper to write the HMAC-signed
// registration record, then `exec`s the harness so the shell's PID is preserved and
// BECOMES the harness PID.
//
// It signs ONLY the exec-preserved facts: the marker, task/generation, and the wrapper
// shell PID ($$) plus its start ticks, parent, and controlling PTY - all read from the
// LIVE shell /proc and all preserved unchanged when the shell `exec`s the harness. It
// deliberately does NOT record or sign the executable realpath or argv hash, because
// `exec` REWRITES them (a directly-invoked shebang script becomes its interpreter with a
// kernel-rewritten argv, e.g. `#!/usr/bin/env node` -> /usr/bin/node), so no pre-exec
// prediction is correct in general. record-spawn OBSERVES the real post-exec exe/argv
// from /proc and stores those as the authoritative identity - robust to any interpreter
// chain (qa-s3r3-q61 finding 1).
//
// It never opens PGlite and never touches the store: it reads /proc and writes one file.
//
//   node cp-reg-write.mjs <shell_pid> <reg_file>
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

const [pidArg, regFile] = process.argv.slice(2);
const shellPid = Number(pidArg);
if (!Number.isInteger(shellPid) || shellPid <= 0) fail('shell pid argument must be a positive integer');
if (!regFile) fail('registration file argument is required');

const marker = requireEnv('CP_LAUNCH_MARKER');
const taskId = requireEnv('CP_TASK_ID');
const generation = Number(requireEnv('CP_RUN_GENERATION'));
const bindNonce = requireEnv('CP_BIND_NONCE');

// Read the shell's coherent /proc identity for the fields exec PRESERVES: start ticks,
// parent pid, and controlling PTY. (Its exe/argv are intentionally ignored - they change
// at exec and are observed live by record-spawn instead.)
const shell = readProcIdentity(shellPid);
if (!shell) fail('could not read a coherent /proc identity for the launch wrapper', 66);

const bootId = readBootId();
if (bootId === null) fail('could not read the host boot id', 66);

const signed = {
  marker, taskId, generation,
  agentPid: shellPid,
  agentStartTicks: shell.startTicks,
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
