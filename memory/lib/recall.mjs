// Governed recall for workflow use (Memory PR-4, milestone B).
//
// This is the ONE consumer-facing recall entry point. It does NOT re-implement
// ranking, eligibility, or the FTS/lexical selection: those belong to the single
// retrieval authority `retrieveMemory()` (PR-2, retrieve.mjs), which this module
// calls and never second-guesses. recall() is a governance + presentation layer
// on top of that authority:
//   * it asks the authority for governed candidates (ranked, evidence-gated),
//   * applies the caller's memory-type/status filter to that already-ranked list,
//   * enforces a POINTER BUDGET (a bounded number of pointer-only entries under a
//     byte ceiling; whole entries are dropped lowest-rank-first, never truncated),
//   * and emits a replay manifest so the exact retrieval is verifiable after the
//     fact (which query, which index generation/watermark, under what budget).
//
// Pointer-only is the hard contract: a recall pointer carries an id, a one-line
// summary, a source pointer/anchor, scope/type/confidence, match reasons, and a
// `mem show <id>` command for full inspection. It NEVER carries the memory body.
// Bulk content dumps are exactly what this layer exists to prevent.
//
// Degradation is fail-open, never fail-wrong:
//   * A healthy canonical + stale/missing derived index still yields a PROVEN
//     retrieval (retrieveMemory degrades to lexical fallback over the verified
//     active projection); recall reports state `proven` and returns pointers.
//   * A canonical verification failure yields state `recall-failed` with ZERO
//     pointers. A caller must treat that as "recall did not complete", never as
//     "no relevant memory". recall never emits a pointer it could not prove.

import { captureCanonical } from './retrieval-index.mjs';
import { retrieveMemory } from './retrieve.mjs';
import { contentHash, sha256 } from './hash.mjs';
import { MEMORY_TYPES, STATUS } from './schema.mjs';

export const RECALL_MANIFEST_SCHEMA = 'kraken-memory/recall-manifest/v1';
export const RECALL_PACK_SCHEMA = 'kraken-memory/recall-pack/v1';

// Bounded defaults. maxPointers caps the entry count; maxBytes caps the rendered
// pointer-section size (estimated from a canonical one-line rendering per pointer,
// so the budget is deterministic and independent of the eventual Markdown
// wrapper). candidateCap bounds how many ranked candidates the authority is asked
// for before the budget trims them, so recall never pulls an unbounded result set.
export const DEFAULT_BUDGET = Object.freeze({ maxPointers: 5, maxBytes: 2048, candidateCap: 50 });

function isoNow() {
  return new Date().toISOString();
}

function normalizeBudget(budget = {}) {
  const b = budget || {};
  const maxPointers = Number.isInteger(b.maxPointers) && b.maxPointers >= 0 ? b.maxPointers : DEFAULT_BUDGET.maxPointers;
  const maxBytes = Number.isInteger(b.maxBytes) && b.maxBytes > 0 ? b.maxBytes : DEFAULT_BUDGET.maxBytes;
  const candidateCap = Number.isInteger(b.candidateCap) && b.candidateCap > 0 ? b.candidateCap : DEFAULT_BUDGET.candidateCap;
  return { maxPointers, maxBytes, candidateCap };
}

// Human-readable match reasons derived from the authority's discrete lexical
// evidence. These explain WHY a pointer was recalled without exposing scores the
// caller must not re-litigate.
function matchReasons(evidence, matchedTermCount) {
  const reasons = [];
  if (evidence?.exactId > 0) reasons.push('exact-id');
  if (evidence?.phrase > 0) reasons.push('quoted-phrase');
  if (evidence?.curated > 0) reasons.push('curated-field');
  if (reasons.length === 0 && matchedTermCount >= 2) reasons.push(`${matchedTermCount}-term-summary`);
  else if (evidence?.term > 0 && matchedTermCount >= 2) reasons.push(`${matchedTermCount}-terms`);
  return reasons;
}

// Deterministic byte estimate for one pointer: a canonical single-line rendering
// of exactly the pointer-only fields. The Markdown wrapper adds fixed overhead
// accounted separately, so this number is stable regardless of presentation.
function pointerBytes(pointer) {
  const src = pointer.source ? `${pointer.source.path}${pointer.source.anchor ? `#${pointer.source.anchor}` : ''}` : '';
  const line = `${pointer.id} | ${pointer.summary} | ${src} | ${pointer.scope}/${pointer.memoryType}/${pointer.confidence} | ${pointer.matchReasons.join(',')} | ${pointer.showCommand}`;
  return Buffer.byteLength(line, 'utf8');
}

function buildPointer(sel, meta) {
  return {
    id: sel.id,
    summary: sel.summary,
    // Prefer the authority's own source field; fall back to the canonical capture
    // (they agree, but the capture is the type/status source of truth used below).
    source: sel.source ?? meta?.source ?? null,
    sourceType: sel.sourceType ?? meta?.sourceType ?? null,
    scope: sel.scope,
    memoryType: meta?.memoryType ?? null,
    status: meta?.status ?? null,
    confidence: sel.confidence ?? null,
    matchReasons: matchReasons(sel.evidence, sel.matchedTermCount),
    showCommand: `mem show ${sel.id}`
  };
}

// The recall manifest is the replay proof: everything needed to re-run and audit
// this exact recall. It is deterministic for identical inputs and canonical state,
// so an injected proof can be re-derived and compared byte-for-byte.
function buildManifest({ querySource, q, filters, budget, retrieval, injectedIds, omitted, counts }) {
  const replayInputs = {
    schema: RECALL_MANIFEST_SCHEMA,
    querySource,
    querySha256: q.sha256,
    queryByteLength: q.byteLength,
    filters,
    budget,
    retrievalMode: retrieval.retrievalMode,
    fallbackReason: retrieval.fallbackReason ?? null,
    canonicalWatermark: retrieval.canonicalWatermark ?? null,
    retrievalGeneration: retrieval.retrievalGeneration ?? null,
    injectedIds,
    omitted,
    counts
  };
  // The manifest id fingerprints the replay-relevant inputs so a caller can detect
  // any drift in query, filters, budget, index generation, or selection.
  const manifestId = contentHash(replayInputs);
  return { manifestId, ...replayInputs };
}

// Governed recall. Returns a structured recall pack; it NEVER mutates canonical
// state, appends registry/activity events, contacts a network, or writes a file.
// Rendering the pack into a brief and proving injection is injection.mjs's job.
export async function recall(options = {}) {
  const {
    registryDir,
    query = '',
    project = null,
    kind = null,
    scopes = [],
    memoryTypes = [],
    statuses = ['active'],
    budget: budgetOpt = {},
    asOf = isoNow(),
    querySource = 'inline'
  } = options;

  const budget = normalizeBudget(budgetOpt);
  const typeFilter = Array.isArray(memoryTypes) ? memoryTypes.filter((t) => MEMORY_TYPES.includes(t)) : [];
  const statusFilter = Array.isArray(statuses) ? statuses.filter((s) => STATUS.includes(s)) : [];
  const q = { sha256: sha256(query), byteLength: Buffer.byteLength(query, 'utf8') };
  const filters = {
    project: project ?? '',
    kind: kind ?? '',
    scopes: Array.isArray(scopes) ? scopes : [],
    memoryTypes: typeFilter,
    statuses: statusFilter,
    asOf
  };

  // 1. Canonical capture for the id -> {memoryType, status, source} map. This is
  //    the SAME sanctioned canonical reader the authority uses; recall consumes it
  //    only for per-record metadata (type/status/source) needed to filter and
  //    render, never to rank. It also tells us how many active records exist, so an
  //    empty registry is distinguishable from a real zero-hit downstream.
  const captured = await captureCanonical(registryDir);
  const metaById = new Map();
  if (captured.ok) {
    for (const rec of captured.records) metaById.set(rec.id, { memoryType: rec.memoryType ?? null, status: rec.status ?? 'active', source: rec.source ?? null, sourceType: rec.sourceType ?? null });
  }
  const activeCount = captured.ok ? captured.records.length : 0;

  // 2. Ask the single retrieval authority for governed, ranked candidates. Request
  //    up to candidateCap so the type filter and pointer budget still have room to
  //    fill; the authority returns them already rank-ordered.
  const retrieval = await retrieveMemory({ registryDir, query, project, kind, scopes, top: budget.candidateCap, asOf });

  // 3. Recall-failed: the authority could not verify canonical state. Fail-open with
  //    ZERO pointers. Never synthesize or reuse stale content here.
  if (!retrieval.ok) {
    const counts = { active: activeCount, candidates: 0, eligible: 0, injected: 0, omitted: 0 };
    const manifest = buildManifest({ querySource, q, filters, budget, retrieval, injectedIds: [], omitted: [], counts });
    return {
      schema: RECALL_PACK_SCHEMA,
      ok: false,
      state: 'recall-failed',
      retrievalMode: retrieval.retrievalMode,
      fallbackReason: retrieval.fallbackReason ?? null,
      canonicalWatermark: retrieval.canonicalWatermark ?? null,
      retrievalGeneration: null,
      budget,
      filters,
      query: { source: querySource, sha256: q.sha256, byteLength: q.byteLength },
      pointers: [],
      omitted: [],
      counts,
      manifest,
      telemetry: retrieval.telemetry ?? null,
      generatedAt: asOf
    };
  }

  // 4. Proven retrieval. Build candidate pointers in the authority's rank order.
  const omitted = [];
  const ranked = [];
  for (const sel of retrieval.selected) {
    const meta = metaById.get(sel.id);
    const pointer = buildPointer(sel, meta);
    // Memory-type filter (post-rank, no re-scoring). Only applied when the caller
    // asked for specific types.
    if (typeFilter.length > 0 && (!pointer.memoryType || !typeFilter.includes(pointer.memoryType))) {
      omitted.push({ id: sel.id, reason: 'type-filtered' });
      continue;
    }
    // Status filter. The active projection only ever contains active records, so
    // this is a guard that rejects anything unexpected rather than a common path.
    if (statusFilter.length > 0 && pointer.status && !statusFilter.includes(pointer.status)) {
      omitted.push({ id: sel.id, reason: 'status-filtered' });
      continue;
    }
    ranked.push(pointer);
  }

  // 5. Pointer budget. First the count ceiling (drop lowest rank), then the byte
  //    ceiling (drop lowest rank until the estimated section fits). Whole entries
  //    only: a summary or provenance pointer is never truncated mid-string.
  const kept = [];
  let usedBytes = 0;
  for (const pointer of ranked) {
    if (kept.length >= budget.maxPointers) {
      omitted.push({ id: pointer.id, reason: 'pointer-budget-count' });
      continue;
    }
    const bytes = pointerBytes(pointer);
    if (usedBytes + bytes > budget.maxBytes) {
      omitted.push({ id: pointer.id, reason: 'pointer-budget-bytes' });
      continue;
    }
    usedBytes += bytes;
    kept.push(pointer);
  }

  const injectedIds = kept.map((p) => p.id);
  const counts = {
    active: activeCount,
    candidates: retrieval.selected.length,
    eligible: ranked.length,
    injected: kept.length,
    omitted: omitted.length
  };
  const manifest = buildManifest({ querySource, q, filters, budget, retrieval, injectedIds, omitted, counts });

  return {
    schema: RECALL_PACK_SCHEMA,
    ok: true,
    state: 'proven',
    retrievalMode: retrieval.retrievalMode,
    fallbackReason: retrieval.fallbackReason ?? null,
    canonicalWatermark: retrieval.canonicalWatermark,
    retrievalGeneration: retrieval.retrievalGeneration,
    budget,
    filters,
    query: { source: querySource, sha256: q.sha256, byteLength: q.byteLength },
    // usedBytes is the estimated pointer-section size the budget accounted for.
    usedBytes,
    pointers: kept,
    omitted,
    counts,
    manifest,
    telemetry: retrieval.telemetry ?? null,
    generatedAt: asOf
  };
}
