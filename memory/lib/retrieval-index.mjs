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
import { auditRegistry, foldRegistry } from './registry.mjs';
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
// Returns { ok, reason, watermark, records, activeIndexFile } where `records` is
// the verified active projection READ FROM the PR-1 active-index artifact
// (memory-index.json), not reconstructed from a fresh registry fold. auditRegistry
// is the authoritative health composition (critical/recovery-incomplete +
// verifyActiveIndex, which proves the on-disk artifact matches the fold exactly);
// this function then parses that already-verified artifact so PR-2 is genuinely
// "over the PR-1 active index" and does not open a second projection path (F3).
// When ok is false, reason is a machine-readable canonical failure and retrieval
// must return `failed` (never lexical fallback). `opts.lockHeld` skips re-acquiring
// the registry lock when the caller already holds it (build path).
export async function captureCanonical(registryDir, opts = {}) {
  const paths = registryPaths(registryDir);
  const body = async () => {
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
    // Fold once more under the lock (no mutation can interleave) purely to obtain the
    // authoritative watermark to cross-check the artifact against.
    const fold = foldRegistry(paths);
    // Consume the verified artifact itself. auditRegistry already proved it matches
    // the fold; parse it and re-assert its watermark to keep the read path explicit.
    let installed;
    try {
      installed = JSON.parse(fs.readFileSync(paths.index, 'utf8'));
    } catch (error) {
      return { ok: false, reason: 'active-index-unreadable', watermark: fold.watermark, records: [] };
    }
    const w = installed.registry || {};
    if (Number(w.seq) !== Number(fold.watermark.seq) || (w.eventId ?? null) !== (fold.watermark.eventId ?? null) || w.registryHash !== fold.watermark.registryHash) {
      return { ok: false, reason: 'active-index-watermark-mismatch', watermark: fold.watermark, records: [] };
    }
    if (!Array.isArray(installed.records)) {
      return { ok: false, reason: 'active-index-records-missing', watermark: fold.watermark, records: [] };
    }
    const activeIndexFile = { path: paths.index, size: fs.statSync(paths.index).size, mtime: fs.statSync(paths.index).mtime.toISOString(), sha256: sha256(fs.readFileSync(paths.index)) };
    return { ok: true, reason: null, watermark: fold.watermark, records: installed.records, activeIndexFile };
  };
  return opts.lockHeld ? body() : withRegistryLock(paths.lock, body);
}

function generationId(watermark, buildId) {
  const shortHash = String(watermark.registryHash || '').slice(0, 12) || '0';
  return `fts-${Number(watermark.seq)}-${shortHash}-${buildId}`;
}

function sortedIds(records) {
  return records.map((r) => r.id).sort();
}

// Full build: under the derived build lock, capture verified canonical, create a
// new unpublished generation, insert every active record, write the manifest,
// reopen and validate (rows, IDs, content hashes, AND FTS-surface consistency),
// and atomically publish current.json. The build lock is acquired BEFORE the
// canonical capture so concurrent builders are fully serialized start-to-publish:
// the last builder to enter captures the newest watermark and publishes last, so a
// stale generation can never overwrite a newer one (F4). On any failure before
// publish, the scratch generation is left for `clean` and the previous published
// generation stays current.
export async function buildRetrievalIndex(registryDir, options = {}) {
  const PGlite = await loadPGlite();
  if (!PGlite) {
    return { ok: false, mode: 'pglite-unavailable', reason: 'pglite-not-loadable', watermark: null };
  }
  const rp = retrievalPaths(registryDir);
  return withRegistryLock(rp.buildLock, async () => {
    const captured = await captureCanonical(registryDir);
    if (!captured.ok) {
      return { ok: false, mode: 'failed', reason: captured.reason, watermark: captured.watermark };
    }
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
      eventId: String(captured.watermark.eventId ?? ''),
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
    if (inspected.missingFtsCount !== 0) issues.push('reopened generation has docs without fts rows');
    if (inspected.ftsMismatchCount !== 0) issues.push('reopened fts documents inconsistent with search_text');
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

// Resolve the current generation directory and reject any pointer that escapes the
// generations root (path-traversal guard): a forged generationDir cannot point the
// reader at an arbitrary directory.
function generationDirFor(rp, current) {
  if (!current || typeof current.generationDir !== 'string') return null;
  const resolved = path.resolve(rp.root, current.generationDir);
  const base = path.resolve(rp.generations);
  if (resolved !== base && !resolved.startsWith(base + path.sep)) return null;
  return resolved;
}

// Inspect the published derived generation and classify it. `canonical` is a
// captureCanonical() result: when ok, the manifest AND the queried PGlite metadata
// are compared against live canonical state (stale/partial); when not ok, only
// internal identity/consistency is checked (doctor calls this even with unhealthy
// canonical). Returns { status, reason, generationId, manifest } with status one of
// current | missing | stale | corrupt | partial.
//
// Corruption/identity gate (F2): before a reader trusts a generation it must prove
// the queried PGlite index IS the validated generation for the current pointer —
// pointer/manifest identity, directory containment, schema+normalizer versions, the
// PGlite retrieval_meta watermark, per-row content hashes, AND that every FTS
// document still matches its search_text. Any mismatch is corrupt/partial, forcing
// lexical fallback when canonical is healthy.
export async function inspectRetrievalIndex(registryDir, canonical) {
  const rp = retrievalPaths(registryDir);
  if (!fs.existsSync(rp.current)) return { status: 'missing', reason: 'no current pointer', generationId: null, manifest: null };
  const current = readJson(rp.current);
  if (!current || current.schema !== RETRIEVAL_CURRENT_SCHEMA || typeof current.generationId !== 'string') {
    return { status: 'corrupt', reason: 'current pointer unreadable or wrong schema', generationId: null, manifest: null };
  }
  const genDir = generationDirFor(rp, current);
  if (!genDir) return { status: 'corrupt', reason: 'current generationDir escapes the generations root', generationId: current.generationId, manifest: null };
  if (!fs.existsSync(genDir)) return { status: 'missing', reason: 'current generation directory missing', generationId: current.generationId, manifest: null };
  const manifest = readJson(path.join(genDir, 'manifest.json'));
  if (!manifest || manifest.schema !== RETRIEVAL_INDEX_SCHEMA) {
    return { status: 'corrupt', reason: 'manifest unreadable or wrong schema', generationId: current.generationId, manifest: null };
  }
  const corrupt = (reason) => ({ status: 'corrupt', reason, generationId: current.generationId, manifest });

  // Pointer <-> manifest identity: the pointer's generation must BE this manifest's.
  if (current.generationId !== manifest.generationId) return corrupt('current pointer generationId != manifest generationId');
  // The generation directory must be the one the manifest names.
  if (path.basename(genDir) !== manifest.generationId) return corrupt('generation directory name != manifest generationId');
  if (manifest.pgliteSchemaVersion !== PGLITE_SCHEMA_VERSION) return corrupt('pglite schema version mismatch');
  if (manifest.normalizerVersion !== NORMALIZER_VERSION) return corrupt('normalizer version mismatch');
  if (manifest.buildStatus !== 'built' || manifest.validation?.ok !== true) return corrupt('generation was never validated for publication');
  const mw = manifest.canonicalWatermark || {};

  const PGlite = await loadPGlite();
  if (!PGlite) return corrupt('pglite not loadable to verify generation');
  let inspected;
  try {
    inspected = await inspectGenerationDb(PGlite, path.join(genDir, 'pglite'));
  } catch (error) {
    return corrupt(`generation db unreadable: ${error.message}`);
  }

  // The PGlite retrieval_meta must match the manifest identity and watermark: a
  // forged meta value (or a DB from a different generation) is corrupt.
  const meta = inspected.meta || {};
  if (meta.generationId !== manifest.generationId) return corrupt('db retrieval_meta generationId != manifest');
  if (meta.pgliteSchemaVersion !== PGLITE_SCHEMA_VERSION) return corrupt('db retrieval_meta pglite schema version mismatch');
  if (meta.normalizerVersion !== NORMALIZER_VERSION) return corrupt('db retrieval_meta normalizer version mismatch');
  if (meta.registryHash !== mw.registryHash) return corrupt('db retrieval_meta registryHash != manifest watermark');
  if (String(meta.seq) !== String(mw.seq)) return corrupt('db retrieval_meta seq != manifest watermark');
  if (String(meta.eventId ?? '') !== String(mw.eventId ?? '')) return corrupt('db retrieval_meta eventId != manifest watermark');

  // The FTS surface must still be internally consistent (no emptied/forged tsvector,
  // no doc missing its FTS row) so the queried index really covers the projection.
  if (inspected.missingFtsCount !== 0) return corrupt('docs without fts rows');
  if (inspected.ftsMismatchCount !== 0) return corrupt('fts documents inconsistent with search_text');

  // Self-consistency against the generation's own manifest.
  const manifestById = new Map((manifest.records || []).map((r) => [r.id, r.contentHash]));
  if (inspected.rowCount !== Number(manifest.recordCount)) return corrupt('db row count != manifest recordCount');
  if (inspected.ftsCount !== inspected.rowCount) return corrupt('fts row count != docs row count');
  if (inspected.contentHashes.size !== manifestById.size) return corrupt('db id set != manifest id set');
  for (const [id, hash] of manifestById) {
    if (inspected.contentHashes.get(id) !== hash) return corrupt(`db content hash != manifest for ${id}`);
  }

  if (!canonical || !canonical.ok) {
    // Canonical health unknown/unhealthy: report internal identity/consistency only.
    return { status: 'current', reason: 'self-consistent (canonical not compared)', generationId: current.generationId, manifest };
  }

  // Against live canonical: watermark drift is stale; id-set/hash drift is partial.
  if (Number(mw.seq) !== Number(canonical.watermark.seq)
      || (mw.eventId ?? null) !== (canonical.watermark.eventId ?? null)
      || mw.registryHash !== canonical.watermark.registryHash) {
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
// published generation, and takes the build lock so it cannot race a concurrent
// build that is still populating an unpublished generation (F4). Returns
// { removed: [ids], kept }.
export async function cleanRetrievalIndex(registryDir) {
  const rp = retrievalPaths(registryDir);
  return withRegistryLock(rp.buildLock, async () => {
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
  });
}
