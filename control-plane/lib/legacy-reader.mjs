import nodeFs from 'node:fs';
import path from 'node:path';
import { LegacyReadError } from './errors-s8.mjs';

// Read-only legacy-store reader for `cp migrate-report` (spec section 13).
//
// THIS MODULE NEVER WRITES. It reaches the legacy home through a single injectable
// `io` seam whose surface is READ-ONLY BY CONSTRUCTION: it exposes exactly
// readdirSync / readFileSync / statSync / existsSync and nothing else, so the reader
// physically cannot open a legacy path for write, take a writer-blocking lock, or
// truncate/rotate a ledger. Tests drive the same seam with a tripwire facade that
// throws on any write API and with an on-disk read-only fixture, proving the
// read-only contract is mutation-sensitive, not merely asserted in prose.
//
// The reader's job is tokenization only: enumerate the legacy stores deterministically
// and split each into individual RECORDS with a stable source_ref. It does the minimal
// structural parse a record needs (JSONL -> object-or-malformed, meta -> key/value map,
// status/backlog -> raw line). Canonical mapping and mapped-or-flagged classification
// live in migrate-map.mjs; this module makes no mapping decisions and skips nothing.

// The read-only fs facade. Frozen and delegating only to node:fs READ functions.
// Because it names no write method, no reader code path can mutate a legacy store
// even by accident (the owner-guard-of-legacy analogue to the PGlite owner guard).
export const readOnlyFs = Object.freeze({
  readdirSync: (dir, opts) => nodeFs.readdirSync(dir, opts),
  readFileSync: (p, enc) => nodeFs.readFileSync(p, enc),
  statSync: (p) => nodeFs.statSync(p),
  existsSync: (p) => nodeFs.existsSync(p)
});

// The legacy stores this shadow read enumerates, in a fixed order (spec section 13:
// "legacy task lifecycle JSONL, task-run closeout ledgers, both order ledgers,
// runtime .meta/.status/.turn-ended"). Order here fixes the record order in the
// report, which is part of the determinism contract.
export const LEGACY_STORES = Object.freeze([
  'state-meta',
  'state-status',
  'state-turn-ended',
  'backlog',
  'task-lifecycle',
  'task-runs',
  'captain-orders'
]);

// Resolve the legacy home to shadow-read. Explicit --home / CP_LEGACY_HOME wins so a
// test always drives an ISOLATED fixture home; else FM_HOME. Never guesses a real home.
export function resolveLegacyHome({ explicit, env = process.env } = {}) {
  if (typeof explicit === 'string' && explicit.length > 0) return path.resolve(explicit);
  if (typeof env.CP_LEGACY_HOME === 'string' && env.CP_LEGACY_HOME.length > 0) {
    return path.resolve(env.CP_LEGACY_HOME);
  }
  if (typeof env.FM_HOME === 'string' && env.FM_HOME.length > 0) return path.resolve(env.FM_HOME);
  throw new LegacyReadError('no legacy home: pass --home <path> or set CP_LEGACY_HOME/FM_HOME', {
    hint: 'the read-only shadow read needs a legacy firstmate home to enumerate'
  });
}

// List files in `dir` matching `suffix`, sorted lexicographically for determinism.
// A missing dir is an empty list (a legacy home may legitimately lack a store), but an
// unreadable dir is a loud LegacyReadError so a truncated proposal can never look complete.
function listBySuffix(io, dir, suffix) {
  if (!io.existsSync(dir)) return [];
  let names;
  try {
    names = io.readdirSync(dir);
  } catch (err) {
    throw new LegacyReadError('legacy state directory is unreadable', {
      path: dir, cause: err && err.message ? err.message : String(err)
    });
  }
  return names.filter((n) => n.endsWith(suffix)).sort();
}

function readFileOrThrow(io, p) {
  try {
    return io.readFileSync(p, 'utf8');
  } catch (err) {
    throw new LegacyReadError('legacy store file is unreadable', {
      path: p, cause: err && err.message ? err.message : String(err)
    });
  }
}

// Parse a key=value .meta file into a flat map, preserving first-seen order.
function parseMeta(text) {
  const kv = {};
  for (const line of text.split('\n')) {
    if (line.length === 0) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue; // a meta line with no '=' is not a field; not a record
    const key = line.slice(0, eq);
    const val = line.slice(eq + 1);
    if (!(key in kv)) kv[key] = val;
  }
  return kv;
}

// Parse one JSONL line into an object, or mark it structurally malformed. A malformed
// line is NEVER dropped: it becomes a record the mapper flags (spec: nothing skipped).
function parseJsonLine(line) {
  try {
    const obj = JSON.parse(line);
    if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
      return { __malformed: true, error: 'not a JSON object', raw: line };
    }
    return obj;
  } catch (err) {
    return { __malformed: true, error: err && err.message ? err.message : 'invalid JSON', raw: line };
  }
}

// Emit one record per meta file.
function readStateMeta(io, home) {
  const dir = path.join(home, 'state');
  const out = [];
  for (const name of listBySuffix(io, dir, '.meta')) {
    const rel = path.join('state', name);
    const text = readFileOrThrow(io, path.join(dir, name));
    out.push({ store: 'state-meta', source_ref: rel, raw: text, value: parseMeta(text) });
  }
  return out;
}

// Emit one record per NON-EMPTY status line (each line is a wake-event record).
function readLineStore(io, home, subdir, suffix, store) {
  const dir = path.join(home, subdir);
  const out = [];
  for (const name of listBySuffix(io, dir, suffix)) {
    const rel = path.join(subdir, name);
    const text = readFileOrThrow(io, path.join(dir, name));
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i];
      if (line.trim().length === 0) continue;
      out.push({ store, source_ref: `${rel}#L${i + 1}`, raw: line, value: { line } });
    }
  }
  return out;
}

// Emit one marker record per .turn-ended file (the file's mere existence is the record;
// it carries no content).
function readTurnEnded(io, home) {
  const dir = path.join(home, 'state');
  const out = [];
  for (const name of listBySuffix(io, dir, '.turn-ended')) {
    const rel = path.join('state', name);
    out.push({ store: 'state-turn-ended', source_ref: rel, raw: '', value: { marker: true } });
  }
  return out;
}

// Emit one record per candidate backlog bullet line. A "candidate record" is any line
// that opens like a task bullet (- [ ], - [x], or - **id**); headers and pure prose are
// not records and are not counted. A candidate that yields no id is still emitted so the
// mapper can flag it (nothing skipped).
function readBacklog(io, home) {
  const p = path.join(home, 'data', 'backlog.md');
  if (!io.existsSync(p)) return [];
  const text = readFileOrThrow(io, p);
  const lines = text.split('\n');
  const out = [];
  let section = null;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const heading = /^##\s+(.+?)\s*$/.exec(line);
    if (heading) {
      section = heading[1].trim();
      continue;
    }
    if (/^- (\[[ xX]\]|\*\*)/.test(line)) {
      out.push({
        store: 'backlog',
        source_ref: `data/backlog.md#L${i + 1}`,
        raw: line,
        value: { line, section }
      });
    }
  }
  return out;
}

function readJsonlStore(io, home, name, store) {
  const p = path.join(home, 'state', name);
  if (!io.existsSync(p)) return [];
  const text = readFileOrThrow(io, p);
  const lines = text.split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.trim().length === 0) continue;
    out.push({
      store,
      source_ref: `state/${name}#L${i + 1}`,
      raw: line,
      value: parseJsonLine(line)
    });
  }
  return out;
}

// Enumerate every legacy store under `home` and return a flat, deterministically-ordered
// list of records ({ store, source_ref, raw, value }). Pure reads through the io seam.
export function readLegacyRecords(home, { io = readOnlyFs } = {}) {
  return [
    ...readStateMeta(io, home),
    ...readLineStore(io, home, 'state', '.status', 'state-status'),
    ...readTurnEnded(io, home),
    ...readBacklog(io, home),
    ...readJsonlStore(io, home, 'task-lifecycle.jsonl', 'task-lifecycle'),
    ...readJsonlStore(io, home, 'task-runs.jsonl', 'task-runs'),
    ...readJsonlStore(io, home, 'captain-orders.jsonl', 'captain-orders')
  ];
}
