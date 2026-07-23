import assert from 'node:assert/strict';
import test from 'node:test';
import {
  NORMALIZER_VERSION,
  buildSearchText,
  extractPhrases,
  normalizeQuery,
  recordLexicalFields,
  tokenize
} from '../lib/retrieval-normalize.mjs';

test('tokenize is deterministic and NFC/lowercase-normalized', () => {
  // Composed vs decomposed forms of "é" must normalize to the same token.
  const composed = tokenize('Café Watcher');
  const decomposed = tokenize('Café Watcher');
  assert.deepEqual(composed, decomposed);
  assert.ok(composed.terms.includes('café'));
  assert.ok(composed.terms.includes('watcher'));
});

test('tokenize splits hyphen/underscore boundaries while retaining the compound token', () => {
  const { terms } = tokenize('fm-teardown ghost_card');
  assert.ok(terms.includes('fm-teardown'), 'compound retained');
  assert.ok(terms.includes('fm'));
  assert.ok(terms.includes('teardown'));
  assert.ok(terms.includes('ghost_card'));
  assert.ok(terms.includes('ghost'));
  assert.ok(terms.includes('card'));
});

test('exact IDs (with a digit) are preserved as id tokens; plain hyphenated words are not', () => {
  const withIds = tokenize('MEM-0007 ORD-261 fix-login-k3 merge-base read-only');
  assert.deepEqual(withIds.ids.sort(), ['fix-login-k3', 'mem-0007', 'ord-261'].sort());
  // merge-base / read-only carry no digit, so they are ordinary words, not IDs.
  assert.ok(!withIds.ids.includes('merge-base'));
  assert.ok(!withIds.ids.includes('read-only'));
});

test('curated abbreviations expand deterministically alongside the original token', () => {
  const { terms } = tokenize('wm mismatch');
  assert.ok(terms.includes('wm'), 'original kept');
  assert.ok(terms.includes('watermark'), 'expansion added');
  assert.ok(terms.includes('mismatch'));
});

test('extractPhrases returns normalized quoted phrases only', () => {
  const phrases = extractPhrases('find "Exact-SHA Lineage" and "Ghost Card" now');
  assert.deepEqual(phrases, ['exact-sha lineage', 'ghost card']);
  assert.deepEqual(extractPhrases('no quotes here'), []);
});

test('normalizeQuery is stable across repeated calls', () => {
  const a = normalizeQuery('Stale WATCHER "idle done" MEM-0001');
  const b = normalizeQuery('Stale WATCHER "idle done" MEM-0001');
  assert.deepEqual(a, b);
  assert.deepEqual(a.phrases, ['idle done']);
  assert.ok(a.ids.includes('mem-0001'));
  assert.equal(a.normalizedTermCount, a.terms.length);
});

test('buildSearchText is byte-stable and field-ordered for a fixed record', () => {
  const record = {
    id: 'MEM-0001',
    summary: 'Stale watcher',
    keywords: ['Watcher', 'stale'],
    entities: ['fm-teardown'],
    scope: 'fleet',
    projects: ['firstmate'],
    taskKinds: ['ship'],
    source: { path: 'data/learnings.md', anchor: 'watcher' }
  };
  const first = buildSearchText(record);
  const second = buildSearchText(record);
  assert.equal(first, second);
  assert.match(first, /mem-0001/);
  assert.match(first, /data\/learnings\.md/);
  assert.equal(first, first.toLowerCase());
});

test('recordLexicalFields exposes id/curated/summary/all surfaces', () => {
  const fields = recordLexicalFields({
    id: 'MEM-0002',
    summary: 'worktree mismatch',
    keywords: ['isolation'],
    projects: ['firstmate'],
    taskKinds: ['ship']
  });
  assert.ok(fields.idSet.has('mem-0002'));
  assert.ok(fields.curatedTerms.has('isolation'));
  assert.ok(fields.summaryTerms.has('worktree'));
  assert.ok(fields.allTerms.has('mismatch'));
});

test('normalizer version is a stable, non-empty contract string', () => {
  assert.equal(typeof NORMALIZER_VERSION, 'string');
  assert.match(NORMALIZER_VERSION, /retrieval-normalize\/v1$/);
});
