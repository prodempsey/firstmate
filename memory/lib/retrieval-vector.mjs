// Optional, non-authoritative rank-only vector reranking.
//
// Vectors are DEFERRED to PR-2b: PR-2 wires no embedding provider and adds no
// pgvector dependency, so the default retrieval path reports vectors disabled and
// never calls into this module. What lives here is the pure, offline contract that
// PR-2b (or a test) can drive with caller-supplied vectors, encoding the two
// invariants the architecture requires:
//   1. Vectors may only REORDER candidates that already passed the lexical
//      evidence threshold; they can never make an ineligible record selectable.
//   2. A semantic-only match (a vector neighbor with no lexical evidence) is
//      returned, if at all, as a non-selectable diagnostic with reason
//      `vector-only`, and is never eligible for governed injection.
// No network calls, no randomness, no provider keys are read here.

export const VECTOR_MANIFEST_SCHEMA = 'kraken-memory/retrieval-vector/v1';

// Validate a caller-supplied vector manifest against the retrieval generation it
// claims to describe. Rank-only vectors are usable only when the manifest names a
// provider/model/dimensions and is bound to the current generation.
export function validateVectorManifest(manifest, generationId) {
  if (!manifest || typeof manifest !== 'object') return { valid: false, reason: 'vector manifest missing' };
  if (manifest.schema !== VECTOR_MANIFEST_SCHEMA) return { valid: false, reason: 'vector manifest schema mismatch' };
  if (!manifest.provider || !manifest.model) return { valid: false, reason: 'vector manifest missing provider/model' };
  if (!Number.isInteger(manifest.dimensions) || manifest.dimensions <= 0) return { valid: false, reason: 'vector manifest dimensions invalid' };
  if (manifest.generationId !== generationId) return { valid: false, reason: 'vector manifest not bound to current generation' };
  return { valid: true, reason: null };
}

export function cosineSimilarity(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length === 0 || a.length !== b.length) return 0;
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i += 1) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na === 0 || nb === 0) return 0;
  return dot / (Math.sqrt(na) * Math.sqrt(nb));
}

// Rank-only rerank. `eligible` is the lexically-eligible candidate list (each item
// carries at least { id, score, matchedTermCount, verifiedAt, recordedAt }).
// `queryVector` and `vectorsById` supply the optional semantic signal.
//
// Returns { reranked, semanticOnly }:
//   * reranked: the SAME eligible set, re-ordered by (vectorSimilarity, then the
//     original deterministic order). No eligible record is dropped or added.
//   * semanticOnly: ids that have a vector neighbor above `threshold` but are NOT
//     in the eligible set, each marked non-selectable with reason `vector-only`.
export function rerankByVectors(eligible, { queryVector, vectorsById, threshold = 0 } = {}) {
  if (!Array.isArray(queryVector) || !(vectorsById instanceof Map) || vectorsById.size === 0) {
    return { reranked: eligible.slice(), semanticOnly: [] };
  }
  const eligibleIds = new Set(eligible.map((c) => c.id));
  const withSim = eligible.map((c, index) => ({
    ...c,
    vectorSimilarity: cosineSimilarity(queryVector, vectorsById.get(c.id) || []),
    _origin: index
  }));
  // Rank-only: similarity influences order, but ties fall back to the original
  // deterministic lexical order so the result is fully reproducible.
  withSim.sort((a, b) => (b.vectorSimilarity - a.vectorSimilarity) || (a._origin - b._origin));
  const reranked = withSim.map(({ _origin, ...rest }) => rest);

  const semanticOnly = [];
  for (const [id, vec] of vectorsById) {
    if (eligibleIds.has(id)) continue;
    const sim = cosineSimilarity(queryVector, vec);
    if (sim > threshold) semanticOnly.push({ id, vectorSimilarity: sim, selectable: false, reason: 'vector-only' });
  }
  semanticOnly.sort((a, b) => (b.vectorSimilarity - a.vectorSimilarity) || (a.id < b.id ? -1 : 1));
  return { reranked, semanticOnly };
}
