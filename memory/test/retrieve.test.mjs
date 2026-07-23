import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { buildRetrievalIndex, retrievalPaths } from '../lib/retrieval-index.mjs';
import { RETRIEVAL_MODES, RETRIEVAL_TELEMETRY_SCHEMA, buildTsquery, retrieveMemory } from '../lib/retrieve.mjs';
import { afterEach } from 'node:test';
import { readCurrent } from '../lib/retrieval-index.mjs';
import { loadPGlite } from '../lib/retrieval-pglite.mjs';
import { registryDir } from '../lib/paths.mjs';
import { cleanTracked, seedActive, tmpRegistry } from './helpers.mjs';

// Derived generations are megabyte-scale PGlite data dirs; reclaim them per test.
afterEach(cleanTracked);

const CORPUS = [
  { id: 'MEM-0001', summary: 'stale watcher leaves idle done crew waiting', keywords: ['watcher', 'stale', 'teardown'], projects: ['*'], taskKinds: ['*'] },
  { id: 'MEM-0002', summary: 'worktree project mismatch on primary checkout', keywords: ['worktree', 'isolation'], projects: ['firstmate'], taskKinds: ['ship'] },
  { id: 'MEM-0003', summary: 'exact-SHA lineage reconcile before merge', keywords: ['lineage', 'ancestor'], entities: ['merge-base'], projects: ['*'], taskKinds: ['landing'] }
];

async function built(specs = CORPUS) {
  const dir = tmpRegistry();
  await seedActive(dir, specs);
  await buildRetrievalIndex(dir);
  return dir;
}

test('RETRIEVAL_MODES reserves all four telemetry modes including hybrid-rank', () => {
  assert.deepEqual([...RETRIEVAL_MODES], ['pglite-fts', 'lexical-fallback', 'hybrid-rank', 'failed']);
});

test('pglite-fts mode returns relevant records and exercises the FTS index (ts_rank)', async () => {
  const dir = await built();
  const r = await retrieveMemory({ registryDir: dir, query: 'stale watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(r.ok, true);
  assert.equal(r.retrievalMode, 'pglite-fts');
  assert.deepEqual(r.selected.map((s) => s.id), ['MEM-0001']);
  assert.equal(typeof r.selected[0].ftsRank, 'number', 'ts_rank surfaced from the derived index');
  assert.equal(r.telemetry.schema, RETRIEVAL_TELEMETRY_SCHEMA);
  assert.equal(r.telemetry.pglite.status, 'current');
});

test('exact ID and quoted phrase matching select precisely', async () => {
  const dir = await built();
  const byId = await retrieveMemory({ registryDir: dir, query: 'MEM-0002', project: 'firstmate', kind: 'ship' });
  assert.deepEqual(byId.selected.map((s) => s.id), ['MEM-0002']);
  assert.ok(byId.selected[0].evidence.exactId >= 1);

  const byPhrase = await retrieveMemory({ registryDir: dir, query: '"exact-sha lineage"', project: 'firstmate', kind: 'landing' });
  assert.deepEqual(byPhrase.selected.map((s) => s.id), ['MEM-0003']);
  assert.ok(byPhrase.selected[0].evidence.phrase >= 1);
});

test('generic single-token false positives are rejected as insufficient-signal', async () => {
  const dir = await built();
  const r = await retrieveMemory({ registryDir: dir, query: 'before', project: 'firstmate', kind: 'landing' });
  // "before" appears only in MEM-0003's summary as a lone generic term: not eligible.
  assert.equal(r.selected.length, 0);
  const reason = r.rejected.find((x) => x.id === 'MEM-0003')?.reason;
  assert.ok(['insufficient-signal', 'score-0'].includes(reason), `unexpected reason ${reason}`);
});

test('project/kind/scope/validity filtering rejects with stable reasons', async () => {
  const dir = tmpRegistry();
  await seedActive(dir, [
    { id: 'MEM-0001', summary: 'watcher note', keywords: ['watcher'], projects: ['firstmate'], taskKinds: ['ship'], scope: 'fleet' },
    { id: 'MEM-0002', summary: 'watcher note two', keywords: ['watcher'], projects: ['other'], taskKinds: ['ship'], scope: 'project' },
    { id: 'MEM-0003', summary: 'watcher note three', keywords: ['watcher'], projects: ['firstmate'], taskKinds: ['scout'], scope: 'fleet' },
    { id: 'MEM-0004', summary: 'watcher expired', keywords: ['watcher'], projects: ['firstmate'], taskKinds: ['ship'], scope: 'fleet', validTo: '2000-01-01' }
  ]);
  await buildRetrievalIndex(dir);
  const r = await retrieveMemory({ registryDir: dir, query: 'watcher', project: 'firstmate', kind: 'ship', scopes: ['fleet'] });
  const reasonById = Object.fromEntries(r.rejected.map((x) => [x.id, x.reason]));
  assert.equal(reasonById['MEM-0002'], 'ineligible-project');
  assert.equal(reasonById['MEM-0003'], 'ineligible-kind');
  assert.equal(reasonById['MEM-0004'], 'outside-validity');
  assert.deepEqual(r.selected.map((s) => s.id), ['MEM-0001']);
});

test('ranking and tie-breaking are deterministic across repeated calls', async () => {
  const dir = await built();
  const a = await retrieveMemory({ registryDir: dir, query: 'watcher lineage worktree', project: 'firstmate', kind: 'ship' });
  const b = await retrieveMemory({ registryDir: dir, query: 'watcher lineage worktree', project: 'firstmate', kind: 'ship' });
  assert.deepEqual(a.selected.map((s) => s.id), b.selected.map((s) => s.id));
  assert.deepEqual(a.selected.map((s) => s.score), b.selected.map((s) => s.score));
});

test('tie-break falls to memory id ascending when scores and counts match', async () => {
  const dir = tmpRegistry();
  // Two records with identical retrievable content, no verified/recorded ordering signal difference.
  await seedActive(dir, [
    { id: 'MEM-0002', summary: 'watcher stale note', keywords: ['watcher'], projects: ['*'], taskKinds: ['*'] },
    { id: 'MEM-0001', summary: 'watcher stale note', keywords: ['watcher'], projects: ['*'], taskKinds: ['*'] }
  ]);
  await buildRetrievalIndex(dir);
  const r = await retrieveMemory({ registryDir: dir, query: 'watcher stale', project: 'firstmate', kind: 'ship' });
  const ids = r.selected.map((s) => s.id);
  assert.deepEqual(ids, [...ids].sort(), 'equal candidates ordered by id ascending');
});

test('canonical failure returns failed, never lexical fallback', async () => {
  const dir = await built();
  // Corrupt the canonical registry -> critical.
  fs.writeFileSync(retrievalPaths(dir).registry.registry, '{bad');
  const r = await retrieveMemory({ registryDir: dir, query: 'watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(r.ok, false);
  assert.equal(r.retrievalMode, 'failed');
  assert.equal(r.selected.length, 0);
  assert.match(r.fallbackReason, /registry-critical|active-index/);
});

test('PGlite failure with a healthy canonical index degrades to lexical-fallback', async () => {
  const dir = await built();
  // Remove the derived generation pointer -> pglite missing, canonical still healthy.
  fs.rmSync(retrievalPaths(dir).current, { force: true });
  const r = await retrieveMemory({ registryDir: dir, query: 'stale watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(r.ok, true);
  assert.equal(r.retrievalMode, 'lexical-fallback');
  assert.match(r.fallbackReason, /pglite-missing/);
  assert.deepEqual(r.selected.map((s) => s.id), ['MEM-0001']);
});

test('pglite-fts and lexical-fallback select the same set and order for the same corpus', async () => {
  const dir = await built();
  const fts = await retrieveMemory({ registryDir: dir, query: 'watcher lineage', project: 'firstmate', kind: 'ship' });
  fs.rmSync(retrievalPaths(dir).current, { force: true });
  const lex = await retrieveMemory({ registryDir: dir, query: 'watcher lineage', project: 'firstmate', kind: 'ship' });
  assert.equal(fts.retrievalMode, 'pglite-fts');
  assert.equal(lex.retrievalMode, 'lexical-fallback');
  assert.deepEqual(fts.selected.map((s) => s.id), lex.selected.map((s) => s.id));
  assert.deepEqual(fts.selected.map((s) => s.score), lex.selected.map((s) => s.score));
});

test('pglite-fts gates selection to the FTS match set: a record the FTS index did not return is not selected', async () => {
  // MEM-0002's only signal is the curated keyword "wm". The JS lexical layer expands
  // "wm" -> "watermark", but the FTS *document* is indexed from raw field text, so a
  // "watermark" query does NOT FTS-match MEM-0002. In pglite-fts mode it must NOT be
  // selected (FTS is the candidate generator); lexical fallback, which scans the full
  // projection with abbreviation expansion, MAY select it. This is the F1 boundary.
  const dir = tmpRegistry();
  await seedActive(dir, [
    { id: 'MEM-0001', summary: 'unrelated note', keywords: ['unrelated'], projects: ['*'], taskKinds: ['*'] },
    { id: 'MEM-0002', summary: 'abbrev only', keywords: ['wm'], projects: ['*'], taskKinds: ['*'] }
  ]);
  await buildRetrievalIndex(dir);
  const fts = await retrieveMemory({ registryDir: dir, query: 'watermark', project: 'firstmate', kind: 'ship' });
  assert.equal(fts.retrievalMode, 'pglite-fts');
  assert.equal(fts.selected.find((s) => s.id === 'MEM-0002'), undefined, 'not an FTS candidate -> not selected in pglite-fts');
  assert.equal(fts.candidateDiagnostics.find((d) => d.id === 'MEM-0002').ftsMatched, false);

  fs.rmSync(retrievalPaths(dir).current, { force: true });
  const lex = await retrieveMemory({ registryDir: dir, query: 'watermark', project: 'firstmate', kind: 'ship' });
  assert.equal(lex.retrievalMode, 'lexical-fallback');
  assert.deepEqual(lex.selected.map((s) => s.id), ['MEM-0002'], 'fallback scans the full projection with abbreviation expansion');
});

test('an internally inconsistent FTS surface is treated as corrupt and forces lexical-fallback, not a false pglite-fts', async () => {
  const dir = await built();
  const gen = readCurrent(dir).generationId;
  const dataDir = `${retrievalPaths(dir).generations}/${gen}/pglite`;
  const PGlite = await loadPGlite();
  const db = await PGlite.create({ dataDir });
  await db.query("UPDATE memory_fts SET document = to_tsvector('simple', '')"); // empty every FTS document
  await db.close();
  const r = await retrieveMemory({ registryDir: dir, query: 'stale watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(r.retrievalMode, 'lexical-fallback');
  assert.match(r.fallbackReason, /pglite-corrupt/);
  assert.deepEqual(r.selected.map((s) => s.id), ['MEM-0001']);
});

test('telemetry carries the complete canonical watermark, filters, counts, and query hash', async () => {
  const dir = await built();
  const r = await retrieveMemory({ registryDir: dir, query: 'stale watcher', project: 'firstmate', kind: 'ship', scopes: ['fleet'] });
  const t = r.telemetry;
  assert.ok(t.canonicalWatermark.seq > 0 && t.canonicalWatermark.eventId && t.canonicalWatermark.registryHash);
  assert.equal(t.filters.project, 'firstmate');
  assert.equal(t.filters.kind, 'ship');
  assert.deepEqual(t.filters.scopes, ['fleet']);
  assert.equal(t.query.sha256, crypto.createHash('sha256').update('stale watcher').digest('hex'));
  assert.equal(t.vector.enabled, false);
  assert.equal(t.vector.status, 'disabled');
  assert.equal(t.counts.selected, r.selected.length);
});

test('buildTsquery emits a safe OR-of-lexemes string of alphanumeric lexemes only', () => {
  const q = buildTsquery(['fm-teardown', 'fm', 'teardown', 'MEM-0001', "wa'tch"]);
  assert.equal(q.includes("'"), false, 'no quote characters leak into the tsquery');
  assert.match(q, /\|/);
  for (const lexeme of q.split(' | ')) assert.match(lexeme, /^[a-z0-9]+$/);
});

test('empty active corpus retrieves cleanly with no selection and no error', async () => {
  const dir = tmpRegistry();
  // A registry with only a candidate (no active records), then a projected active
  // index over it: canonical verifies, but there is nothing to select. Mirrors the
  // production registry, which currently has zero active memories.
  const { appendRegistryEvent, buildActiveIndex } = await import('../lib/registry.mjs');
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'firstmate', id: 'p' }, fields: { summary: 'candidate only' } });
  buildActiveIndex(dir);
  const r = await retrieveMemory({ registryDir: dir, query: 'watcher', project: 'firstmate', kind: 'ship' });
  assert.equal(r.ok, true);
  assert.deepEqual(r.selected, []);
});

test('production memory registry is never touched by a full retrieval build + retrieve cycle', async () => {
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
  await retrieveMemory({ registryDir: dir, query: 'watcher lineage', project: 'firstmate', kind: 'ship' });
  const after = inventory(prod);
  assert.deepEqual(after, before, 'production memory registry inventory unchanged');
});
