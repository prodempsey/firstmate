import assert from 'node:assert/strict';
import test from 'node:test';
import {
  VECTOR_MANIFEST_SCHEMA,
  cosineSimilarity,
  rerankByVectors,
  validateVectorManifest
} from '../lib/retrieval-vector.mjs';

function eligible(...ids) {
  return ids.map((id, i) => ({ id, score: 100 - i, matchedTermCount: 1, verifiedAt: null, recordedAt: null }));
}

test('validateVectorManifest accepts a well-formed, generation-bound manifest', () => {
  const manifest = { schema: VECTOR_MANIFEST_SCHEMA, provider: 'mock', model: 'm1', dimensions: 3, generationId: 'gen-1' };
  assert.deepEqual(validateVectorManifest(manifest, 'gen-1'), { valid: true, reason: null });
});

test('validateVectorManifest rejects missing/invalid/mismatched manifests', () => {
  assert.equal(validateVectorManifest(null, 'gen-1').valid, false);
  assert.equal(validateVectorManifest({ schema: 'wrong', provider: 'm', model: 'm1', dimensions: 3, generationId: 'gen-1' }, 'gen-1').valid, false);
  assert.equal(validateVectorManifest({ schema: VECTOR_MANIFEST_SCHEMA, model: 'm1', dimensions: 3, generationId: 'gen-1' }, 'gen-1').valid, false);
  assert.equal(validateVectorManifest({ schema: VECTOR_MANIFEST_SCHEMA, provider: 'm', model: 'm1', dimensions: 0, generationId: 'gen-1' }, 'gen-1').valid, false);
  assert.equal(validateVectorManifest({ schema: VECTOR_MANIFEST_SCHEMA, provider: 'm', model: 'm1', dimensions: 3, generationId: 'gen-2' }, 'gen-1').valid, false);
});

test('cosineSimilarity is bounded and safe on degenerate inputs', () => {
  assert.equal(cosineSimilarity([1, 0], [1, 0]), 1);
  assert.equal(cosineSimilarity([1, 0], [0, 1]), 0);
  assert.equal(cosineSimilarity([0, 0], [1, 1]), 0);
  assert.equal(cosineSimilarity([1, 2], [1, 2, 3]), 0, 'dimension mismatch is zero, not a throw');
});

test('disabled by default: no query vector or no vectors is a pure no-op preserving order', () => {
  const set = eligible('MEM-0001', 'MEM-0002');
  const a = rerankByVectors(set, {});
  assert.deepEqual(a.reranked.map((c) => c.id), ['MEM-0001', 'MEM-0002']);
  assert.deepEqual(a.semanticOnly, []);
  const b = rerankByVectors(set, { queryVector: [1, 0], vectorsById: new Map() });
  assert.deepEqual(b.reranked.map((c) => c.id), ['MEM-0001', 'MEM-0002']);
});

test('rank-only: vectors reorder ONLY already-eligible candidates, never adding or dropping', () => {
  const set = eligible('MEM-0001', 'MEM-0002'); // MEM-0001 first by lexical score
  const vectorsById = new Map([
    ['MEM-0001', [0, 1]],
    ['MEM-0002', [1, 0]]
  ]);
  const { reranked } = rerankByVectors(set, { queryVector: [1, 0], vectorsById });
  // Query aligns with MEM-0002's vector, so it reorders ahead — but the set is
  // identical (no id added or removed).
  assert.deepEqual(reranked.map((c) => c.id).sort(), ['MEM-0001', 'MEM-0002']);
  assert.equal(reranked[0].id, 'MEM-0002');
  assert.equal(reranked.length, set.length);
});

test('semantic-only matches are returned as non-selectable diagnostics with reason vector-only', () => {
  const set = eligible('MEM-0001'); // only MEM-0001 is lexically eligible
  const vectorsById = new Map([
    ['MEM-0001', [1, 0]],
    ['MEM-0009', [1, 0]] // strong vector neighbor but NOT lexically eligible
  ]);
  const { reranked, semanticOnly } = rerankByVectors(set, { queryVector: [1, 0], vectorsById });
  // MEM-0009 never becomes selectable.
  assert.deepEqual(reranked.map((c) => c.id), ['MEM-0001']);
  assert.equal(semanticOnly.length, 1);
  assert.equal(semanticOnly[0].id, 'MEM-0009');
  assert.equal(semanticOnly[0].selectable, false);
  assert.equal(semanticOnly[0].reason, 'vector-only');
});

test('reranking is deterministic: equal similarities keep the original lexical order', () => {
  const set = eligible('MEM-0001', 'MEM-0002', 'MEM-0003');
  const vectorsById = new Map([
    ['MEM-0001', [1, 0]],
    ['MEM-0002', [1, 0]],
    ['MEM-0003', [1, 0]]
  ]);
  const a = rerankByVectors(set, { queryVector: [1, 0], vectorsById });
  const b = rerankByVectors(set, { queryVector: [1, 0], vectorsById });
  assert.deepEqual(a.reranked.map((c) => c.id), ['MEM-0001', 'MEM-0002', 'MEM-0003']);
  assert.deepEqual(a.reranked.map((c) => c.id), b.reranked.map((c) => c.id));
});
