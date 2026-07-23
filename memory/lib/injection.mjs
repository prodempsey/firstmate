// Verified brief injection (Memory PR-4, milestone B).
//
// Turns a governed recall pack (recall.mjs) into a POINTER-ONLY `## Fleet memory`
// block appended to a crew brief at SPAWN TIME, and produces a spawn-time proof
// that records exactly what was retrieved, from which index generation/watermark,
// under what budget — so the injection is verifiable after the fact.
//
// Invariants this module enforces:
//   * Inert by default. The brief is mutated ONLY when there is at least one
//     proven pointer to inject. An empty registry, a proven zero-hit, a
//     recall-failure, an unresolved `{TASK}` placeholder, a non-regular brief file,
//     or an already-injected brief all leave the brief byte-for-byte unchanged.
//     This is what keeps injection inert in the current production state (zero
//     active memories) and fail-open (never fail-wrong) on degradation.
//   * Atomic mutation. Same-directory temp, preserved mode, fsync file, rename,
//     fsync dir, then read back from the canonical path before claiming success.
//   * Pointer-only. The block carries ids, one-line summaries, source pointers,
//     match reasons, confidence, and a `mem show <id>` command — never memory
//     bodies. Source pointers are escaped for Markdown control characters.
//   * Tamper-evident proof. The proof hashes the ENTIRE final brief, not just the
//     block, plus the task section and the block itself. A one-byte edit anywhere
//     after injection invalidates verification.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { sha256, contentHash } from './hash.mjs';

export const BRIEF_INJECTION_PROOF_SCHEMA = 'kraken-memory/brief-injection-proof/v1';
export const MARKER_BEGIN = '<!-- fm:memory:begin -->';
export const MARKER_END = '<!-- fm:memory:end -->';
const STAMP_PREFIX = '<!-- fm:memory:stamp ';
const STAMP_SUFFIX = ' -->';

// Reasons a brief is left unmodified. Every non-injection path names one; there is
// no silent no-op.
export const NOT_INJECTED_REASONS = Object.freeze([
  'recall-failed',
  'inert-empty-registry',
  'proven-zero-hit',
  'unresolved-task-placeholder',
  'brief-not-regular-file',
  'brief-unreadable',
  'already-injected',
  'malformed-existing-block'
]);

function isoNow() {
  return new Date().toISOString();
}

// Escape a source pointer for safe inline Markdown inside a backtick span: drop
// newlines/carriage returns and neutralize backticks (which would end the span)
// and pipes (which would break a rendered table cell), so a hostile or malformed
// source path can never break out of the pointer rendering.
function escapeInline(value) {
  return String(value ?? '')
    .replace(/[\r\n]+/g, ' ')
    .replace(/`/g, "'")
    .replace(/\|/g, '\\|')
    .trim();
}

function renderSource(source) {
  if (!source || !source.path) return '(no source pointer)';
  const anchor = source.anchor ? `#${source.anchor}` : '';
  return `\`${escapeInline(`${source.path}${anchor}`)}\``;
}

// The machine-parseable, versioned stamp embedded in the block. It carries only
// identity/replay fields — NOT a hash of the file it lives in (that would be
// self-referential); the whole-file hash lives in the sidecar proof. Single line.
function renderStamp(stamp) {
  return `${STAMP_PREFIX}${JSON.stringify(stamp)}${STAMP_SUFFIX}`;
}

export function parseStamp(text) {
  const idx = text.indexOf(STAMP_PREFIX);
  if (idx === -1) return null;
  const end = text.indexOf(STAMP_SUFFIX, idx + STAMP_PREFIX.length);
  if (end === -1) return null;
  const json = text.slice(idx + STAMP_PREFIX.length, end);
  try {
    return JSON.parse(json);
  } catch {
    return null;
  }
}

// Locate every begin..end marker block. Returns [{begin, end}] byte offsets.
// More than one is malformed (refuse rather than guess).
export function findMarkerBlocks(text) {
  const blocks = [];
  let from = 0;
  for (;;) {
    const begin = text.indexOf(MARKER_BEGIN, from);
    if (begin === -1) break;
    const end = text.indexOf(MARKER_END, begin + MARKER_BEGIN.length);
    if (end === -1) {
      blocks.push({ begin, end: -1 });
      break;
    }
    blocks.push({ begin, end: end + MARKER_END.length });
    from = end + MARKER_END.length;
  }
  return blocks;
}

// Extract the completed `# Task` section body (text after the `# Task` heading up
// to the next top-level `# ` heading). Returns '' when there is no Task heading.
export function extractTaskSection(text) {
  const lines = text.split('\n');
  let start = -1;
  for (let i = 0; i < lines.length; i += 1) {
    if (/^#\s+Task\s*$/.test(lines[i])) { start = i + 1; break; }
  }
  if (start === -1) return '';
  const body = [];
  for (let i = start; i < lines.length; i += 1) {
    if (/^#\s+\S/.test(lines[i])) break;
    body.push(lines[i]);
  }
  return body.join('\n').trim();
}

export function hasUnresolvedPlaceholder(text) {
  return /\{TASK\}/.test(text);
}

// Deterministic injection id: fingerprints the identity of THIS injection into
// THIS brief, independent of the resulting file bytes (so it can appear in the
// in-file stamp without circularity). Same inputs -> same id.
function injectionIdFor({ manifestId, taskId, project, kind, briefPath, injectedIds, generatedAt }) {
  return contentHash({ manifestId, taskId, project, kind, briefPath, injectedIds, generatedAt });
}

// Render the pointer-only `## Fleet memory` block, markers and stamp included.
export function renderBriefBlock(pack, { taskId, project, kind, injectionId }) {
  const gen = pack.retrievalGeneration ? `index generation ${pack.retrievalGeneration}` : `${pack.retrievalMode} (no derived index)`;
  const seq = pack.canonicalWatermark?.seq ?? '?';
  const header = `## Fleet memory (governed recall — pointers only)`;
  const provenance = `_Recalled ${pack.counts.injected} of ${pack.counts.candidates} candidate memor${pack.counts.candidates === 1 ? 'y' : 'ies'} under a ${pack.budget.maxPointers}-pointer / ${pack.budget.maxBytes}-byte budget from ${gen} at registry watermark seq ${seq}. These are pointers, not the memory itself — run \`mem show <id>\` for the full record, and do not assume an unlisted memory does not exist._`;
  const items = pack.pointers.map((p) => {
    const summary = escapeInline(p.summary);
    const facets = [`scope ${p.scope}`, p.memoryType, p.confidence ? `confidence ${p.confidence}` : null].filter(Boolean).join(' · ');
    const reasons = p.matchReasons.length ? `match: ${p.matchReasons.join(', ')}` : 'match: recalled';
    return `- **${p.id}** — ${summary}\n  ${renderSource(p.source)} · ${facets} · ${reasons} · \`mem show ${p.id}\``;
  });
  const stamp = {
    schema: BRIEF_INJECTION_PROOF_SCHEMA,
    manifestId: pack.manifest.manifestId,
    injectionId,
    taskId,
    project,
    kind,
    retrievalMode: pack.retrievalMode,
    retrievalGeneration: pack.retrievalGeneration,
    canonicalWatermark: pack.canonicalWatermark,
    budget: pack.budget,
    injectedIds: pack.pointers.map((p) => p.id)
  };
  return [MARKER_BEGIN, header, '', provenance, '', items.join('\n'), '', renderStamp(stamp), MARKER_END].join('\n');
}

// Durable atomic file replace preserving the target's mode. Mirrors the PR-1/PR-2
// write discipline: temp in the same dir, fsync the file, rename, fsync the dir.
function atomicReplace(file, data, mode) {
  const dir = path.dirname(file);
  const tmp = path.join(dir, `.${path.basename(file)}.fmmem-${process.pid}-${crypto.randomBytes(4).toString('hex')}`);
  const fd = fs.openSync(tmp, 'w', mode);
  try {
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  try {
    fs.chmodSync(tmp, mode);
  } catch {
    // best effort; a mode we cannot restore is not a correctness failure
  }
  fs.renameSync(tmp, file);
  const dirFd = fs.openSync(dir, 'r');
  try {
    fs.fsyncSync(dirFd);
  } finally {
    fs.closeSync(dirFd);
  }
}

function notInjected(reason, extra = {}) {
  return { injected: false, reason, ...extra };
}

// Build the sidecar proof object for a completed (or declined) injection.
function buildProof({ injected, reason, taskId, project, kind, briefPath, pack, injectionId, wholeFileSha256, briefBlockSha256, taskSectionSha256, byteLength, now }) {
  return {
    schema: BRIEF_INJECTION_PROOF_SCHEMA,
    injected,
    reason: reason ?? null,
    taskId,
    project,
    kind,
    briefPath,
    manifestId: pack.manifest.manifestId,
    injectionId: injectionId ?? null,
    state: pack.state,
    retrievalMode: pack.retrievalMode,
    fallbackReason: pack.fallbackReason ?? null,
    canonicalWatermark: pack.canonicalWatermark ?? null,
    retrievalGeneration: pack.retrievalGeneration ?? null,
    budget: pack.budget,
    injectedIds: injected ? pack.pointers.map((p) => p.id) : [],
    omitted: pack.omitted ?? [],
    counts: pack.counts,
    wholeFileSha256: wholeFileSha256 ?? null,
    briefBlockSha256: briefBlockSha256 ?? null,
    taskSectionSha256: taskSectionSha256 ?? null,
    byteLength: byteLength ?? null,
    manifest: pack.manifest,
    stampedAt: now
  };
}

// Inject the recall pack into the brief on disk, or decline (leaving the brief
// untouched) with a named reason. Returns a result carrying the sidecar proof.
// This function does the disk side effect; the caller writes the proof file.
export function injectBrief({ briefPath, recallPack: pack, taskId, project, kind, now = isoNow() }) {
  // Canonical absolute path so the proof records a stable identity.
  const canonicalPath = path.resolve(briefPath);

  // The brief must be a regular file (never a symlink or directory): refuse to
  // follow a link or write through an unexpected target.
  let lst;
  try {
    lst = fs.lstatSync(canonicalPath);
  } catch {
    return { ...notInjected('brief-unreadable'), proof: buildProof({ injected: false, reason: 'brief-unreadable', taskId, project, kind, briefPath: canonicalPath, pack, now }) };
  }
  if (!lst.isFile()) {
    return { ...notInjected('brief-not-regular-file'), proof: buildProof({ injected: false, reason: 'brief-not-regular-file', taskId, project, kind, briefPath: canonicalPath, pack, now }) };
  }

  let original;
  try {
    original = fs.readFileSync(canonicalPath, 'utf8');
  } catch {
    return { ...notInjected('brief-unreadable'), proof: buildProof({ injected: false, reason: 'brief-unreadable', taskId, project, kind, briefPath: canonicalPath, pack, now }) };
  }

  const declineUnchanged = (reason) => {
    const wholeFileSha256 = sha256(original);
    return {
      ...notInjected(reason),
      proof: buildProof({ injected: false, reason, taskId, project, kind, briefPath: canonicalPath, pack, wholeFileSha256, byteLength: Buffer.byteLength(original, 'utf8'), now })
    };
  };

  // A remaining literal {TASK} means the brief was never finalized. Do not inject
  // into an unfinished brief; leave it exactly as-is.
  if (hasUnresolvedPlaceholder(original)) return declineUnchanged('unresolved-task-placeholder');

  // Fail-open on recall failure: never inject unproven content.
  if (pack.state === 'recall-failed') return declineUnchanged('recall-failed');

  // Inert when there is nothing proven to inject. Distinguish an empty registry
  // (current production state) from a real zero-hit for the proof record.
  if (!pack.pointers || pack.pointers.length === 0) {
    return declineUnchanged(pack.counts?.active === 0 ? 'inert-empty-registry' : 'proven-zero-hit');
  }

  // Refuse to inject twice. A well-formed single existing block is treated as
  // already-injected; anything else (duplicate/torn markers) is malformed.
  const existing = findMarkerBlocks(original);
  if (existing.length === 1 && existing[0].end !== -1) return declineUnchanged('already-injected');
  if (existing.length > 0) return declineUnchanged('malformed-existing-block');

  // Build the block with a deterministic injection id, append it, and write
  // atomically. A single trailing newline separates the block from prior content.
  const injectionId = injectionIdFor({ manifestId: pack.manifest.manifestId, taskId, project, kind, briefPath: canonicalPath, injectedIds: pack.pointers.map((p) => p.id), generatedAt: now });
  const block = renderBriefBlock(pack, { taskId, project, kind, injectionId });
  const separator = original.endsWith('\n') ? '\n' : '\n\n';
  const next = `${original}${separator}${block}\n`;

  atomicReplace(canonicalPath, next, lst.mode & 0o777);

  // Read back from the canonical path and verify the mutation landed exactly once
  // and carries every injected id before claiming success.
  const readBack = fs.readFileSync(canonicalPath, 'utf8');
  const blocks = findMarkerBlocks(readBack);
  if (blocks.length !== 1 || blocks[0].end === -1) {
    return { ...notInjected('readback-block-count'), proof: buildProof({ injected: false, reason: 'readback-block-count', taskId, project, kind, briefPath: canonicalPath, pack, injectionId, now }) };
  }
  const blockText = readBack.slice(blocks[0].begin, blocks[0].end);
  for (const p of pack.pointers) {
    if (!blockText.includes(p.id)) {
      return { ...notInjected('readback-missing-id'), proof: buildProof({ injected: false, reason: 'readback-missing-id', taskId, project, kind, briefPath: canonicalPath, pack, injectionId, now }) };
    }
  }

  const proof = buildProof({
    injected: true,
    reason: null,
    taskId,
    project,
    kind,
    briefPath: canonicalPath,
    pack,
    injectionId,
    wholeFileSha256: sha256(readBack),
    briefBlockSha256: sha256(blockText),
    taskSectionSha256: sha256(extractTaskSection(readBack)),
    byteLength: Buffer.byteLength(readBack, 'utf8'),
    now
  });
  return { injected: true, reason: null, injectionId, briefPath: canonicalPath, block: blockText, proof };
}

function proofPathFor(briefPath) {
  return path.join(path.dirname(path.resolve(briefPath)), 'memory-proof.json');
}

export function writeProof(proofPath, proof) {
  const dir = path.dirname(proofPath);
  fs.mkdirSync(dir, { recursive: true });
  atomicReplace(proofPath, `${JSON.stringify(proof, null, 2)}\n`, 0o644);
}

// Verify a brief against its sidecar proof AFTER THE FACT. Independent of the
// finalizer's return value: it re-reads both files from disk and re-derives every
// hash, so a tampered brief, a swapped memory id, a forged stamp, or a stale proof
// is caught. Returns { ok, checks, failures }.
export function verifyBrief({ briefPath, proofPath, proof: proofArg }) {
  const canonicalPath = path.resolve(briefPath);
  const checks = [];
  const failures = [];
  const record = (name, ok, detail) => { checks.push({ name, ok, detail: detail ?? null }); if (!ok) failures.push(name); };

  let proof = proofArg;
  if (!proof) {
    const pp = proofPath || proofPathFor(canonicalPath);
    try {
      proof = JSON.parse(fs.readFileSync(pp, 'utf8'));
    } catch {
      return { ok: false, checks: [{ name: 'proof-readable', ok: false, detail: 'proof file missing or unparseable' }], failures: ['proof-readable'] };
    }
  }
  record('proof-schema', proof.schema === BRIEF_INJECTION_PROOF_SCHEMA, proof.schema);

  let lst;
  try {
    lst = fs.lstatSync(canonicalPath);
  } catch {
    record('brief-regular-file', false, 'brief missing');
    return { ok: false, checks, failures };
  }
  record('brief-regular-file', lst.isFile(), 'must be a regular file');
  if (!lst.isFile()) return { ok: false, checks, failures };

  const text = fs.readFileSync(canonicalPath, 'utf8');
  const wholeFileSha256 = sha256(text);

  if (!proof.injected) {
    // A declined injection: the brief must carry NO block and, when the proof
    // recorded the unchanged file hash, still match it (proving no drift).
    const blocks = findMarkerBlocks(text);
    record('no-block-for-declined', blocks.length === 0, `${blocks.length} block(s) found`);
    if (proof.wholeFileSha256) record('whole-file-sha256', wholeFileSha256 === proof.wholeFileSha256, 'unchanged brief hash');
    record('not-injected-reason', typeof proof.reason === 'string' && proof.reason.length > 0, proof.reason);
    return { ok: failures.length === 0, checks, failures };
  }

  // An injected brief: exactly one well-formed block, whole-file hash intact, stamp
  // consistent with the proof, and every injected id present.
  const blocks = findMarkerBlocks(text);
  record('exactly-one-block', blocks.length === 1 && blocks[0].end !== -1, `${blocks.length} block(s)`);
  record('whole-file-sha256', wholeFileSha256 === proof.wholeFileSha256, 'whole final brief bytes');
  if (blocks.length === 1 && blocks[0].end !== -1) {
    const blockText = text.slice(blocks[0].begin, blocks[0].end);
    record('block-sha256', sha256(blockText) === proof.briefBlockSha256, 'memory block bytes');
    const stamp = parseStamp(blockText);
    record('stamp-parses', Boolean(stamp), 'embedded stamp is valid JSON');
    if (stamp) {
      record('stamp-manifest', stamp.manifestId === proof.manifestId, 'manifest id matches proof');
      record('stamp-injection', stamp.injectionId === proof.injectionId, 'injection id matches proof');
      record('stamp-ids', Array.isArray(stamp.injectedIds) && stamp.injectedIds.length === proof.injectedIds.length && stamp.injectedIds.every((id, i) => id === proof.injectedIds[i]), 'injected ids match proof');
    }
    for (const id of proof.injectedIds) record(`id-present:${id}`, blockText.includes(id), 'selected id present in block');
  }
  record('task-section-sha256', sha256(extractTaskSection(text)) === proof.taskSectionSha256, 'task section bytes');

  return { ok: failures.length === 0, checks, failures };
}

export { proofPathFor };
