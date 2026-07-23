import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { appendRegistryEvent } from '../lib/registry.mjs';
import {
  RETRIEVAL_CURRENT_SCHEMA,
  RETRIEVAL_INDEX_SCHEMA,
  buildRetrievalIndex,
  captureCanonical,
  cleanRetrievalIndex,
  inspectRetrievalIndex,
  readCurrent,
  retrievalPaths
} from '../lib/retrieval-index.mjs';
import { afterEach } from 'node:test';
import { loadPGlite } from '../lib/retrieval-pglite.mjs';
import { cleanTracked, seedActive, tmpRegistry } from './helpers.mjs';

// Derived generations are megabyte-scale PGlite data dirs; reclaim them per test.
afterEach(cleanTracked);

const CORPUS = [
  { id: 'MEM-0001', summary: 'stale watcher leaves idle done crew', keywords: ['watcher', 'stale'], projects: ['*'], taskKinds: ['*'] },
  { id: 'MEM-0002', summary: 'worktree project mismatch on primary checkout', keywords: ['worktree'], projects: ['firstmate'], taskKinds: ['ship'] }
];

test('full build produces a validated generation, complete watermark, and atomic current pointer', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  const result = await buildRetrievalIndex(dir);
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.equal(result.mode, 'pglite-fts');
  assert.equal(result.recordCount, 2);

  const rp = retrievalPaths(dir);
  const current = JSON.parse(fs.readFileSync(rp.current, 'utf8'));
  assert.equal(current.schema, RETRIEVAL_CURRENT_SCHEMA);
  assert.equal(current.generationId, result.generationId);

  const manifest = JSON.parse(fs.readFileSync(path.join(rp.generations, result.generationId, 'manifest.json'), 'utf8'));
  assert.equal(manifest.schema, RETRIEVAL_INDEX_SCHEMA);
  assert.equal(manifest.buildStatus, 'built');
  assert.equal(manifest.validation.ok, true);
  // Complete canonical watermark is stored (seq + eventId + registryHash).
  const captured = await captureCanonical(dir);
  assert.deepEqual(manifest.canonicalWatermark, captured.watermark);
  assert.ok(manifest.canonicalWatermark.seq > 0);
  assert.ok(manifest.canonicalWatermark.eventId);
  assert.ok(manifest.canonicalWatermark.registryHash);
  // Memory ID set stored in stable sorted order.
  assert.deepEqual(manifest.memoryIds, ['MEM-0001', 'MEM-0002']);
  assert.equal(manifest.recordCount, 2);
  assert.equal(manifest.activeIndexSchema, 'kraken-memory/active-index/v1');
  assert.ok(manifest.activeIndex.sha256, 'active-index sha256 recorded');
});

test('inspect reports current for a freshly built generation', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  await buildRetrievalIndex(dir);
  const status = await inspectRetrievalIndex(dir, await captureCanonical(dir));
  assert.equal(status.status, 'current');
});

test('a new build after canonical advances publishes a new generation atomically', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  const first = await buildRetrievalIndex(dir);
  await seedActive(dir, [{ id: 'MEM-0003', summary: 'exact-SHA lineage reconcile', keywords: ['lineage'], projects: ['*'], taskKinds: ['ship'] }]);
  const second = await buildRetrievalIndex(dir);
  assert.notEqual(second.generationId, first.generationId);
  assert.equal(readCurrent(dir).generationId, second.generationId);
  assert.equal((await inspectRetrievalIndex(dir, await captureCanonical(dir))).status, 'current');
});

test('missing detection: no current pointer', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  const status = await inspectRetrievalIndex(dir, await captureCanonical(dir));
  assert.equal(status.status, 'missing');
});

test('stale detection: canonical watermark advances after the last build', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  await buildRetrievalIndex(dir);
  // Advance canonical WITHOUT rebuilding the derived index.
  await appendRegistryEvent(dir, {
    event: 'proposed', memId: 'MEM-0003', actor: { kind: 'firstmate', id: 'p' }, fields: { summary: 'new candidate' }
  });
  const status = await inspectRetrievalIndex(dir, await captureCanonical(dir));
  assert.equal(status.status, 'stale');
  assert.match(status.reason, /watermark/);
});

test('corrupt detection: unreadable current pointer', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  await buildRetrievalIndex(dir);
  fs.writeFileSync(retrievalPaths(dir).current, '{ not json');
  const status = await inspectRetrievalIndex(dir, await captureCanonical(dir));
  assert.equal(status.status, 'corrupt');
});

test('corrupt detection: unreadable generation database', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  const built = await buildRetrievalIndex(dir);
  // Wreck the PGlite data directory so it cannot be opened.
  const pgliteDir = path.join(retrievalPaths(dir).generations, built.generationId, 'pglite');
  fs.rmSync(path.join(pgliteDir, 'PG_VERSION'), { force: true });
  fs.writeFileSync(path.join(pgliteDir, 'PG_VERSION'), 'garbage');
  const status = await inspectRetrievalIndex(dir, await captureCanonical(dir));
  assert.equal(status.status, 'corrupt');
});

test('partial detection: indexed id set is a subset of the verified active projection', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  const built = await buildRetrievalIndex(dir);
  const rp = retrievalPaths(dir);
  const genDir = path.join(rp.generations, built.generationId);

  // Delete one row from the generation DB and edit the manifest to match, so the
  // generation is SELF-consistent for {MEM-0001} while live canonical still holds
  // {MEM-0001, MEM-0002}: exactly the partial-index condition.
  const PGlite = await loadPGlite();
  const db = await PGlite.create({ dataDir: path.join(genDir, 'pglite') });
  await db.query('DELETE FROM memory_docs WHERE mem_id = $1', ['MEM-0002']);
  await db.close();

  const manifestPath = path.join(genDir, 'manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  manifest.recordCount = 1;
  manifest.memoryIds = ['MEM-0001'];
  manifest.records = manifest.records.filter((r) => r.id === 'MEM-0001');
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  const status = await inspectRetrievalIndex(dir, await captureCanonical(dir));
  assert.equal(status.status, 'partial');
});

test('clean removes abandoned generations but never the published current one', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  const built = await buildRetrievalIndex(dir);
  const rp = retrievalPaths(dir);

  // A crashed/unpublished scratch generation left behind.
  const scratch = path.join(rp.generations, 'fts-scratch-abandoned');
  fs.mkdirSync(path.join(scratch, 'pglite'), { recursive: true });
  fs.writeFileSync(path.join(scratch, 'build.log.jsonl'), '{"event":"build-start"}\n');

  // Its presence never displaces current: inspect still reports current.
  assert.equal((await inspectRetrievalIndex(dir, await captureCanonical(dir))).status, 'current');

  const cleaned = cleanRetrievalIndex(dir);
  assert.deepEqual(cleaned.removed, ['fts-scratch-abandoned']);
  assert.equal(cleaned.kept, built.generationId);
  assert.equal(fs.existsSync(scratch), false, 'abandoned generation removed');
  assert.equal(fs.existsSync(path.join(rp.generations, built.generationId)), true, 'current generation kept');
  // Current still usable after clean.
  assert.equal((await inspectRetrievalIndex(dir, await captureCanonical(dir))).status, 'current');
});

test('build fails (not fallback) when canonical active index is unverified', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, CORPUS);
  // Corrupt the active index so canonical verification fails.
  const rp = retrievalPaths(dir);
  fs.writeFileSync(rp.registry.index, `${JSON.stringify({ schema: 'kraken-memory/active-index/v1', generatedAt: 'x', registry: { seq: 99, eventId: 'x', registryHash: 'x' }, recordCount: 0, records: [] }, null, 2)}\n`);
  const result = await buildRetrievalIndex(dir);
  assert.equal(result.ok, false);
  assert.equal(result.mode, 'failed');
  assert.match(result.reason, /active-index/);
});
