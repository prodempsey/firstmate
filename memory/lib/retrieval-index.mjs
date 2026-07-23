// Derived retrieval index lifecycle: canonical capture, generation build, atomic
// publication, staleness/corruption/partial detection, and cleanup. Everything
// here lives under ${MEM_REGISTRY_DIR}/derived/retrieval/ and is DERIVED,
// disposable, and rebuildable. The canonical registry, active index, activity,
// and snapshots (PR-1) remain the sole authority; nothing in this module ever
// mutates canonical state.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { sha256 } from './hash.mjs';
import { registryPaths } from './paths.mjs';
import { ACTIVE_INDEX_SCHEMA } from './schema.mjs';
import { activeRecords, auditRegistry, foldRegistry } from './registry.mjs';
import { withRegistryLock } from './lock.mjs';
import { NORMALIZER_VERSION } from './retrieval-normalize.mjs';
import { PGLITE_SCHEMA_VERSION, buildGenerationDb, inspectGenerationDb, loadPGlite } from './retrieval-pglite.mjs';

export const RETRIEVAL_INDEX_SCHEMA = 'kraken-memory/retrieval-index/v1';
export const RETRIEVAL_CURRENT_SCHEMA = 'kraken-memory/retrieval-current/v1';

export function retrievalPaths(registryDir) {
  const paths = registryPaths(registryDir);
  const root = path.join(paths.dir, 'derived', 'retrieval');
  return {
    registry: paths,
    root,
    current: path.join(root, 'current.json'),
    buildLock: path.join(root, '.build.lock'),
    generations: path.join(root, 'generations')
  };
}

// Durable, atomic file replace: temp in the same dir, fsync the file, rename, then
// fsync the directory so the rename itself is durable. Mirrors the PR-1 registry
// write discipline so a crash never leaves a torn current.json.
function atomicWriteFile(file, data) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o755 });
  const tmp = path.join(dir, `.${path.basename(file)}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`);
  const fd = fs.openSync(tmp, 'w', 0o600);
  try {
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, file);
  const dirFd = fs.openSync(dir, 'r');
  try {
    fs.fsyncSync(dirFd);
  } finally {
    fs.closeSync(dirFd);
  }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

// Capture a fully verified snapshot of canonical state under the registry lock.
// Returns { ok, reason, watermark, records, activeIndexFile } where records is the
// verified active projection. When ok is false, reason is a machine-readable
// canonical failure and retrieval must return `failed` (never lexical fallback).
// Uses only exported PR-1 surfaces; auditRegistry is the authoritative health
// composition (registry critical/recovery-incomplete + active-index verification).
export async function captureCanonical(registryDir) {
  const paths = registryPaths(registryDir);
  return withRegistryLock(paths.lock, async () => {
    const audit = auditRegistry(registryDir);
    if (audit.registry.health === 'critical') {
      return { ok: false, reason: 'registry-critical', watermark: audit.registry.watermark, records: [] };
    }
    if (audit.registry.health === 'recovery_incomplete') {
      return { ok: false, reason: 'recovery-incomplete', watermark: audit.registry.watermark, records: [] };
    }
    if (audit.activeIndex.status !== 'current') {
      return { ok: false, reason: `active-index-${audit.activeIndex.status}`, watermark: audit.registry.watermark, records: [] };
    }
    // Fold once more under the same lock (no mutation can interleave) to capture the
    // verified active projection and the complete watermark.
    const fold = foldRegistry(paths);
    const records = activeRecords(fold);
    const activeIndexFile = fs.existsSync(paths.index)
      ? { path: paths.index, size: fs.statSync(paths.index).size, mtime: fs.statSync(paths.index).mtime.toISOString(), sha256: sha256(fs.readFileSync(paths.index)) }
      : null;
    return { ok: true, reason: null, watermark: fold.watermark, records, activeIndexFile };
  });
}

function generationId(watermark, buildId) {
  const shortHash = String(watermark.registryHash || '').slice(0, 12) || '0';
  return `fts-${Number(watermark.seq)}-${shortHash}-${buildId}`;
}

function sortedIds(records) {
  return records.map((r) => r.id).sort();
}

// Full build: capture verified canonical, then (under the derived build lock)
// create a new unpublished generation, insert every active record, write the
// manifest, reopen and validate, and atomically publish current.json. On any
// failure before publish, the scratch generation is left for `clean` and the
// previous published generation stays current.
export async function buildRetrievalIndex(registryDir, options = {}) {
  const captured = await captureCanonical(registryDir);
  if (!captured.ok) {
    return { ok: false, mode: 'failed', reason: captured.reason, watermark: captured.watermark };
  }
  const PGlite = await loadPGlite();
  if (!PGlite) {
    return { ok: false, mode: 'pglite-unavailable', reason: 'pglite-not-loadable', watermark: captured.watermark };
  }
  const rp = retrievalPaths(registryDir);
  return withRegistryLock(rp.buildLock, async () => {
    const buildId = crypto.randomBytes(4).toString('hex');
    const genId = generationId(captured.watermark, buildId);
    const genDir = path.join(rp.generations, genId);
    const pgliteDir = path.join(genDir, 'pglite');
    fs.mkdirSync(genDir, { recursive: true, mode: 0o755 });

    const buildLog = path.join(genDir, 'build.log.jsonl');
    const log = (event, detail = {}) => {
      fs.appendFileSync(buildLog, `${JSON.stringify({ ts: new Date().toISOString(), event, ...detail })}\n`);
    };
    log('build-start', { generationId: genId, recordCount: captured.records.length, watermark: captured.watermark });

    const built = await buildGenerationDb(PGlite, pgliteDir, captured.records, captured.watermark.seq, {
      generationId: genId,
      registryHash: captured.watermark.registryHash,
      seq: String(captured.watermark.seq),
      pgliteSchemaVersion: PGLITE_SCHEMA_VERSION,
      normalizerVersion: NORMALIZER_VERSION
    });
    log('rows-inserted', { rowCount: built.rowCount });

    const manifest = {
      schema: RETRIEVAL_INDEX_SCHEMA,
      generationId: genId,
      createdAt: new Date().toISOString(),
      sourceRegistryDir: rp.registry.dir,
      canonicalWatermark: captured.watermark,
      activeIndex: captured.activeIndexFile,
      activeIndexSchema: ACTIVE_INDEX_SCHEMA,
      recordCount: built.rowCount,
      memoryIds: sortedIds(captured.records),
      records: captured.records.map((r) => ({ id: r.id, contentHash: r.contentHash })).sort((a, b) => (a.id < b.id ? -1 : 1)),
      pgliteSchemaVersion: PGLITE_SCHEMA_VERSION,
      normalizerVersion: NORMALIZER_VERSION,
      vector: null,
      buildStatus: 'built',
      validation: { ok: null, issues: [] }
    };

    // Reopen the built generation and validate it self-consistently before publish:
    // row count, ID set, and per-row content hash must match what we intended to
    // write. A mismatch means the build is corrupt; do not publish it.
    const issues = [];
    const inspected = await inspectGenerationDb(PGlite, pgliteDir);
    if (inspected.rowCount !== built.rowCount) issues.push('reopened row count mismatch');
    if (inspected.ftsCount !== built.rowCount) issues.push('reopened fts row count mismatch');
    const expectedById = new Map(captured.records.map((r) => [r.id, r.contentHash]));
    if (inspected.contentHashes.size !== expectedById.size) issues.push('reopened id set size mismatch');
    for (const [id, expectedHash] of expectedById) {
      if (inspected.contentHashes.get(id) !== expectedHash) issues.push(`reopened content hash mismatch: ${id}`);
    }
    manifest.validation = { ok: issues.length === 0, issues };
    atomicWriteFile(path.join(genDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
    log('validated', { ok: manifest.validation.ok, issues });

    if (!manifest.validation.ok) {
      return { ok: false, mode: 'failed', reason: 'build-validation-failed', generationId: genId, issues, watermark: captured.watermark };
    }

    const current = {
      schema: RETRIEVAL_CURRENT_SCHEMA,
      generationId: genId,
      generationDir: path.relative(rp.root, genDir),
      publishedAt: new Date().toISOString(),
      canonicalWatermark: captured.watermark,
      recordCount: built.rowCount
    };
    atomicWriteFile(rp.current, `${JSON.stringify(current, null, 2)}\n`);
    log('published', { generationId: genId });
    return { ok: true, mode: 'pglite-fts', generationId: genId, recordCount: built.rowCount, watermark: captured.watermark };
  });
}

export function readCurrent(registryDir) {
  const rp = retrievalPaths(registryDir);
  if (!fs.existsSync(rp.current)) return null;
  return readJson(rp.current);
}

function generationDirFor(rp, current) {
  if (!current || typeof current.generationDir !== 'string') return null;
  return path.resolve(rp.root, current.generationDir);
}

// Inspect the published derived generation and classify it. `canonical` is a
// captureCanonical() result: when ok, watermark/id-set/content-hash are compared
// against live canonical state (stale/partial); when not ok, only self-consistency
// is checked (doctor calls this even with unhealthy canonical). Returns
// { status, reason, generationId, manifest } with status one of
// current | missing | stale | corrupt | partial.
export async function inspectRetrievalIndex(registryDir, canonical) {
  const rp = retrievalPaths(registryDir);
  if (!fs.existsSync(rp.current)) return { status: 'missing', reason: 'no current pointer', generationId: null, manifest: null };
  const current = readJson(rp.current);
  if (!current || current.schema !== RETRIEVAL_CURRENT_SCHEMA || typeof current.generationId !== 'string') {
    return { status: 'corrupt', reason: 'current pointer unreadable or wrong schema', generationId: null, manifest: null };
  }
  const genDir = generationDirFor(rp, current);
  if (!genDir || !fs.existsSync(genDir)) return { status: 'missing', reason: 'current generation directory missing', generationId: current.generationId, manifest: null };
  const manifest = readJson(path.join(genDir, 'manifest.json'));
  if (!manifest || manifest.schema !== RETRIEVAL_INDEX_SCHEMA) {
    return { status: 'corrupt', reason: 'manifest unreadable or wrong schema', generationId: current.generationId, manifest: null };
  }
  if (manifest.pgliteSchemaVersion !== PGLITE_SCHEMA_VERSION) {
    return { status: 'corrupt', reason: 'pglite schema version mismatch', generationId: current.generationId, manifest };
  }
  if (manifest.buildStatus !== 'built' || manifest.validation?.ok !== true) {
    return { status: 'corrupt', reason: 'generation was never validated for publication', generationId: current.generationId, manifest };
  }

  const PGlite = await loadPGlite();
  if (!PGlite) return { status: 'corrupt', reason: 'pglite not loadable to verify generation', generationId: current.generationId, manifest };
  let inspected;
  try {
    inspected = await inspectGenerationDb(PGlite, path.join(genDir, 'pglite'));
  } catch (error) {
    return { status: 'corrupt', reason: `generation db unreadable: ${error.message}`, generationId: current.generationId, manifest };
  }
  // Self-consistency against the generation's own manifest.
  const manifestById = new Map((manifest.records || []).map((r) => [r.id, r.contentHash]));
  if (inspected.rowCount !== Number(manifest.recordCount)) return { status: 'corrupt', reason: 'db row count != manifest recordCount', generationId: current.generationId, manifest };
  if (inspected.ftsCount !== inspected.rowCount) return { status: 'corrupt', reason: 'fts row count != docs row count', generationId: current.generationId, manifest };
  if (inspected.contentHashes.size !== manifestById.size) return { status: 'corrupt', reason: 'db id set != manifest id set', generationId: current.generationId, manifest };
  for (const [id, hash] of manifestById) {
    if (inspected.contentHashes.get(id) !== hash) return { status: 'corrupt', reason: `db content hash != manifest for ${id}`, generationId: current.generationId, manifest };
  }

  if (!canonical || !canonical.ok) {
    // Canonical health unknown/unhealthy: report self-consistency only.
    return { status: 'current', reason: 'self-consistent (canonical not compared)', generationId: current.generationId, manifest };
  }

  // Against live canonical: watermark drift is stale; id-set/hash drift is partial.
  const w = manifest.canonicalWatermark || {};
  if (Number(w.seq) !== Number(canonical.watermark.seq)
      || (w.eventId ?? null) !== (canonical.watermark.eventId ?? null)
      || w.registryHash !== canonical.watermark.registryHash) {
    return { status: 'stale', reason: 'generation watermark differs from active-index watermark', generationId: current.generationId, manifest };
  }
  const liveById = new Map(canonical.records.map((r) => [r.id, r.contentHash]));
  if (liveById.size !== manifestById.size) return { status: 'partial', reason: 'indexed id set differs from active projection', generationId: current.generationId, manifest };
  for (const [id, hash] of liveById) {
    if (manifestById.get(id) !== hash) return { status: 'partial', reason: `indexed content differs from active projection for ${id}`, generationId: current.generationId, manifest };
  }
  return { status: 'current', reason: null, generationId: current.generationId, manifest };
}

// Remove abandoned/unpublished generation directories. NEVER removes the currently
// published generation. Returns { removed: [ids], kept } so callers can report.
export function cleanRetrievalIndex(registryDir) {
  const rp = retrievalPaths(registryDir);
  const current = readCurrent(registryDir);
  const keep = current && typeof current.generationId === 'string' ? current.generationId : null;
  const removed = [];
  if (!fs.existsSync(rp.generations)) return { removed, kept: keep };
  for (const entry of fs.readdirSync(rp.generations)) {
    if (entry === keep) continue;
    const target = path.join(rp.generations, entry);
    try {
      fs.rmSync(target, { recursive: true, force: true });
      removed.push(entry);
    } catch {
      // best effort; a generation we cannot remove is harmless scratch
    }
  }
  return { removed, kept: keep };
}
