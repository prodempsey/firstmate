import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { appendRegistryEvent } from '../lib/registry.mjs';

export const memoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const memBin = path.join(memoryRoot, 'bin', 'mem.mjs');

// Track every fixture registry so tests can reclaim disk between cases. Derived
// PGlite generations are full embedded-Postgres data directories (megabytes each),
// so retrieval test files call `afterEach(cleanTracked)` to avoid piling them up in
// TMPDIR across a run.
const trackedRegistries = new Set();

export function tmpRegistry() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-registry-'));
  trackedRegistries.add(dir);
  return dir;
}

export function cleanTracked() {
  for (const dir of trackedRegistries) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      // best effort; a fixture we cannot remove is harmless scratch
    }
  }
  trackedRegistries.clear();
}

// Seed an isolated fixture registry with active records for retrieval tests. Each
// spec is `{ id, ...recordFields }`; the proposer and activator use DISTINCT ids so
// high-impact activation (landing/dispatch/qa/governance kinds) passes the
// independent-activator governance check without needing captain authority. Never
// touches the production registry — callers pass a tmpRegistry() dir.
export async function seedActive(dir, specs) {
  for (const spec of specs) {
    const { id, ...fields } = spec;
    await appendRegistryEvent(dir, { event: 'proposed', memId: id, actor: { kind: 'firstmate', id: 'proposer' }, fields });
    await appendRegistryEvent(dir, {
      event: 'activated',
      memId: id,
      actor: { kind: 'firstmate', id: 'activator' },
      fields: { confidence: fields.confidence || 'observed' },
      evidence: [{ type: 'test', ref: `ev-${id}` }],
      validation: { method: 'captain', by: 'captain', ref: `CAP-${id}` }
    });
  }
}

export function runMem(args, env = {}) {
  return spawnSync(process.execPath, [memBin, ...args], {
    cwd: memoryRoot,
    env: { ...process.env, MEM_REGISTRY_DIR: tmpRegistry(), ...env },
    encoding: 'utf8'
  });
}

export function runMemIn(dir, args, env = {}) {
  return spawnSync(process.execPath, [memBin, ...args], {
    cwd: memoryRoot,
    env: { ...process.env, MEM_REGISTRY_DIR: dir, ...env },
    encoding: 'utf8'
  });
}

// Async spawn of a real, independent `mem` OS process. Used by the cross-process
// concurrency stress: this launches genuine separate processes contending for the
// registry lock, which an in-process Promise test cannot exercise.
export function spawnMemIn(dir, args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [memBin, ...args], {
      cwd: memoryRoot,
      env: { ...process.env, MEM_REGISTRY_DIR: dir, MEM_LOCK_WAIT_MS: '30000', ...env }
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('exit', (code) => resolve({ code, stdout, stderr }));
  });
}

export function writeJsonl(file, rows) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, rows.map((row) => (typeof row === 'string' ? row : JSON.stringify(row))).join('\n') + '\n');
}
