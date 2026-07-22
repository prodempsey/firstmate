import nodeFs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { LegacyReadError, MigrateReportError } from './errors-s8.mjs';

// Read-only legacy-store reader for `cp migrate-report` (spec section 13).
//
// THIS MODULE NEVER WRITES. It reaches every legacy path through a single injectable
// `io` seam whose surface is READ-ONLY BY CONSTRUCTION: it exposes exactly
// readdirSync / readFileSync / statSync / existsSync and nothing else, so the reader
// physically cannot open a legacy path for write, take a writer-blocking lock, or
// truncate/rotate a ledger.
//
// The reader's job is tokenization only: enumerate the legacy stores deterministically
// and split each into individual RECORDS with a stable source_ref and a content digest.
// It does the minimal structural parse a record needs (JSONL -> object-or-malformed,
// meta -> key/value map, status/backlog -> raw line). Canonical mapping and
// mapped-or-flagged classification live in migrate-map.mjs; this module makes no mapping
// decisions and skips nothing. It also returns a `sources` manifest naming every store
// it consulted and whether it resolved, so an omitted store can never be silent.

// The read-only fs facade. Frozen and delegating only to node:fs READ functions.
export const readOnlyFs = Object.freeze({
  readdirSync: (dir, opts) => nodeFs.readdirSync(dir, opts),
  readFileSync: (p, enc) => nodeFs.readFileSync(p, enc),
  statSync: (p) => nodeFs.statSync(p),
  existsSync: (p) => nodeFs.existsSync(p)
});

// The legacy stores this shadow read enumerates, in a fixed order (spec section 13:
// "legacy task lifecycle JSONL, task-run closeout ledgers, BOTH order ledgers, runtime
// .meta/.status/.turn-ended, and Bridge History projections"). Order here fixes the
// record order in the report, which is part of the determinism contract.
export const LEGACY_STORES = Object.freeze([
  'state-meta',
  'state-status',
  'state-turn-ended',
  'backlog',
  'done-archive',
  'task-lifecycle',
  'task-runs',
  'captain-orders',
  'authoritative-orders',
  'bridge-history'
]);

function sha256hex(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

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

// Read the first non-empty, comment-stripped line of a pointer file (config/orders-path
// style), tilde-expanding a leading ~/ exactly as bin/fm-order-lib.sh does.
function readPointer(io, pointerPath, env) {
  try {
    const first = io.readFileSync(pointerPath, 'utf8')
      .split('\n').map((l) => l.replace(/#.*/, '').trim()).find((l) => l.length > 0);
    if (!first) return null;
    return first.startsWith('~/') ? path.join(env.HOME || '', first.slice(2)) : first;
  } catch {
    return null;
  }
}

// Resolve the AUTHORITATIVE external captain order ledger (spec section 13 "both order
// ledgers"; the in-home state/captain-orders.jsonl is the OTHER, legacy folded one). The
// resolution mirrors Firstmate's own contract (bin/fm-order-lib.sh): explicit
// --orders-path, then CP_ORDERS_PATH/FM_ORDERS_PATH, then $home/config/orders-path. It
// deliberately does NOT reimplement the hashed XDG default (one-owner rule: that hash is
// owned by fm-backend-hometag-lib.sh) - for a cutover run Firstmate passes the resolved
// path. Unresolved is a LOUD error, never a silent omission, because cutover evidence
// that drops the authoritative order ledger is exactly the S8 failure QA caught.
export function resolveAuthoritativeOrdersPath({ explicit, home, env = process.env, io = readOnlyFs } = {}) {
  if (typeof explicit === 'string' && explicit.length > 0) return path.resolve(explicit);
  for (const k of ['CP_ORDERS_PATH', 'FM_ORDERS_PATH']) {
    if (typeof env[k] === 'string' && env[k].length > 0) return path.resolve(env[k]);
  }
  const ptr = readPointer(io, path.join(home, 'config', 'orders-path'), env);
  if (ptr) return path.resolve(ptr);
  throw new MigrateReportError(
    'authoritative order ledger unresolved: pass --orders-path or set CP_ORDERS_PATH/FM_ORDERS_PATH or provide config/orders-path',
    { home }
  );
}

// Resolve the Bridge History projection export (spec section 13). Bridge History is a
// DERIVED view (fleet-bridge buildTaskHistory over backlog/archive/runs/bugs/orders), so
// migrate-report ingests a read-only EXPORT of it via an EXPLICIT interface: --bridge-history
// or CP_BRIDGE_HISTORY_PATH. Absent by default (a derived projection Firstmate optionally
// exports for cutover); its presence/absence is declared in the report's sources manifest,
// so it is never silently omitted.
export function resolveBridgeHistoryPath({ explicit, env = process.env } = {}) {
  if (typeof explicit === 'string' && explicit.length > 0) return path.resolve(explicit);
  if (typeof env.CP_BRIDGE_HISTORY_PATH === 'string' && env.CP_BRIDGE_HISTORY_PATH.length > 0) {
    return path.resolve(env.CP_BRIDGE_HISTORY_PATH);
  }
  return null;
}

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

function rec(store, sourceRef, raw, value) {
  return { store, source_ref: sourceRef, raw, value, digest: sha256hex(raw) };
}

function parseMeta(text) {
  const kv = {};
  for (const line of text.split('\n')) {
    if (line.length === 0) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq);
    const val = line.slice(eq + 1);
    if (!(key in kv)) kv[key] = val;
  }
  return kv;
}

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

function readStateMeta(io, home) {
  const dir = path.join(home, 'state');
  const out = [];
  for (const name of listBySuffix(io, dir, '.meta')) {
    const rel = path.join('state', name);
    const text = readFileOrThrow(io, path.join(dir, name));
    out.push(rec('state-meta', rel, text, parseMeta(text)));
  }
  return out;
}

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
      out.push(rec(store, `${rel}#L${i + 1}`, line, { line }));
    }
  }
  return out;
}

function readTurnEnded(io, home) {
  const dir = path.join(home, 'state');
  const out = [];
  for (const name of listBySuffix(io, dir, '.turn-ended')) {
    const rel = path.join('state', name);
    out.push(rec('state-turn-ended', rel, rel, { marker: true }));
  }
  return out;
}

// Parse candidate task bullets from a curated markdown file (backlog.md or
// done-archive.md). A "candidate record" is any line that opens like a task bullet;
// headers and pure prose are not records and are not counted. A candidate that yields no
// id is still emitted so the mapper can flag it (nothing skipped).
function readMarkdownBullets(io, home, relPath, store) {
  const p = path.join(home, relPath);
  if (!io.existsSync(p)) return [];
  const text = readFileOrThrow(io, p);
  const lines = text.split('\n');
  const out = [];
  let section = null;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const heading = /^##\s+(.+?)\s*$/.exec(line);
    if (heading) { section = heading[1].trim(); continue; }
    if (/^- (\[[ xX]\]|\*\*)/.test(line)) {
      out.push(rec(store, `${relPath}#L${i + 1}`, line, { line, section }));
    }
  }
  return out;
}

function readJsonlFile(io, absPath, refPrefix, store) {
  if (!io.existsSync(absPath)) return [];
  const text = readFileOrThrow(io, absPath);
  const lines = text.split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.trim().length === 0) continue;
    out.push(rec(store, `${refPrefix}#L${i + 1}`, line, parseJsonLine(line)));
  }
  return out;
}

// Ingest a Bridge History projection export. Accepts a JSON array (each element one
// projection record) or JSONL (each line one record); a whole-file parse failure that is
// not an array falls back to line-by-line so a malformed projection still surfaces record
// by record instead of vanishing.
function readBridgeHistory(io, bridgePath) {
  if (!bridgePath || !io.existsSync(bridgePath)) return [];
  const text = readFileOrThrow(io, bridgePath);
  let arr = null;
  try {
    const whole = JSON.parse(text);
    if (Array.isArray(whole)) arr = whole;
  } catch {
    arr = null;
  }
  const out = [];
  if (arr) {
    for (let i = 0; i < arr.length; i += 1) {
      const raw = JSON.stringify(arr[i]);
      out.push(rec('bridge-history', `bridge-history[${i}]`, raw, arr[i]));
    }
    return out;
  }
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.trim().length === 0) continue;
    out.push(rec('bridge-history', `bridge-history#L${i + 1}`, line, parseJsonLine(line)));
  }
  return out;
}

// Enumerate every legacy store under `home` (plus the resolved external order ledger and
// the optional Bridge History export) and return { records, sources }. `records` is a flat,
// deterministically-ordered list; `sources` is the manifest naming each store, its resolved
// path, whether it resolved, and its discovered count - so an omission is always visible.
export function readLegacyRecords(home, { io = readOnlyFs, ordersPath, bridgeHistoryPath } = {}) {
  const groups = [
    ['state-meta', path.join(home, 'state'), readStateMeta(io, home)],
    ['state-status', path.join(home, 'state'), readLineStore(io, home, 'state', '.status', 'state-status')],
    ['state-turn-ended', path.join(home, 'state'), readTurnEnded(io, home)],
    ['backlog', path.join(home, 'data', 'backlog.md'), readMarkdownBullets(io, home, path.join('data', 'backlog.md'), 'backlog')],
    ['done-archive', path.join(home, 'data', 'done-archive.md'), readMarkdownBullets(io, home, path.join('data', 'done-archive.md'), 'done-archive')],
    ['task-lifecycle', path.join(home, 'state', 'task-lifecycle.jsonl'), readJsonlFile(io, path.join(home, 'state', 'task-lifecycle.jsonl'), 'state/task-lifecycle.jsonl', 'task-lifecycle')],
    ['task-runs', path.join(home, 'state', 'task-runs.jsonl'), readJsonlFile(io, path.join(home, 'state', 'task-runs.jsonl'), 'state/task-runs.jsonl', 'task-runs')],
    ['captain-orders', path.join(home, 'state', 'captain-orders.jsonl'), readJsonlFile(io, path.join(home, 'state', 'captain-orders.jsonl'), 'state/captain-orders.jsonl', 'captain-orders')],
    ['authoritative-orders', ordersPath, readJsonlFile(io, ordersPath, ordersPath || '<unresolved>', 'authoritative-orders')],
    ['bridge-history', bridgeHistoryPath || null, readBridgeHistory(io, bridgeHistoryPath)]
  ];
  const records = [];
  const sources = [];
  for (const [store, storePath, storeRecords] of groups) {
    records.push(...storeRecords);
    sources.push({
      store,
      path: storePath || null,
      resolved: storePath != null,
      discovered: storeRecords.length
    });
  }
  return { records, sources };
}
