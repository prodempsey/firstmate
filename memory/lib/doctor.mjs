import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { auditRegistry } from './registry.mjs';
import { canonicalCheckout, registryDir } from './paths.mjs';
import { assembleDoctor, packageLockStatus, versionMatches } from './doctor-core.mjs';
import { retrievalPaths } from './retrieval-index.mjs';

function requiredDependencies(root, pkg) {
  const missing = [];
  const mismatched = [];
  for (const [name, want] of Object.entries(pkg.dependencies || {})) {
    const depPkg = path.join(root, 'node_modules', name, 'package.json');
    if (!fs.existsSync(depPkg)) {
      missing.push(name);
      continue;
    }
    try {
      const installed = JSON.parse(fs.readFileSync(depPkg, 'utf8')).version;
      if (!versionMatches(installed, want)) mismatched.push(`${name}@${installed} != ${want}`);
    } catch {
      missing.push(name);
    }
  }
  return { ok: missing.length === 0 && mismatched.length === 0, missing, mismatched };
}

function dependencyAvailable(root, name) {
  return fs.existsSync(path.join(root, 'node_modules', name, 'package.json'));
}

function writable(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o755 });
    fs.accessSync(dir, fs.constants.W_OK);
    return 'writable';
  } catch {
    return 'read-only';
  }
}

// Fast, synchronous derived-retrieval readiness. This is a SHALLOW probe: it reads
// the current pointer and generation directory without booting PGlite. `mem
// retrieval doctor` performs the full canonical+generation verification. Readiness
// tracks what retrieval would do right now: `failed` when canonical is unhealthy,
// `pglite-fts` when a published generation is present, else `lexical-fallback`.
function retrievalReadiness(env, registryStatus, activeIndexStatus) {
  const canonicalHealthy = registryStatus !== 'critical'
    && registryStatus !== 'recovery_incomplete'
    && !String(registryStatus).startsWith('error')
    && activeIndexStatus === 'current';
  const rp = retrievalPaths(registryDir(env));
  let present = false;
  let generationId = null;
  if (fs.existsSync(rp.current)) {
    try {
      const current = JSON.parse(fs.readFileSync(rp.current, 'utf8'));
      generationId = current.generationId ?? null;
      const genDir = current.generationDir ? path.resolve(rp.root, current.generationDir) : null;
      present = Boolean(genDir && fs.existsSync(genDir));
    } catch {
      present = false;
    }
  }
  if (!canonicalHealthy) {
    return { status: present ? 'present' : 'missing', generationId, retrievalReadiness: 'failed', reason: 'canonical index not verified; run mem retrieval doctor' };
  }
  if (present) {
    return { status: 'present', generationId, retrievalReadiness: 'pglite-fts', reason: 'shallow probe; run mem retrieval doctor for full verification' };
  }
  return { status: 'missing', generationId: null, retrievalReadiness: 'lexical-fallback', reason: 'no published derived generation' };
}

export function checkDoctor(root, env = process.env) {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const lockPath = path.join(root, 'package-lock.json');
  const lock = fs.existsSync(lockPath) ? JSON.parse(fs.readFileSync(lockPath, 'utf8')) : null;

  let registryStatus = 'missing';
  let registryHealth = null;
  let registryReason = null;
  let activeIndexStatus = 'missing';
  let activeIndexWatermark = null;
  let snapshots = { health: null, outstanding: [], issues: [], reason: null };
  try {
    const audit = auditRegistry(registryDir(env));
    registryHealth = audit.registry.health;
    if (audit.registry.health === 'critical' || audit.registry.health === 'recovery_incomplete') registryStatus = audit.registry.health;
    else if (fs.existsSync(audit.registry.path)) registryStatus = writable(registryDir(env));
    else registryStatus = 'missing';
    activeIndexStatus = audit.activeIndex.status;
    activeIndexWatermark = audit.activeIndex.watermark;
    snapshots = {
      health: audit.snapshots.health,
      outstanding: audit.snapshots.outstanding,
      issues: audit.snapshots.issues,
      path: audit.snapshots.path,
      reason: audit.snapshots.issues[0] || null
    };
  } catch (error) {
    registryStatus = `error: ${error.message}`;
    registryReason = error.message;
  }

  const pgliteAvailable = dependencyAvailable(root, '@electric-sql/pglite');
  const vectorAvailable = dependencyAvailable(root, '@electric-sql/pglite-pgvector');
  return assembleDoctor({
    nodeVersion: process.version,
    engines: pkg.engines.node,
    cli: { available: true, path: fileURLToPath(new URL('../bin/mem.mjs', import.meta.url)) },
    canonicalCheckout: { path: canonicalCheckout(env), source: 'HOME' },
    packageLock: packageLockStatus(lock, pkg, lockPath),
    requiredDependencies: requiredDependencies(root, pkg),
    // PGlite backs the derived retrieval index (PR-2). It is runtime-optional
    // (retrieval falls back to lexical when it is absent), so `required` stays
    // false, but the status now reports real availability rather than a placeholder.
    pglite: { available: pgliteAvailable, required: false, status: pgliteAvailable ? 'available' : 'not installed (retrieval degrades to lexical fallback)' },
    // Rank-only vectors are deferred to PR-2b; the extension is optional and absent.
    vectorExtension: { available: vectorAvailable, required: false, status: vectorAvailable ? 'available' : 'not installed (vectors deferred to PR-2b)' },
    embeddingProvider: { configured: Boolean(env.MEM_EMBEDDING_KEY || env.OPENAI_API_KEY), required: false, status: 'optional' },
    registry: { path: registryDir(env), status: registryStatus, health: registryHealth, reason: registryReason },
    snapshots,
    activeIndex: { status: activeIndexStatus, watermark: activeIndexWatermark, reason: null },
    retrieval: retrievalReadiness(env, registryStatus, activeIndexStatus)
  });
}
