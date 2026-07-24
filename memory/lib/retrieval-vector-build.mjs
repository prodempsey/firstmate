// Build-time vector artifacts for the derived retrieval index (Memory PR-2b).
//
// Embeddings are computed AT BUILD TIME (never at query time for the corpus) and
// cached in the generation directory, bound to the generation they describe:
//   generations/<genId>/
//     vector-manifest.json   # VECTOR_MANIFEST_SCHEMA; provider/model/dims + genId
//     vectors.jsonl          # one {id, contentHash, embedding} per record
// The reader (retrieve.mjs) validates the manifest against the CURRENT generation
// id with validateVectorManifest before trusting any of it (FC-002: a manifest not
// bound to the live generation is refused, never used stale).
//
// This module is the ONLY vector code that touches the provider and the disk;
// retrieval-vector.mjs stays pure (no network, no keys, no fs). Query-text
// embedding for reranking is bounded by the provider itself (FC-006).
//
// Incremental: when a previous generation's vectors are supplied, a record whose
// contentHash is unchanged reuses its cached embedding and is NOT re-embedded, so
// a rebuild only pays the provider for new/changed records.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { VECTOR_MANIFEST_SCHEMA } from './retrieval-vector.mjs';

export const VECTORS_FILE = 'vectors.jsonl';
export const VECTOR_MANIFEST_FILE = 'vector-manifest.json';

// Durable atomic replace mirroring retrieval-index.mjs's write discipline.
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

// Deterministic, stable text projection for embedding one record. Emphasizes the
// hand-authored semantic surface (summary, curated fields, body) in a fixed order
// so the same record always yields the same text — the embedding cache and the
// build determinism both depend on this being stable.
export function buildEmbeddingText(record) {
  const parts = [];
  if (record.summary) parts.push(String(record.summary));
  const fields = ['keywords', 'aliases', 'entities', 'commands', 'failureModes', 'relatedTerms'];
  for (const field of fields) {
    const value = record[field];
    if (Array.isArray(value)) {
      for (const item of value) if (item) parts.push(String(item));
    }
  }
  if (record.body) parts.push(String(record.body));
  return parts.join('\n').replace(/[ \t]+/g, ' ').trim();
}

// Compute embeddings for `records`, reusing cached vectors for unchanged records.
// Returns { vectorsById, vectorManifest, embeddedCount, reusedCount } where
// vectorsById maps id -> { contentHash, embedding }. Throws only if the provider
// throws (the caller treats a throw as "no vectors this build" and keeps FTS).
export async function computeGenerationVectors({ records, provider, generationId, prevVectorsById = new Map() }) {
  if (!provider || typeof provider.embedBatch !== 'function') throw new Error('embedding provider required');
  const vectorsById = new Map();
  const toEmbed = [];
  const toEmbedIds = [];
  let reusedCount = 0;
  for (const record of records) {
    const prev = prevVectorsById.get(record.id);
    if (prev && prev.contentHash === record.contentHash && Array.isArray(prev.embedding) && prev.embedding.length === provider.dimensions) {
      vectorsById.set(record.id, { contentHash: record.contentHash, embedding: prev.embedding });
      reusedCount += 1;
    } else {
      toEmbedIds.push(record.id);
      toEmbed.push({ id: record.id, contentHash: record.contentHash, text: buildEmbeddingText(record) });
    }
  }
  let embeddedCount = 0;
  if (toEmbed.length > 0) {
    const embeddings = await provider.embedBatch(toEmbed.map((r) => r.text));
    if (!Array.isArray(embeddings) || embeddings.length !== toEmbed.length) {
      throw new Error(`provider returned ${embeddings?.length ?? 0} embeddings for ${toEmbed.length} inputs`);
    }
    for (let i = 0; i < toEmbed.length; i += 1) {
      const emb = embeddings[i];
      if (!Array.isArray(emb) || emb.length !== provider.dimensions) {
        throw new Error(`provider embedding ${i} has wrong dimension (${emb?.length} != ${provider.dimensions})`);
      }
      vectorsById.set(toEmbed[i].id, { contentHash: toEmbed[i].contentHash, embedding: emb });
      embeddedCount += 1;
    }
  }
  const vectorManifest = {
    schema: VECTOR_MANIFEST_SCHEMA,
    provider: provider.id,
    model: provider.model || provider.id,
    dimensions: provider.dimensions,
    generationId,
    vectorCount: vectorsById.size,
    createdAt: new Date().toISOString()
  };
  return { vectorsById, vectorManifest, embeddedCount, reusedCount };
}

// Atomically write vectors.jsonl + vector-manifest.json into the generation dir.
export function writeVectorArtifacts(genDir, { vectorManifest, vectorsById }) {
  const lines = [];
  // Stable id order so the file is byte-reproducible for a fixed input.
  const ids = [...vectorsById.keys()].sort();
  for (const id of ids) {
    const v = vectorsById.get(id);
    lines.push(JSON.stringify({ id, contentHash: v.contentHash, embedding: v.embedding }));
  }
  atomicWriteFile(path.join(genDir, VECTORS_FILE), lines.length ? `${lines.join('\n')}\n` : '');
  atomicWriteFile(path.join(genDir, VECTOR_MANIFEST_FILE), `${JSON.stringify(vectorManifest, null, 2)}\n`);
}

// Read vector artifacts back from a generation dir. Returns
// { vectorManifest, vectorsById } or null when absent/unreadable. vectorsById maps
// id -> { contentHash, embedding }. A partially-written/corrupt pair returns null
// so the reader treats it as "no vectors" and stays on FTS.
export function readVectorArtifacts(genDir) {
  const manifestPath = path.join(genDir, VECTOR_MANIFEST_FILE);
  const vectorsPath = path.join(genDir, VECTORS_FILE);
  if (!fs.existsSync(manifestPath) || !fs.existsSync(vectorsPath)) return null;
  let vectorManifest;
  try {
    vectorManifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch {
    return null;
  }
  const vectorsById = new Map();
  try {
    const raw = fs.readFileSync(vectorsPath, 'utf8');
    for (const line of raw.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const row = JSON.parse(trimmed);
      if (row && typeof row.id === 'string' && Array.isArray(row.embedding)) {
        vectorsById.set(row.id, { contentHash: row.contentHash ?? null, embedding: row.embedding });
      }
    }
  } catch {
    return null;
  }
  return { vectorManifest, vectorsById };
}

// Convenience: read just the id -> embedding[] map for reranking.
export function embeddingsById(vectorsById) {
  const out = new Map();
  for (const [id, v] of vectorsById) out.set(id, v.embedding);
  return out;
}
