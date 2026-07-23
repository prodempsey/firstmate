// Deterministic query and document normalization for the derived retrieval index.
//
// This module is the ONLY source of tokenization/normalization truth shared by
// document indexing (what goes into the PGlite tsvector) and query eligibility
// (exact-ID, quoted-phrase, curated-field, and summary/term matching in JS). It
// is intentionally pure and offline: no network, no model-generated synonyms, no
// randomness. The version string below is stamped into every generation manifest
// so a normalization change forces the derived index stale rather than silently
// re-ranking against an incompatible tokenizer.

export const NORMALIZER_VERSION = 'kraken-memory/retrieval-normalize/v1';

// Curated, versioned abbreviation table. Expansions are ADDED alongside the
// original token (never replacing it) so an abbreviated query still matches an
// unabbreviated record and vice versa. This is a hand-maintained lexical aid, not
// a synonym model: every entry is a KrakenLoop-domain contraction with a single
// unambiguous expansion. Keep it small and deterministic.
export const ABBREVIATIONS = Object.freeze({
  wm: 'watermark',
  pr: 'pullrequest',
  qa: 'qualityassurance',
  fm: 'firstmate',
  cp: 'controlplane',
  wt: 'worktree',
  cfg: 'config',
  repro: 'reproduce',
  db: 'database',
  fts: 'fulltextsearch'
});

// Fields projected into the searchable document. Order is stable so the generated
// search_text (and therefore the tsvector) is deterministic for a fixed record.
export const SEARCH_FIELD_ORDER = Object.freeze([
  'id', 'summary', 'keywords', 'aliases', 'entities', 'commands',
  'failureModes', 'relatedTerms', 'scope', 'projects', 'taskKinds'
]);

// Curated fields carry hand-authored retrieval signal; a single hit in one of
// these is stronger evidence than a stray summary token.
export const CURATED_FIELDS = Object.freeze([
  'keywords', 'aliases', 'entities', 'commands', 'failureModes', 'relatedTerms'
]);

// A token is an explicit ID when it is a dashed/underscored token that carries at
// least one digit (MEM-0001, ORD-261, BUG-12, fix-login-k3). Purely alphabetic
// hyphenated words (merge-base, read-only) are NOT treated as IDs: they split
// normally and never earn exact-ID evidence.
const ID_TOKEN = /^[a-z0-9]+(?:[-_][a-z0-9]+)+$/;

function nfcLower(value) {
  return String(value ?? '').normalize('NFC').toLowerCase();
}

function isIdToken(token) {
  return ID_TOKEN.test(token) && /[0-9]/.test(token) && /[a-z]/.test(token);
}

// Split a normalized string into raw candidate tokens on whitespace and any
// character that is not a Unicode letter, digit, dash, or underscore. Dash and
// underscore are retained here so ID tokens survive; ordinary hyphenated words are
// split into subtokens by expandTokens below. Unicode letters/digits are kept so
// tokenization tracks PostgreSQL's `simple` text-search config (which preserves
// accented word characters) rather than silently truncating them.
function rawTokens(normalized) {
  return normalized.split(/[^\p{L}\p{N}_-]+/u).filter(Boolean);
}

// Expand a raw token into its emitted forms:
//   * the token itself (with any leading/trailing separators trimmed),
//   * for dashed/underscored tokens, each subtoken, so hyphen/underscore
//     boundaries are searchable while the exact compound token is retained,
//   * a curated abbreviation expansion when the token is a known abbreviation.
function expandTokens(token) {
  const out = [];
  const trimmed = token.replace(/^[-_]+|[-_]+$/g, '');
  if (!trimmed) return out;
  out.push(trimmed);
  if (/[-_]/.test(trimmed)) {
    for (const part of trimmed.split(/[-_]+/)) {
      if (part) out.push(part);
    }
  }
  const expansion = ABBREVIATIONS[trimmed];
  if (expansion) out.push(expansion);
  return out;
}

// Tokenize normalized text into { terms, ids }. `terms` is the full deterministic
// bag (compound + subtokens + abbreviation expansions), deduped and stable; `ids`
// is the subset of exact ID tokens seen. Callers use `terms` for term matching
// and `ids` for exact-ID evidence.
export function tokenize(text) {
  const normalized = nfcLower(text);
  const terms = [];
  const seen = new Set();
  const ids = [];
  const idSeen = new Set();
  for (const raw of rawTokens(normalized)) {
    const trimmed = raw.replace(/^[-_]+|[-_]+$/g, '');
    if (trimmed && isIdToken(trimmed) && !idSeen.has(trimmed)) {
      idSeen.add(trimmed);
      ids.push(trimmed);
    }
    for (const token of expandTokens(raw)) {
      if (!seen.has(token)) {
        seen.add(token);
        terms.push(token);
      }
    }
  }
  return { terms, ids };
}

// Extract quoted "..." phrases from a raw query as normalized substrings. A phrase
// match is exact-substring evidence against a record's normalized search text.
export function extractPhrases(query) {
  const phrases = [];
  const seen = new Set();
  const re = /"([^"]+)"/g;
  let match;
  while ((match = re.exec(String(query ?? ''))) !== null) {
    const phrase = nfcLower(match[1]).replace(/\s+/g, ' ').trim();
    if (phrase && !seen.has(phrase)) {
      seen.add(phrase);
      phrases.push(phrase);
    }
  }
  return phrases;
}

// Normalize a query into the structured shape the ranker consumes. `terms` powers
// term matching and FTS query construction; `ids` and `phrases` power the exact
// evidence gates. `normalizedTermCount` is reported in telemetry.
export function normalizeQuery(query) {
  const raw = String(query ?? '');
  const phrases = extractPhrases(raw);
  const { terms, ids } = tokenize(raw);
  return {
    raw,
    normalized: nfcLower(raw).replace(/\s+/g, ' ').trim(),
    terms,
    ids,
    phrases,
    normalizedTermCount: terms.length
  };
}

// Flatten one projected active record into a single normalized search string for
// the tsvector document. Arrays are joined; scalars appended. The field order is
// fixed so the document (and its tsvector) is byte-stable for a fixed record.
export function buildSearchText(record) {
  const parts = [];
  for (const field of SEARCH_FIELD_ORDER) {
    const value = record[field];
    if (value === undefined || value === null) continue;
    if (Array.isArray(value)) {
      for (const item of value) if (item) parts.push(nfcLower(item));
    } else {
      parts.push(nfcLower(value));
    }
  }
  if (record.source?.path) parts.push(nfcLower(record.source.path));
  if (record.source?.anchor) parts.push(nfcLower(record.source.anchor));
  return parts.join(' ').replace(/\s+/g, ' ').trim();
}

// Derive the lexical evidence surface of a record: its normalized full search
// text, the exact ID token set (record id + any ID tokens embedded in fields),
// the curated-field term set, and the summary term set. The ranker matches query
// evidence against these without re-reading the raw record, keeping scoring
// deterministic and mode-independent.
export function recordLexicalFields(record) {
  const searchText = buildSearchText(record);
  const all = tokenize(searchText);
  const idSet = new Set(all.ids);
  if (record.id) idSet.add(nfcLower(record.id));
  const curatedText = CURATED_FIELDS
    .map((field) => (Array.isArray(record[field]) ? record[field].join(' ') : ''))
    .join(' ');
  const curatedTerms = new Set(tokenize(curatedText).terms);
  const summaryTerms = new Set(tokenize(record.summary || '').terms);
  const allTerms = new Set(all.terms);
  return { searchText, idSet, curatedTerms, summaryTerms, allTerms };
}
