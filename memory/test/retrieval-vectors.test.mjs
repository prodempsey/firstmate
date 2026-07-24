import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test, { afterEach } from 'node:test';
import { buildRetrievalIndex, readCurrent, retrievalPaths } from '../lib/retrieval-index.mjs';
import { retrieveMemory, __resetVectorFallbackLog } from '../lib/retrieve.mjs';
import { recall } from '../lib/recall.mjs';
import { readVectorArtifacts, VECTOR_MANIFEST_FILE, VECTORS_FILE } from '../lib/retrieval-vector-build.mjs';
import { VECTOR_MANIFEST_SCHEMA } from '../lib/retrieval-vector.mjs';
import { createStubEmbeddingProvider } from '../lib/embedding-provider.mjs';
import { cleanTracked, seedActive, tmpRegistry } from './helpers.mjs';

afterEach(cleanTracked);

// A CONTROLLED embedding provider for deterministic reorder assertions: a text
// carrying "axisN" embeds to a one-hot vector at index N (query with no axis marker
// -> axis 0). Used for BOTH build and query so corpus/query vectors are comparable.
function axisProvider(dim = 4) {
  const embed = (text) => {
    const v = new Array(dim).fill(0);
    const m = String(text).match(/axis(\d+)/);
    v[m ? Number(m[1]) % dim : 0] = 1;
    return v;
  };
  return {
    id: `test-axis:${dim}`,
    model: 'test-axis',
    dimensions: dim,
    async canEmbed() { return true; },
    async embed(t) { return embed(t); },
    async embedBatch(ts) { return ts.map(embed); }
  };
}

// For query "alpha beta": MEM-0001 matches BOTH terms (higher lexical score, FTS
// order first, DETERMINISTIC by score, not timestamp); MEM-0002 matches only
// "alpha" (curated -> still eligible, lower score, FTS second). Their vectors are
// crafted so the query (axis0) aligns with the FTS-LAST record (MEM-0002 -> axis0),
// forcing a visible reorder to [MEM-0002, MEM-0001] under hybrid-rank. MEM-0003 is a
// filter-passing record with a query-aligned vector but NO lexical evidence for the
// query — the semantic-only case.
const CORPUS = [
  { id: 'MEM-0001', summary: 'alpha beta axis1', keywords: ['alpha', 'beta'], projects: ['*'], taskKinds: ['*'] },
  { id: 'MEM-0002', summary: 'alpha only axis0', keywords: ['alpha'], projects: ['*'], taskKinds: ['*'] },
  { id: 'MEM-0003', summary: 'gamma delta axis0', keywords: ['gamma'], projects: ['*'], taskKinds: ['*'] }
];

async function builtWithVectors(specs = CORPUS, provider = axisProvider()) {
  const dir = tmpRegistry();
  await seedActive(dir, specs);
  const result = await buildRetrievalIndex(dir, { vectors: true, embeddingProvider: provider });
  return { dir, result };
}

test('build --vectors writes a generation-bound vector manifest and per-record vectors', async () => {
  const { dir, result } = await builtWithVectors();
  assert.equal(result.ok, true);
  assert.equal(result.vector.status, 'built');
  assert.equal(result.vector.embeddedCount, 3);
  assert.equal(result.vector.reusedCount, 0);

  const current = readCurrent(dir);
  const rp = retrievalPaths(dir);
  const genDir = path.resolve(rp.root, current.generationDir);
  const manifest = JSON.parse(fs.readFileSync(path.join(genDir, VECTOR_MANIFEST_FILE), 'utf8'));
  assert.equal(manifest.schema, VECTOR_MANIFEST_SCHEMA);
  assert.equal(manifest.model, 'test-axis');
  assert.equal(manifest.dimensions, 4);
  // FC-002 anchor: the manifest is BOUND to the published generation id.
  assert.equal(manifest.generationId, current.generationId);
  assert.equal(manifest.vectorCount, 3);

  const lines = fs.readFileSync(path.join(genDir, VECTORS_FILE), 'utf8').trim().split('\n');
  assert.equal(lines.length, 3, 'one embedding row per active record');
  const row = JSON.parse(lines[0]);
  assert.ok(typeof row.id === 'string' && Array.isArray(row.embedding) && typeof row.contentHash === 'string');

  // The generation manifest.json also records the vector summary.
  const genManifest = JSON.parse(fs.readFileSync(path.join(genDir, 'manifest.json'), 'utf8'));
  assert.equal(genManifest.vector.enabled, true);
  assert.equal(genManifest.vector.status, 'built');
});

test('rank-only: vectors REORDER the eligible set without changing its membership', async () => {
  const provider = axisProvider();
  const { dir } = await builtWithVectors(CORPUS, provider);

  const fts = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship' });
  assert.equal(fts.retrievalMode, 'pglite-fts');
  assert.deepEqual(fts.selected.map((s) => s.id), ['MEM-0001', 'MEM-0002'], 'FTS order is by lexical score: MEM-0001 matches both terms');

  const hybrid = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: provider });
  assert.equal(hybrid.retrievalMode, 'hybrid-rank');
  // Same SET, reordered: the query-aligned MEM-0002 moves ahead.
  assert.deepEqual(hybrid.selected.map((s) => s.id), ['MEM-0002', 'MEM-0001'], 'vector-aligned MEM-0002 reorders ahead of the higher-lexical MEM-0001');
  assert.deepEqual(hybrid.selected.map((s) => s.id).slice().sort(), fts.selected.map((s) => s.id).slice().sort(), 'membership unchanged');
  assert.equal(hybrid.selected[0].vectorSimilarity, 1);
  assert.equal(hybrid.telemetry.vector.enabled, true);
  assert.equal(hybrid.telemetry.vector.status, 'active');
  assert.equal(hybrid.telemetry.vector.reordered, true);
});

test('invariant 2: a semantic-only neighbor is a NON-SELECTABLE diagnostic, never selected', async () => {
  const provider = axisProvider();
  const { dir } = await builtWithVectors(CORPUS, provider);
  const hybrid = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: provider });

  // MEM-0003 has a query-aligned vector but no lexical evidence for "alpha".
  assert.ok(!hybrid.selected.some((s) => s.id === 'MEM-0003'), 'semantic-only record is never selectable');
  const so = hybrid.semanticOnly.find((x) => x.id === 'MEM-0003');
  assert.ok(so, 'semantic-only neighbor surfaced as a diagnostic');
  assert.equal(so.selectable, false);
  assert.equal(so.reason, 'vector-only');
  assert.equal(hybrid.telemetry.vector.semanticOnlyCount, hybrid.semanticOnly.length);
});

test('invariant 1: vectors never make a filtered-out (out-of-scope) record a semantic-only neighbor', async () => {
  const provider = axisProvider();
  const specs = [
    { id: 'MEM-0001', summary: 'alpha topic axis0', keywords: ['alpha'], projects: ['firstmate'], taskKinds: ['ship'] },
    // Query-aligned vector, but scoped to a DIFFERENT project: must not leak even as a diagnostic.
    { id: 'MEM-0009', summary: 'omega scoped axis0', keywords: ['omega'], projects: ['other-project'], taskKinds: ['ship'] }
  ];
  const { dir } = await builtWithVectors(specs, provider);
  const hybrid = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: provider });
  assert.ok(!hybrid.selected.some((s) => s.id === 'MEM-0009'));
  assert.ok(!hybrid.semanticOnly.some((x) => x.id === 'MEM-0009'), 'out-of-scope record never surfaces as a semantic-only neighbor');
});

test('FC-002: a vector manifest not bound to the current generation is refused, degrading to FTS', async () => {
  const provider = axisProvider();
  const { dir } = await builtWithVectors(CORPUS, provider);
  const current = readCurrent(dir);
  const rp = retrievalPaths(dir);
  const genDir = path.resolve(rp.root, current.generationDir);
  const manifestPath = path.join(genDir, VECTOR_MANIFEST_FILE);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  manifest.generationId = 'fts-999-deadbeef-stale';
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

  __resetVectorFallbackLog();
  const r = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: provider });
  assert.equal(r.retrievalMode, 'pglite-fts', 'stale manifest refused; retrieval stays on the proven FTS tier');
  assert.equal(r.telemetry.vector.enabled, false);
  assert.equal(r.telemetry.vector.status, 'fallback');
  assert.match(r.telemetry.vector.reason, /not bound|invalid/);
  // FTS order is intact (not reranked).
  assert.deepEqual(r.selected.map((s) => s.id), ['MEM-0001', 'MEM-0002']);
});

test('fallback: no embedding key degrades to FTS without failing, logged once', async () => {
  const provider = axisProvider();
  const { dir } = await builtWithVectors(CORPUS, provider);
  // A provider that cannot embed (no key) — degrade, don't fail.
  const keyless = { ...axisProvider(), async canEmbed() { return false; } };

  const writes = [];
  const origWrite = process.stderr.write.bind(process.stderr);
  process.stderr.write = (chunk, ...rest) => { writes.push(String(chunk)); return origWrite(chunk, ...rest); };
  __resetVectorFallbackLog();
  try {
    const r1 = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: keyless });
    const r2 = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: keyless });
    assert.equal(r1.ok, true);
    assert.equal(r1.retrievalMode, 'pglite-fts');
    assert.equal(r1.telemetry.vector.reason, 'no embedding key');
    assert.equal(r2.ok, true, 'a second recall still succeeds on the proven tier');
  } finally {
    process.stderr.write = origWrite;
  }
  const noKeyLogs = writes.filter((w) => /vectors unavailable.*no embedding key/.test(w));
  assert.equal(noKeyLogs.length, 1, 'the fallback is logged exactly once per process, not per call');
});

test('fallback: a provider error during query embedding degrades to FTS, never throws', async () => {
  const provider = axisProvider();
  const { dir } = await builtWithVectors(CORPUS, provider);
  const boom = { ...axisProvider(), async embed() { throw new Error('provider exploded'); } };
  __resetVectorFallbackLog();
  const r = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: boom });
  assert.equal(r.ok, true);
  assert.equal(r.retrievalMode, 'pglite-fts');
  assert.equal(r.telemetry.vector.status, 'fallback');
  assert.match(r.telemetry.vector.reason, /provider error/);
});

test('fallback: vectors requested but the generation has no vector manifest -> FTS', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  await buildRetrievalIndex(dir); // built WITHOUT vectors
  __resetVectorFallbackLog();
  const r = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: axisProvider() });
  assert.equal(r.retrievalMode, 'pglite-fts');
  assert.equal(r.telemetry.vector.status, 'fallback');
  assert.match(r.telemetry.vector.reason, /no vector manifest/);
});

test('build never fails on a provider error: FTS generation still publishes and serves', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  const throwing = { ...axisProvider(), async embedBatch() { throw new Error('embed outage'); } };
  const result = await buildRetrievalIndex(dir, { vectors: true, embeddingProvider: throwing });
  assert.equal(result.ok, true, 'the build succeeds despite the vector provider failing');
  assert.equal(result.vector.status, 'fallback');
  assert.match(result.vector.reason, /provider error/);
  // No vector artifacts were written; retrieval still serves FTS.
  const current = readCurrent(dir);
  const rp = retrievalPaths(dir);
  const genDir = path.resolve(rp.root, current.generationDir);
  assert.equal(readVectorArtifacts(genDir), null, 'no partial vector artifacts on a failed embed');
  const r = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship' });
  assert.equal(r.retrievalMode, 'pglite-fts');
  assert.deepEqual(r.selected.map((s) => s.id), ['MEM-0001', 'MEM-0002']);
});

test('incremental: an unchanged corpus reuses cached embeddings instead of re-embedding', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  const provider = axisProvider();
  const first = await buildRetrievalIndex(dir, { vectors: true, embeddingProvider: provider });
  assert.equal(first.vector.embeddedCount, 3);
  assert.equal(first.vector.reusedCount, 0);
  // Rebuild the SAME corpus: every record's contentHash is unchanged, so all
  // embeddings are reused from the prior generation and none is recomputed.
  const second = await buildRetrievalIndex(dir, { vectors: true, embeddingProvider: provider });
  assert.equal(second.vector.embeddedCount, 0, 'nothing re-embedded');
  assert.equal(second.vector.reusedCount, 3, 'all embeddings reused from the prior generation');
});

test('recall consumes the reordered ranking through the single authority (no re-ranking)', async () => {
  const provider = axisProvider();
  const { dir } = await builtWithVectors(CORPUS, provider);
  const pack = await recall({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: provider });
  assert.equal(pack.ok, true);
  assert.equal(pack.retrievalMode, 'hybrid-rank');
  // recall preserves the authority's order: MEM-0002 (query-aligned) leads.
  assert.deepEqual(pack.pointers.map((p) => p.id), ['MEM-0002', 'MEM-0001'], 'recall preserves the authority hybrid order');
  // The semantic-only record is never a governed pointer.
  assert.ok(!pack.pointers.some((p) => p.id === 'MEM-0003'));
});

test('the stub provider path also produces a working hybrid-rank retrieval', async () => {
  // Exercises the real deterministic stub end-to-end (build + query same provider).
  const stub = createStubEmbeddingProvider(64);
  const { dir } = await builtWithVectors(CORPUS, stub);
  const r = await retrieveMemory({ registryDir: dir, query: 'alpha beta', project: 'firstmate', kind: 'ship', vectors: true, embeddingProvider: stub });
  assert.equal(r.retrievalMode, 'hybrid-rank');
  assert.equal(r.selected.map((s) => s.id).sort().join(','), 'MEM-0001,MEM-0002', 'membership is the lexical-eligible set');
  for (const s of r.selected) assert.equal(typeof s.vectorSimilarity, 'number');
});
