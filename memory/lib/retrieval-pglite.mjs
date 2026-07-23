// PGlite adapter for the derived FTS retrieval index. Every PGlite touch in the
// package goes through here so the rest of the code stays backend-neutral and so
// a missing/broken PGlite install degrades to lexical fallback instead of crashing.
//
// PGlite is a genuine embedded PostgreSQL (WASM), so the FTS surface uses real
// PostgreSQL text-search primitives: `tsvector`, `to_tsvector`, GIN index,
// `websearch_to_tsquery`, and `ts_rank`. If a future PGlite build drops those, the
// build validates as corrupt and retrieval falls back rather than pretending an ad
// hoc string index is FTS (respec-s3 hard stop).

import { buildSearchText } from './retrieval-normalize.mjs';

// Bump when the SQL schema or the tsvector text-search configuration changes; the
// value is written into the generation manifest so an old generation reads stale.
export const PGLITE_SCHEMA_VERSION = 'kraken-memory/retrieval-pglite/v1';

// The deterministic PostgreSQL text-search configuration. `simple` avoids
// language-specific stemming/stop-words, so tokenization is stable and predictable
// for KrakenLoop identifiers and jargon.
export const TS_CONFIG = 'simple';

const SCHEMA_SQL = `
CREATE TABLE memory_docs (
  mem_id TEXT PRIMARY KEY,
  generation INTEGER NOT NULL,
  content_hash TEXT NOT NULL,
  summary TEXT NOT NULL,
  source_path TEXT,
  source_anchor TEXT,
  scope_json TEXT NOT NULL,
  projects_json TEXT NOT NULL,
  task_kinds_json TEXT NOT NULL,
  confidence TEXT,
  search_text TEXT NOT NULL,
  sortable_verified_at TEXT,
  sortable_recorded_at TEXT,
  canonical_json TEXT NOT NULL
);
CREATE TABLE memory_fts (
  mem_id TEXT PRIMARY KEY REFERENCES memory_docs(mem_id) ON DELETE CASCADE,
  document TSVECTOR NOT NULL
);
CREATE INDEX memory_fts_document_idx ON memory_fts USING GIN(document);
CREATE TABLE retrieval_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
`;

// Dynamic, guarded load of PGlite. Returns the PGlite class or null when the
// dependency is absent or unloadable, so retrieval can degrade to lexical fallback
// (the package remains functional without a working PGlite install).
export async function loadPGlite() {
  try {
    const mod = await import('@electric-sql/pglite');
    return mod.PGlite || null;
  } catch {
    return null;
  }
}

// The compact, searchable projection stored as canonical_json. Intentionally omits
// the full `body` and evidence: the derived store carries only what search and
// debugging need. The authoritative record data returned to callers always comes
// from the verified canonical active index, never from here.
function indexedProjection(record) {
  return {
    id: record.id,
    summary: record.summary,
    scope: record.scope,
    projects: record.projects,
    taskKinds: record.taskKinds,
    confidence: record.confidence,
    source: record.source ?? null,
    contentHash: record.contentHash,
    generation: record.generation ?? 0,
    validFrom: record.validFrom ?? null,
    validTo: record.validTo ?? null,
    verifiedAt: record.verifiedAt ?? null,
    recordedAt: record.recordedAt ?? null
  };
}

// Build a fresh generation database at `dataDir`, inserting one memory_docs +
// memory_fts row per active record. Returns { rowCount, ids } for post-build
// validation. The caller owns generation-dir layout and manifest writing.
export async function buildGenerationDb(PGlite, dataDir, records, generation, meta = {}) {
  const db = await PGlite.create({ dataDir });
  try {
    await db.exec(SCHEMA_SQL);
    for (const [key, value] of Object.entries(meta)) {
      await db.query('INSERT INTO retrieval_meta(key, value) VALUES ($1, $2)', [String(key), String(value)]);
    }
    const ids = [];
    for (const record of records) {
      const searchText = buildSearchText(record);
      await db.query(
        `INSERT INTO memory_docs(
           mem_id, generation, content_hash, summary, source_path, source_anchor,
           scope_json, projects_json, task_kinds_json, confidence, search_text,
           sortable_verified_at, sortable_recorded_at, canonical_json
         ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
        [
          record.id,
          Number(generation) || 0,
          record.contentHash,
          record.summary || '',
          record.source?.path ?? null,
          record.source?.anchor ?? null,
          JSON.stringify(record.scope ?? null),
          JSON.stringify(record.projects ?? []),
          JSON.stringify(record.taskKinds ?? []),
          record.confidence ?? null,
          searchText,
          record.verifiedAt ?? null,
          record.recordedAt ?? null,
          JSON.stringify(indexedProjection(record))
        ]
      );
      await db.query(
        `INSERT INTO memory_fts(mem_id, document) VALUES ($1, to_tsvector('${TS_CONFIG}', $2))`,
        [record.id, searchText]
      );
      ids.push(record.id);
    }
    return { rowCount: ids.length, ids };
  } finally {
    await db.close();
  }
}

// Open a published generation read-only-ish and return { rowCount, contentHashes,
// meta } for corruption/partial detection. Throws if the DB cannot be opened or
// the expected schema is absent — the caller treats a throw as `pglite-corrupt`.
export async function inspectGenerationDb(PGlite, dataDir) {
  const db = await PGlite.create({ dataDir });
  try {
    const docs = await db.query('SELECT mem_id, content_hash FROM memory_docs ORDER BY mem_id');
    const fts = await db.query('SELECT count(*)::int AS n FROM memory_fts');
    const metaRows = await db.query('SELECT key, value FROM retrieval_meta');
    const contentHashes = new Map();
    for (const row of docs.rows) contentHashes.set(row.mem_id, row.content_hash);
    const meta = {};
    for (const row of metaRows.rows) meta[row.key] = row.value;
    return { rowCount: docs.rows.length, ftsCount: fts.rows[0].n, contentHashes, meta };
  } finally {
    await db.close();
  }
}

// Run the FTS candidate query. `tsquery` is a pre-sanitized OR-of-lexemes string
// (see retrieve.mjs) built only from alphanumeric lexemes, so it is safe for
// to_tsquery. Returns [{ memId, rank }] ordered by rank desc then id for
// determinism. An empty tsquery yields no FTS candidates.
export async function queryGenerationDb(PGlite, dataDir, tsquery) {
  if (!tsquery) return [];
  const db = await PGlite.create({ dataDir });
  try {
    const result = await db.query(
      `SELECT d.mem_id AS "memId", ts_rank(f.document, to_tsquery('${TS_CONFIG}', $1)) AS rank
         FROM memory_fts f JOIN memory_docs d ON d.mem_id = f.mem_id
        WHERE f.document @@ to_tsquery('${TS_CONFIG}', $1)
        ORDER BY rank DESC, d.mem_id ASC`,
      [tsquery]
    );
    return result.rows.map((row) => ({ memId: row.memId, rank: Number(row.rank) }));
  } finally {
    await db.close();
  }
}
