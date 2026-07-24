// Backend-neutral retrieval interface. PR-4 will call retrieveMemory() to obtain
// governed candidates; PR-2 exposes it via `mem retrieve` only and wires it into
// no workflow, brief, spawn, or UI surface.
//
// Layering:
//   * Canonical verification (PR-1 authority) decides failed vs proceed.
//   * The derived PGlite FTS generation, when healthy, is queried to exercise the
//     index and produce ts_rank telemetry (retrievalMode `pglite-fts`); when it is
//     missing/stale/corrupt/partial the query degrades to deterministic lexical
//     fallback over the verified active projection (`lexical-fallback`).
//   * A deterministic JS lexical layer performs evidence gating and tie-breaking in
//     BOTH modes, so ordering never depends on model-specific ts_rank and PR-4 does
//     not re-litigate scores. FTS is the acceleration/telemetry substrate; the
//     governed ranking is deterministic and reproducible.
//   * Rank-only vectors (PR-2b) are an OPTIONAL refinement on top: when enabled and
//     a generation-bound vector manifest + embedding provider are available, they
//     REORDER the already-eligible set only (retrievalMode `hybrid-rank`) and surface
//     semantic-only neighbors as non-selectable diagnostics. They never add, drop, or
//     make an ineligible record selectable (invariants 1 & 2 in retrieval-vector.mjs).
//
// The FC-004 DISTINCTION (documented deliberately): FC-004 says a missing REQUIRED
// validation tool must REFUSE, never degrade to a weaker path. Vectors are NOT such
// a tool — they are an optional rank refinement whose absence degrades to the STILL-
// PROVEN FTS tier, which is itself a proven ranking, not a best-effort weaker path.
// So no key, a provider error, or a missing/stale/unbound vector manifest degrades to
// FTS (logged once) and NEVER fails a retrieval, recall, or build. This is not an
// FC-004 violation; it is the correct treatment of an optional-by-design capability.

import path from 'node:path';
import { sha256 } from './hash.mjs';
import { normalizeQuery, recordLexicalFields } from './retrieval-normalize.mjs';
import { captureCanonical, inspectRetrievalIndex, readCurrent, retrievalPaths } from './retrieval-index.mjs';
import { TS_CONFIG, loadPGlite, queryGenerationDb } from './retrieval-pglite.mjs';
import { rerankByVectors, validateVectorManifest } from './retrieval-vector.mjs';
import { embeddingsById, readVectorArtifacts } from './retrieval-vector-build.mjs';

// Vector-degradation is fail-open and OPTIONAL by design. When vectors are
// unavailable (no key, provider error, missing/stale/unbound manifest, dimension
// mismatch) retrieval degrades to the STILL-PROVEN FTS tier and this logs the
// reason ONCE per process (deduped by reason) rather than spamming every recall.
// This is the FC-004 distinction, not a violation: FTS is proven, so vector
// absence degrades to it instead of refusing.
const loggedVectorFallbacks = new Set();
function logVectorFallbackOnce(reason) {
  if (loggedVectorFallbacks.has(reason)) return;
  loggedVectorFallbacks.add(reason);
  try {
    process.stderr.write(`mem: vectors unavailable, using FTS-only (${reason})\n`);
  } catch {
    // never let a logging failure affect retrieval
  }
}
// Test-only: reset the once-per-process dedupe so a suite can assert the log fires.
export function __resetVectorFallbackLog() {
  loggedVectorFallbacks.clear();
}

export const RETRIEVAL_TELEMETRY_SCHEMA = 'kraken-memory/retrieval-telemetry/v1';
// All retrieval modes the telemetry contract reserves. `hybrid-rank` is reserved
// for PR-2b (rank-only vectors); PR-2 emits only the other three.
export const RETRIEVAL_MODES = Object.freeze(['pglite-fts', 'lexical-fallback', 'hybrid-rank', 'failed']);

const DEFAULT_TOP = 10;

// Deterministic scoring weights. Discrete lexical evidence dominates; ts_rank is
// deliberately NOT part of the score or the tie-break, so pglite-fts and
// lexical-fallback order identically for the same candidate set.
const WEIGHT = { exactId: 100, phrase: 50, curated: 10, term: 3 };

function isoNow() {
  return new Date().toISOString();
}

// Filter one active record against project/kind/scope/validity. Returns null when
// it passes, or a stable rejection reason when it does not.
function filterReason(record, { project, kind, scopes, asOf }) {
  if (project) {
    const projects = record.projects || [];
    if (!projects.includes('*') && !projects.includes(project)) return 'ineligible-project';
  }
  if (kind) {
    const kinds = record.taskKinds || [];
    if (!kinds.includes('*') && !kinds.includes(kind)) return 'ineligible-kind';
  }
  if (Array.isArray(scopes) && scopes.length > 0) {
    if (!scopes.includes(record.scope)) return 'ineligible-scope';
  }
  if (record.validFrom && asOf < record.validFrom) return 'outside-validity';
  if (record.validTo && asOf > record.validTo) return 'outside-validity';
  return null;
}

// Deterministic lexical evidence + score for one record against the normalized
// query. Returns { score, matchedTermCount, evidence } where evidence records
// which gates fired. Eligibility is decided by the caller from `evidence`.
function scoreRecord(record, q) {
  const fields = recordLexicalFields(record);
  const matchedTerms = new Set();
  let exactId = 0;
  let phrase = 0;
  let curated = 0;
  let term = 0;

  for (const id of q.ids) {
    if (fields.idSet.has(id)) exactId += 1;
  }
  for (const p of q.phrases) {
    if (p && fields.searchText.includes(p)) phrase += 1;
  }
  for (const t of q.terms) {
    let hit = false;
    if (fields.curatedTerms.has(t)) { curated += 1; hit = true; }
    if (fields.allTerms.has(t)) { term += 1; hit = true; }
    if (hit) matchedTerms.add(t);
  }
  const score = WEIGHT.exactId * exactId + WEIGHT.phrase * phrase + WEIGHT.curated * curated + WEIGHT.term * term;
  const evidence = { exactId, phrase, curated, term };
  return { score, matchedTermCount: matchedTerms.size, evidence };
}

// Lexical evidence threshold shared with the PR-4 governed contract: an exact ID,
// an exact quoted phrase, at least one curated-field hit, or at least two matched
// query terms. A single generic token that only grazes the broad term surface is
// NOT sufficient (rejected `insufficient-signal`).
function isEligible(evidence, matchedTermCount) {
  return evidence.exactId > 0 || evidence.phrase > 0 || evidence.curated > 0 || matchedTermCount >= 2;
}

// Deterministic tie-break: score desc, matched-term count desc, verifiedAt desc
// (null last), recordedAt desc (null last), then memory id asc. ts_rank is
// intentionally excluded.
function compareCandidates(a, b) {
  if (b.score !== a.score) return b.score - a.score;
  if (b.matchedTermCount !== a.matchedTermCount) return b.matchedTermCount - a.matchedTermCount;
  const vt = compareIsoDesc(a.record.verifiedAt, b.record.verifiedAt);
  if (vt !== 0) return vt;
  const rt = compareIsoDesc(a.record.recordedAt, b.record.recordedAt);
  if (rt !== 0) return rt;
  return a.record.id < b.record.id ? -1 : (a.record.id > b.record.id ? 1 : 0);
}

// Descending ISO comparison with nulls sorted last.
function compareIsoDesc(a, b) {
  if (a && b) return a < b ? 1 : (a > b ? -1 : 0);
  if (a && !b) return -1;
  if (!a && b) return 1;
  return 0;
}

// Build the OR-of-lexemes tsquery from the normalized query terms. Only terms that
// are ALREADY purely alphanumeric are used as lexemes; dashed/underscored compounds
// are skipped because their split subtokens are already present in the term bag, so
// no lexeme is ever synthesized by stripping separators (which would produce junk
// like "exactsha"). Every emitted lexeme matches [a-z0-9]+, so the joined string is
// always safe for to_tsquery('simple', ...).
export function buildTsquery(terms) {
  const lexemes = [];
  const seen = new Set();
  for (const t of terms) {
    const term = String(t);
    if (/^[a-z0-9]+$/.test(term) && !seen.has(term)) {
      seen.add(term);
      lexemes.push(term);
    }
  }
  return lexemes.join(' | ');
}

function telemetry({ mode, fallbackReason, watermark, generationId, derivedStatus, derivedReason, vector, q, filters, counts, timing }) {
  return {
    schema: RETRIEVAL_TELEMETRY_SCHEMA,
    retrievalMode: mode,
    fallbackReason: fallbackReason ?? null,
    canonicalWatermark: watermark,
    retrievalGeneration: generationId ?? null,
    pglite: { status: derivedStatus, reason: derivedReason ?? null },
    vector: vector || { enabled: false, status: 'disabled', reason: 'vectors not requested' },
    query: { sha256: sha256(q.raw), byteLength: Buffer.byteLength(q.raw, 'utf8'), normalizedTermCount: q.normalizedTermCount },
    filters,
    counts,
    timingMs: timing
  };
}

// The retrieval entry point. Never mutates canonical state, never appends registry
// or activity events, and never contacts a network. Returns a structured payload;
// producing brief Markdown / launch decisions is explicitly out of scope (PR-4).
export async function retrieveMemory(options = {}) {
  const {
    registryDir,
    query = '',
    project = null,
    kind = null,
    scopes = [],
    top = DEFAULT_TOP,
    asOf = isoNow(),
    // Rank-only vectors (PR-2b). Optional: when enabled and a bound vector manifest
    // + provider are available they REORDER the already-eligible set only. Any
    // failure degrades to the proven FTS tier without failing retrieval.
    vectors = false,
    embeddingProvider = null,
    vectorThreshold = 0
  } = options;

  const t0 = Date.now();
  const q = normalizeQuery(query);
  const filters = { project: project ?? '', kind: kind ?? '', scopes: Array.isArray(scopes) ? scopes : [], asOf };

  // 1. Canonical verification.
  const canonical = await captureCanonical(registryDir);
  const canonicalVerifyMs = Date.now() - t0;
  if (!canonical.ok) {
    return {
      ok: false,
      retrievalMode: 'failed',
      fallbackReason: canonical.reason,
      canonicalWatermark: canonical.watermark,
      retrievalGeneration: null,
      selected: [],
      rejected: [],
      candidateDiagnostics: [],
      semanticOnly: [],
      telemetry: telemetry({
        mode: 'failed', fallbackReason: canonical.reason, watermark: canonical.watermark, generationId: null,
        derivedStatus: 'skipped', derivedReason: 'canonical verification failed',
        vector: { enabled: false, status: 'disabled', reason: 'canonical verification failed' }, q, filters,
        counts: { eligible: 0, candidates: 0, selected: 0, rejected: 0 },
        timing: { canonicalVerify: canonicalVerifyMs, pgliteVerify: 0, query: 0, rank: 0 }
      })
    };
  }

  // 2. Derived-index inspection + mode selection.
  const tVerify = Date.now();
  const derived = await inspectRetrievalIndex(registryDir, canonical);
  const pgliteVerifyMs = Date.now() - tVerify;
  let mode;
  let fallbackReason = null;
  let generationId = null;
  if (derived.status === 'current') {
    mode = 'pglite-fts';
    generationId = derived.generationId;
  } else {
    mode = 'lexical-fallback';
    fallbackReason = `pglite-${derived.status}`;
  }

  // 3. Filter active records; collect rejections.
  const rejected = [];
  const passing = [];
  for (const record of canonical.records) {
    const reason = filterReason(record, { project, kind, scopes, asOf });
    if (reason) rejected.push({ id: record.id, reason });
    else passing.push(record);
  }

  // 4. In pglite-fts mode, query the verified derived index. The returned ID set is
  //    the CANDIDATE GENERATOR: only records the FTS index returned may be selected
  //    (F1). A record absent from the FTS match set is never selected while the mode
  //    claims pglite-fts. In lexical-fallback mode there is no FTS gate and the JS
  //    lexical layer scans the full verified projection.
  const tQuery = Date.now();
  const ftsRankById = new Map();
  if (mode === 'pglite-fts') {
    const PGlite = await loadPGlite();
    if (!PGlite) {
      mode = 'lexical-fallback';
      fallbackReason = 'pglite-not-loadable';
      generationId = null;
    } else {
      try {
        const current = readCurrent(registryDir);
        const rp = retrievalPaths(registryDir);
        const genDir = path.resolve(rp.root, current.generationDir, 'pglite');
        const tsquery = buildTsquery(q.terms);
        const rows = await queryGenerationDb(PGlite, genDir, tsquery);
        for (const row of rows) ftsRankById.set(row.memId, row.rank);
      } catch {
        mode = 'lexical-fallback';
        fallbackReason = 'pglite-query-error';
        generationId = null;
      }
    }
  }
  const queryMs = Date.now() - tQuery;
  const ftsGated = mode === 'pglite-fts';

  // 5. Deterministic lexical scoring + eligibility. In pglite-fts mode the candidate
  //    pool is exactly the FTS match set (∩ filtered); in lexical-fallback it is the
  //    full filtered set. Records excluded by the FTS gate are not candidates and are
  //    reported in candidateDiagnostics (ftsMatched: false), never selected.
  const tRank = Date.now();
  const candidates = [];
  for (const record of passing) {
    const inFts = ftsRankById.has(record.id);
    const scored = scoreRecord(record, q);
    candidates.push({
      record,
      score: scored.score,
      matchedTermCount: scored.matchedTermCount,
      evidence: scored.evidence,
      ftsRank: inFts ? ftsRankById.get(record.id) : null,
      ftsMatched: inFts
    });
  }

  const pool = ftsGated ? candidates.filter((c) => c.ftsMatched) : candidates;
  const eligible = [];
  for (const cand of pool) {
    if (cand.score === 0) {
      rejected.push({ id: cand.record.id, reason: 'score-0' });
    } else if (!isEligible(cand.evidence, cand.matchedTermCount)) {
      rejected.push({ id: cand.record.id, reason: 'insufficient-signal' });
    } else {
      eligible.push(cand);
    }
  }
  eligible.sort(compareCandidates);

  // 5b. Rank-only vector reranking (PR-2b). This ONLY reorders the already-eligible
  //     set and surfaces semantic-only neighbors as non-selectable diagnostics; it
  //     never adds, drops, or makes an ineligible record selectable (invariants 1 &
  //     2 from retrieval-vector.mjs). It runs only in pglite-fts mode (a healthy
  //     generation the vectors are bound to) and degrades to the proven FTS order on
  //     ANY failure — logged once, never throwing.
  let vectorTelemetry = { enabled: false, status: 'disabled', reason: 'vectors not requested' };
  let semanticOnly = [];
  let reranked = eligible;
  const simById = new Map();
  if (vectors) {
    const skip = (reason, status = 'fallback') => {
      logVectorFallbackOnce(reason);
      vectorTelemetry = { enabled: false, status, reason };
    };
    if (mode !== 'pglite-fts') {
      // No healthy generation to bind vectors to; FTS-only path can't rerank.
      skip(`no-generation (${fallbackReason || 'lexical-fallback'})`);
    } else {
      const artifacts = (() => {
        try {
          const current = readCurrent(registryDir);
          const rp = retrievalPaths(registryDir);
          const genDir = path.resolve(rp.root, current.generationDir);
          return readVectorArtifacts(genDir);
        } catch {
          return null;
        }
      })();
      if (!artifacts) {
        skip('no vector manifest for current generation');
      } else {
        const check = validateVectorManifest(artifacts.vectorManifest, generationId);
        if (!check.valid) {
          // FC-002: a manifest not bound to the CURRENT generation is refused, never
          // used stale. Degrade to FTS.
          skip(`vector manifest invalid: ${check.reason}`);
        } else if (!embeddingProvider || typeof embeddingProvider.embed !== 'function') {
          skip('no embedding provider');
        } else {
          let queryVector = null;
          try {
            const canEmbed = typeof embeddingProvider.canEmbed === 'function' ? await embeddingProvider.canEmbed() : true;
            if (!canEmbed) {
              skip('no embedding key');
            } else {
              queryVector = await embeddingProvider.embed(query);
            }
          } catch (error) {
            skip(`provider error: ${error.message}`);
          }
          if (queryVector) {
            if (!Array.isArray(queryVector) || queryVector.length !== artifacts.vectorManifest.dimensions) {
              skip(`query vector dimension mismatch (${queryVector?.length} != ${artifacts.vectorManifest.dimensions})`);
            } else {
              // Restrict the vector set to filter-PASSING records so a semantic-only
              // neighbor can never be an out-of-scope (project/kind/scope/validity)
              // record. Within that set, rerank the eligible list only.
              const passingIds = new Set(passing.map((r) => r.id));
              const embMap = new Map();
              for (const [id, emb] of embeddingsById(artifacts.vectorsById)) {
                if (passingIds.has(id)) embMap.set(id, emb);
              }
              const rerankInput = eligible.map((c) => ({
                id: c.record.id,
                score: c.score,
                matchedTermCount: c.matchedTermCount,
                verifiedAt: c.record.verifiedAt ?? null,
                recordedAt: c.record.recordedAt ?? null
              }));
              const result = rerankByVectors(rerankInput, { queryVector, vectorsById: embMap, threshold: vectorThreshold });
              const byId = new Map(eligible.map((c) => [c.record.id, c]));
              reranked = result.reranked.map((r) => byId.get(r.id)).filter(Boolean);
              for (const r of result.reranked) simById.set(r.id, r.vectorSimilarity);
              semanticOnly = result.semanticOnly;
              mode = 'hybrid-rank';
              vectorTelemetry = {
                enabled: true,
                status: 'active',
                provider: artifacts.vectorManifest.provider,
                model: artifacts.vectorManifest.model,
                dimensions: artifacts.vectorManifest.dimensions,
                reordered: true,
                rerankedCount: reranked.length,
                semanticOnlyCount: semanticOnly.length
              };
            }
          }
        }
      }
    }
  }

  const topN = Number.isInteger(top) && top > 0 ? top : DEFAULT_TOP;
  const selectedCands = reranked.slice(0, topN);
  for (const cand of reranked.slice(topN)) rejected.push({ id: cand.record.id, reason: 'rank-cutoff' });
  const rankMs = Date.now() - tRank;

  const selected = selectedCands.map((c) => ({
    id: c.record.id,
    summary: c.record.summary,
    scope: c.record.scope,
    projects: c.record.projects,
    taskKinds: c.record.taskKinds,
    confidence: c.record.confidence,
    source: c.record.source ?? null,
    sourceType: c.record.sourceType ?? null,
    contentHash: c.record.contentHash,
    score: c.score,
    matchedTermCount: c.matchedTermCount,
    evidence: c.evidence,
    ftsRank: c.ftsRank,
    vectorSimilarity: simById.has(c.record.id) ? simById.get(c.record.id) : null
  }));

  const counts = {
    eligible: eligible.length,
    candidates: pool.length,
    selected: selected.length,
    rejected: rejected.length,
    semanticOnly: semanticOnly.length
  };

  return {
    ok: true,
    retrievalMode: mode,
    fallbackReason,
    canonicalWatermark: canonical.watermark,
    retrievalGeneration: generationId,
    selected,
    rejected,
    // Semantic-only neighbors: NON-SELECTABLE diagnostics (invariant 2). Never
    // eligible for governed injection; surfaced only for observability.
    semanticOnly,
    candidateDiagnostics: candidates.map((c) => ({
      id: c.record.id, score: c.score, matchedTermCount: c.matchedTermCount,
      evidence: c.evidence, ftsMatched: c.ftsMatched, ftsRank: c.ftsRank,
      vectorSimilarity: simById.has(c.record.id) ? simById.get(c.record.id) : null
    })),
    telemetry: telemetry({
      mode, fallbackReason, watermark: canonical.watermark, generationId,
      derivedStatus: derived.status, derivedReason: derived.reason, vector: vectorTelemetry, q, filters, counts,
      timing: { canonicalVerify: canonicalVerifyMs, pgliteVerify: pgliteVerifyMs, query: queryMs, rank: rankMs }
    })
  };
}

export { TS_CONFIG };
