import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Sandboxed fixtures ONLY. Every test home is a fresh mktemp directory under the
// OS temp dir; nothing here ever touches a real FM_HOME, production state, or any
// production ledger. Registered cleanups run in an after() hook.
const cleanups = [];

export function mkFixtureHome() {
  const fmHome = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-s0-home-'));
  cleanups.push(fmHome);
  const dataDir = path.join(fmHome, 'state', 'control-plane', 'pgdata');
  return { fmHome, dataDir };
}

// A bare temp directory (e.g. to host a symlink-escape target or an explicit
// --data-dir fixture).
export function mkTempDir(prefix = 'cp-s0-tmp-') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  cleanups.push(dir);
  return dir;
}

export function cleanupAll() {
  for (const dir of cleanups.splice(0)) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      // best effort
    }
  }
}
