import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test, { afterEach } from 'node:test';
import { buildRetrievalIndex, retrievalPaths } from '../lib/retrieval-index.mjs';
import { DEFAULT_BUDGET, RECALL_MANIFEST_SCHEMA, RECALL_PACK_SCHEMA, recall } from '../lib/recall.mjs';
import { registryDir } from '../lib/paths.mjs';
import { cleanTracked, seedActive, tmpRegistry } from './helpers.mjs';

// Derived generations are megabyte-scale PGlite data dirs; reclaim them per test.
afterEach(cleanTracked);

const CORPUS = [
  { id: 'MEM-0001', summary: 'stale watcher leaves idle done crew waiting', keywords: ['watcher', 'stale'], memoryType: 'procedural', scope: 'fleet', projects: ['*'], taskKinds: ['*'] },
  { id: 'MEM-0002', summary: 'worktree project mismatch on primary checkout', keywords: ['worktree', 'isolation'], memoryType: 'factual', scope: 'project', projects: ['firstmate'], taskKinds: ['ship'] },
  { id: 'MEM-0003', summary: 'exact-SHA lineage reconcile before merge', keywords: ['lineage'], memoryType: 'procedural', scope: 'fleet', projects: ['*'], taskKinds: ['landing'] }
];

async function built(specs = CORPUS) {
  const dir = tmpRegistry();
  await seedActive(dir, specs);
  await buildRetrievalIndex(dir);
  return dir;
}

test('recall consumes the retrieve authority and returns pointer-only entries', async () => {
  const dir = await built();
  const pack = await recall({ registryDir: dir, query: 'stale watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.schema, RECALL_PACK_SCHEMA);
  assert.equal(pack.ok, true);
  assert.equal(pack.state, 'proven');
  assert.equal(pack.retrievalMode, 'pglite-fts');
  assert.deepEqual(pack.pointers.map((p) => p.id), ['MEM-0001']);
  const p = pack.pointers[0];
  // Pointer-only: id, summary, source, facets, reasons, show command - NEVER a body.
  assert.equal(p.summary, 'stale watcher leaves idle done crew waiting');
  assert.equal(p.memoryType, 'procedural');
  assert.equal(p.showCommand, 'mem show MEM-0001');
  assert.ok(Array.isArray(p.matchReasons) && p.matchReasons.length > 0);
  assert.equal('body' in p, false, 'pointer must not carry the memory body');
});

test('recall ranking matches the authority and never re-litigates scores', async () => {
  const dir = await built();
  const pack = await recall({ registryDir: dir, query: 'watcher lineage worktree', project: 'firstmate', kind: 'ship' });
  const again = await recall({ registryDir: dir, query: 'watcher lineage worktree', project: 'firstmate', kind: 'ship' });
  assert.deepEqual(pack.pointers.map((p) => p.id), again.pointers.map((p) => p.id));
  // No score field leaks into the pointer (recall does not re-rank).
  for (const p of pack.pointers) assert.equal('score' in p, false);
});

test('memory-type filter drops off-type candidates with a stable omitted reason', async () => {
  const dir = await built();
  const pack = await recall({ registryDir: dir, query: 'watcher lineage worktree', project: 'firstmate', kind: 'ship', memoryTypes: ['factual'] });
  assert.deepEqual(pack.pointers.map((p) => p.id), ['MEM-0002']);
  const omittedProc = pack.omitted.filter((o) => o.reason === 'type-filtered').map((o) => o.id).sort();
  assert.deepEqual(omittedProc, ['MEM-0001']);
});

test('pointer budget caps entry count, dropping lowest rank with a named reason', async () => {
  const dir = await built();
  const pack = await recall({ registryDir: dir, query: 'watcher lineage worktree', project: 'firstmate', kind: 'ship', budget: { maxPointers: 1 } });
  assert.equal(pack.pointers.length, 1);
  assert.ok(pack.omitted.some((o) => o.reason === 'pointer-budget-count'));
  // The kept pointer is the top-ranked one, and no summary was truncated.
  assert.equal(pack.pointers[0].summary.endsWith('…'), false);
});

test('byte budget omits whole lowest-rank entries until the section fits', async () => {
  const dir = await built();
  // A tiny byte budget that admits only the first ranked pointer.
  const full = await recall({ registryDir: dir, query: 'watcher lineage worktree', project: 'firstmate', kind: 'ship' });
  assert.ok(full.pointers.length >= 2, 'need at least two candidates for this test');
  const pack = await recall({ registryDir: dir, query: 'watcher lineage worktree', project: 'firstmate', kind: 'ship', budget: { maxBytes: 80 } });
  assert.ok(pack.pointers.length < full.pointers.length);
  assert.ok(pack.usedBytes <= 80);
  assert.ok(pack.omitted.some((o) => o.reason === 'pointer-budget-bytes'));
});

test('the manifest is a deterministic replay fingerprint of the recall inputs', async () => {
  const dir = await built();
  // asOf is a real replay input (it drives validity filtering), so it is part of
  // the fingerprint; pin it to prove identical inputs -> identical id.
  const asOf = '2026-07-23T00:00:00.000Z';
  const a = await recall({ registryDir: dir, query: 'stale watcher', project: 'firstmate', kind: 'ship', asOf });
  const b = await recall({ registryDir: dir, query: 'stale watcher', project: 'firstmate', kind: 'ship', asOf });
  assert.equal(a.manifest.schema, RECALL_MANIFEST_SCHEMA);
  assert.equal(a.manifest.manifestId, b.manifest.manifestId, 'identical inputs -> identical manifest id');
  assert.equal(a.manifest.querySha256, crypto.createHash('sha256').update('stale watcher').digest('hex'));
  assert.deepEqual(a.manifest.injectedIds, a.pointers.map((p) => p.id));
  assert.ok(a.manifest.canonicalWatermark.seq > 0);
  // A different query changes the fingerprint.
  const c = await recall({ registryDir: dir, query: 'lineage', project: 'firstmate', kind: 'ship', asOf });
  assert.notEqual(a.manifest.manifestId, c.manifest.manifestId);
});

test('a proven zero-hit is a successful recall with no pointers (not a failure)', async () => {
  const dir = await built();
  const pack = await recall({ registryDir: dir, query: 'nonexistent-token-xyzzy', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.ok, true);
  assert.equal(pack.state, 'proven');
  assert.deepEqual(pack.pointers, []);
  assert.ok(pack.counts.active > 0, 'active memories exist; this is a zero-hit, not an empty registry');
});

test('an empty registry recalls inert: proven, zero pointers, zero active', async () => {
  const dir = tmpRegistry();
  const { appendRegistryEvent, buildActiveIndex } = await import('../lib/registry.mjs');
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'firstmate', id: 'p' }, fields: { summary: 'candidate only' } });
  buildActiveIndex(dir);
  const pack = await recall({ registryDir: dir, query: 'watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.ok, true);
  assert.equal(pack.state, 'proven');
  assert.deepEqual(pack.pointers, []);
  assert.equal(pack.counts.active, 0);
});

test('a stale/missing derived index degrades to a PROVEN lexical-fallback recall', async () => {
  const dir = await built();
  fs.rmSync(retrievalPaths(dir).current, { force: true });
  const pack = await recall({ registryDir: dir, query: 'stale watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.ok, true);
  assert.equal(pack.state, 'proven');
  assert.equal(pack.retrievalMode, 'lexical-fallback');
  assert.equal(pack.retrievalGeneration, null);
  assert.deepEqual(pack.pointers.map((p) => p.id), ['MEM-0001']);
});

test('a canonical failure fails open: recall-failed, zero pointers, never fail-wrong', async () => {
  const dir = await built();
  fs.writeFileSync(retrievalPaths(dir).registry.registry, '{bad');
  const pack = await recall({ registryDir: dir, query: 'watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.ok, false);
  assert.equal(pack.state, 'recall-failed');
  assert.deepEqual(pack.pointers, []);
  assert.equal(pack.retrievalGeneration, null);
});

test('an absent registry fails open rather than throwing', async () => {
  const pack = await recall({ registryDir: path.join(tmpRegistry(), 'nope'), query: 'x', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.ok, false);
  assert.equal(pack.state, 'recall-failed');
  assert.deepEqual(pack.pointers, []);
});

test('default budget values are exposed and applied when unspecified', async () => {
  const dir = await built();
  const pack = await recall({ registryDir: dir, query: 'watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.budget.maxPointers, DEFAULT_BUDGET.maxPointers);
  assert.equal(pack.budget.maxBytes, DEFAULT_BUDGET.maxBytes);
});

test('project/kind filters still flow through to the authority', async () => {
  const dir = await built();
  // MEM-0002 is project=firstmate kind=ship; MEM-0003 is kind=landing. A ship-kind
  // recall scoped to firstmate must not surface the landing-only record.
  const pack = await recall({ registryDir: dir, query: 'worktree lineage', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.pointers.some((p) => p.id === 'MEM-0003'), false);
});

test('production memory registry is untouched by a recall cycle', async () => {
  const prod = registryDir({ HOME: process.env.HOME });
  const inventory = (root) => {
    if (!fs.existsSync(root)) return { absent: true };
    const out = {};
    const walk = (base) => {
      for (const entry of fs.readdirSync(base, { withFileTypes: true })) {
        const full = path.join(base, entry.name);
        if (entry.isDirectory()) walk(full);
        else {
          const st = fs.statSync(full);
          out[path.relative(root, full)] = `${st.size}:${st.mtimeMs}:${crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex')}`;
        }
      }
    };
    walk(root);
    return out;
  };
  const before = inventory(prod);
  const dir = await built();
  await recall({ registryDir: dir, query: 'watcher lineage', project: 'firstmate', kind: 'ship' });
  assert.deepEqual(inventory(prod), before, 'production memory registry inventory unchanged');
});
