// Conservative migration dry-run + captain-gated activation apply (PR-3, Milestone A).
//
// `runDryRun` scans the corpus (migrate-sources.mjs), assigns stable proposal ids,
// computes a content digest, renders a captain-facing report, and writes both a
// machine-readable proposal file and the report — with ZERO writes to the canonical
// memory registry (memory-registry.jsonl / memory-index.json / activity). The dry-run
// is the whole PR-3 product: it produces the proposal surface; it never activates.
//
// `applyMigration` is the OPTIONAL apply path. It is gated behind an explicit
// `--captain-approved <digest>` that must equal the recomputed digest of the exact
// proposal file being applied — the same consent pattern as cp shadow-reconcile
// (the approval names the exact reviewed artifact by its digest; a changed corpus
// yields a new digest and invalidates a stale approval). The activation decision is
// the captain's: only proposal ids the captain names in `activate` become active;
// every other candidate is merely `proposed`.
//
// Idempotency:
//   * The dry-run is deterministic — same corpus yields the same digest and the same
//     proposal content (only the `generatedAt` stamp varies), so re-running is a
//     no-op in effect and safe to repeat.
//   * The apply derives deterministic event ids from the approved digest + proposal
//     id, so re-applying the same approved proposal re-appends nothing (the registry's
//     own eventId de-dup skips it) — proven by the receipt's per-row `skipped` flags.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { contentHash, sha256, stableJson } from './hash.mjs';
import { appendRegistryEvent, foldRegistry } from './registry.mjs';
import { registryPaths } from './paths.mjs';
import { MIGRATION_PARSER_VERSION, enumerateCorpus } from './migrate-sources.mjs';

export const MIGRATION_PROPOSAL_SCHEMA = 'kraken-memory/migration-proposal/v1';
export const MIGRATION_RECEIPT_SCHEMA = 'kraken-memory/migration-receipt/v1';
export const MIGRATION_TOOL_VERSION = 'migration-tool/v1';
export const DEFAULT_MAX_ACTIVATION = 10;

// Dispositions that a proposal may carry INTO the apply path. Only `candidate` is
// activatable in PR-3; `superseded`/`retired`/`quarantined` require successor links
// or captain judgement and are surfaced as advisory metadata, never auto-applied.
const ACTIVATABLE_DISPOSITIONS = new Set(['candidate']);

// Durable, atomic file replace (same discipline as the registry/retrieval writers):
// temp in the same dir, fsync the file, rename, fsync the dir so the rename is durable.
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

// The content fields a migrated record would carry. This is the per-proposal
// contentDigest input and the record payload the apply path writes.
function recordContent(proposal) {
  return {
    summary: proposal.summary,
    body: proposal.body,
    memoryType: proposal.memoryType,
    scope: proposal.scope,
    projects: proposal.projects,
    taskKinds: proposal.taskKinds,
    keywords: proposal.keywords,
    aliases: proposal.aliases,
    entities: proposal.entities,
    commands: proposal.commands,
    failureModes: proposal.failureModes,
    relatedTerms: proposal.relatedTerms,
    confidence: proposal.confidence,
    validFrom: proposal.validFrom,
    source: { path: proposal.provenance.path, anchor: proposal.provenance.anchor }
  };
}

// Stable proposal id: derived from the source key + anchor only (NOT line numbers),
// so incidental reformatting above an entry does not renumber it, while a genuine
// content change is caught by the digest instead.
function proposalIdFor(proposal) {
  const key = `${proposal.provenance.source}\n${proposal.provenance.anchor}`;
  return `MIG-${sha256(key).slice(0, 12)}`;
}

// The volatile / non-portable top-level keys excluded from the approval digest: the
// wall-clock stamp, the absolute corpus root (so the digest is machine-independent),
// and the self-referential digest field itself.
const NON_DIGEST_KEYS = new Set(['generatedAt', 'corpusRoot', 'digest']);

// The canonical approval payload: the ENTIRE proposal document minus the volatile
// keys above. Binding the whole document — every candidate field and every
// source-review field, not a hand-picked projection — is what makes the approval
// exact: any tamper to any bound field (including a candidate's stored contentDigest,
// disposition, provenance, surveyed headings, or a source hash) changes the digest
// and invalidates a prior approval (QA finding F1).
function canonicalProposalDoc(proposal) {
  const out = {};
  for (const [key, value] of Object.entries(proposal)) {
    if (NON_DIGEST_KEYS.has(key)) continue;
    out[key] = value;
  }
  return out;
}

export function computeDigest(proposal) {
  return sha256(stableJson(canonicalProposalDoc(proposal)));
}

// Build the in-memory proposal object from a corpus root. Pure aside from the corpus
// reads done by enumerateCorpus; never touches the registry.
export function buildProposal(corpusRoot, options = {}) {
  const { sources, proposals } = enumerateCorpus(corpusRoot);
  const withIds = proposals.map((p) => {
    const proposalId = proposalIdFor(p);
    return { ...p, proposalId, contentDigest: contentHash(recordContent({ ...p })) };
  });
  // Stable order: by proposalId, so the file and digest do not depend on corpus
  // traversal order.
  withIds.sort((a, b) => (a.proposalId < b.proposalId ? -1 : a.proposalId > b.proposalId ? 1 : 0));

  const counts = { total: withIds.length, byDisposition: {}, byType: {} };
  for (const p of withIds) {
    counts.byDisposition[p.disposition] = (counts.byDisposition[p.disposition] || 0) + 1;
    counts.byType[p.memoryType] = (counts.byType[p.memoryType] || 0) + 1;
  }

  const proposal = {
    schema: MIGRATION_PROPOSAL_SCHEMA,
    parserVersion: MIGRATION_PARSER_VERSION,
    toolVersion: MIGRATION_TOOL_VERSION,
    generatedAt: options.generatedAt || new Date().toISOString(),
    corpusRoot,
    counts,
    sources,
    proposals: withIds
  };
  proposal.digest = computeDigest(proposal);
  return proposal;
}

// Flatten every refused path (file sources and glob sources) into one list, so the
// report and the CLI can surface them prominently. A refused source is never read.
export function collectRefusals(sources) {
  const out = [];
  for (const s of sources || []) {
    if (s.refused && s.refusedReason) out.push({ path: s.path, reason: s.refusedReason });
    for (const f of s.refusedFiles || []) out.push({ path: f.path, reason: f.reason });
  }
  return out;
}

// Render the captain-facing migration report. This is the human proposal surface:
// the corpus enumeration, every proposed record with provenance/type/confidence, the
// digest, and the EXACT approval command — stated as the captain's decision.
export function renderReport(proposal, options = {}) {
  const lines = [];
  const proposalFile = options.proposalFile || '<proposal.json>';
  lines.push('# Memory migration — conservative dry-run proposal');
  lines.push('');
  lines.push(`- Generated: ${proposal.generatedAt}`);
  lines.push(`- Corpus root: \`${proposal.corpusRoot}\``);
  lines.push(`- Proposal digest: \`${proposal.digest}\``);
  lines.push(`- Parser: \`${proposal.parserVersion}\` · Tool: \`${proposal.toolVersion}\``);
  lines.push(`- Proposed records: ${proposal.counts.total}`);
  lines.push('');
  lines.push('> This is a DRY RUN. No memory record has been created or activated.');
  lines.push('> Every proposed record defaults to `candidate` with `confidence: unverified`.');
  lines.push('> **Activation is the captain\'s decision** — see "Applying an approved activation set" below.');
  lines.push('');

  const refusals = collectRefusals(proposal.sources);
  if (refusals.length) {
    lines.push('## ⚠ Refused sources (not read)');
    lines.push('');
    lines.push('These declared corpus paths were REFUSED before any read — a symlink, a path');
    lines.push('escaping the corpus root, or a secret-class file. Their content was never copied');
    lines.push('into any candidate. Investigate before trusting the corpus:');
    lines.push('');
    for (const r of refusals) lines.push(`- \`${r.path}\` — ${r.reason}`);
    lines.push('');
  }

  lines.push('## Corpus sources considered');
  lines.push('');
  lines.push(`| Source | Policy | Path | Present | Items | Note |`);
  lines.push(`| --- | --- | --- | --- | --- | --- |`);
  for (const s of proposal.sources) {
    const present = s.refused ? 'REFUSED' : (s.exists ? 'yes' : 'no');
    const items = s.policy === 'extract' ? `${s.itemCount} extracted` : `${s.itemCount} surveyed`;
    lines.push(`| ${s.label} (\`${s.key}\`) | ${s.policy} | \`${s.path}\` | ${present} | ${items} | ${s.reason} |`);
  }
  lines.push('');

  const surveyed = proposal.sources.filter((s) => s.policy === 'survey' && s.exists);
  if (surveyed.length) {
    lines.push('### Surveyed (not proposed) detail');
    lines.push('');
    const LISTING_CAP = 50;
    for (const s of surveyed) {
      lines.push(`- **${s.label}** (\`${s.path}\`): ${s.itemCount} section(s) — surveyed only.`);
      if (s.surveyedHeadings?.length) {
        for (const h of s.surveyedHeadings) lines.push(`  - ${h}`);
      }
      if (s.files?.length) {
        for (const f of s.files.slice(0, LISTING_CAP)) lines.push(`  - \`${f.path}\` — ${f.sections} section(s)`);
        if (s.files.length > LISTING_CAP) lines.push(`  - …and ${s.files.length - LISTING_CAP} more file(s)`);
      }
    }
    lines.push('');
  }

  lines.push('## Proposed candidate records');
  lines.push('');
  const dispositionCounts = Object.entries(proposal.counts.byDisposition)
    .sort()
    .map(([k, v]) => `${k}: ${v}`)
    .join(', ');
  lines.push(`Disposition summary: ${dispositionCounts || 'none'}.`);
  lines.push('');
  if (proposal.proposals.length === 0) {
    lines.push('_No experience-memory records were extracted from the corpus._');
    lines.push('');
  }
  for (const p of proposal.proposals) {
    lines.push(`### ${p.proposalId} — ${p.summary}`);
    lines.push('');
    lines.push(`- Type: \`${p.memoryType}\` · Scope: \`${p.scope}\` · Confidence: \`${p.confidence}\``);
    lines.push(`- Disposition: **${p.disposition}** — ${p.dispositionReason}`);
    lines.push(`- Provenance: \`${p.provenance.path}\` anchor \`${p.provenance.anchor}\` (lines ${p.provenance.lineStart}–${p.provenance.lineEnd})`);
    if (p.validFrom) lines.push(`- Valid from: ${p.validFrom}`);
    if (p.commands.length) lines.push(`- Commands: ${p.commands.map((c) => `\`${c}\``).join(', ')}`);
    if (p.entities.length) lines.push(`- Entities: ${p.entities.map((e) => `\`${e}\``).join(', ')}`);
    if (p.keywords.length) lines.push(`- Keywords: ${p.keywords.join(', ')}`);
    if (p.evidence.length) lines.push(`- Evidence: ${p.evidence.map((e) => `${e.type}:${e.ref}`).join(', ')}`);
    lines.push(`- Content digest: \`${p.contentDigest}\``);
    lines.push('');
  }

  lines.push('## Applying an approved activation set');
  lines.push('');
  lines.push('The captain reviews the records above and chooses which (if any) to activate.');
  lines.push('Everything not named is created as a `candidate` — safe, inert, and curatable later.');
  lines.push('');
  lines.push('Apply is gated on the exact proposal digest (consent binds to this exact proposal):');
  lines.push('');
  lines.push('```sh');
  lines.push(`mem migrate apply \\`);
  lines.push(`  --proposal ${proposalFile} \\`);
  lines.push(`  --captain-approved ${proposal.digest} \\`);
  lines.push(`  --activate ${proposal.proposals[0]?.proposalId || '<MIG-id>'} [--activate <MIG-id> ...]`);
  lines.push('```');
  lines.push('');
  lines.push(`- Omitting every \`--activate\` proposes all candidates and activates none.`);
  lines.push(`- The activation set is capped at ${DEFAULT_MAX_ACTIVATION} records (override with \`--max-activation\`).`);
  lines.push(`- A changed corpus produces a new digest, which rejects this stale approval.`);
  lines.push('');
  return lines.join('\n');
}

export function migrationPaths(outDir) {
  return {
    dir: outDir,
    proposal: path.join(outDir, 'migration-proposal.json'),
    report: path.join(outDir, 'migration-dry-run-report.md'),
    receipt: path.join(outDir, 'migration-receipt.json')
  };
}

// Run the dry-run end to end: build the proposal, render the report, and write both
// atomically under outDir. Returns a compact summary. NEVER writes to the registry.
export function runDryRun(corpusRoot, outDir, options = {}) {
  const proposal = buildProposal(corpusRoot, options);
  const paths = migrationPaths(outDir);
  const report = renderReport(proposal, { proposalFile: paths.proposal });
  atomicWriteFile(paths.proposal, `${JSON.stringify(proposal, null, 2)}\n`);
  atomicWriteFile(paths.report, `${report}\n`);
  const refusals = collectRefusals(proposal.sources);
  return {
    ok: true,
    digest: proposal.digest,
    proposalFile: paths.proposal,
    reportFile: paths.report,
    counts: proposal.counts,
    refusals,
    sources: proposal.sources.map((s) => ({ key: s.key, policy: s.policy, exists: s.exists, refused: Boolean(s.refused), itemCount: s.itemCount }))
  };
}

function readProposalFile(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (error) {
    throw new Error(`proposal file unreadable: ${file}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`proposal file is not valid JSON: ${file}`);
  }
  if (!parsed || parsed.schema !== MIGRATION_PROPOSAL_SCHEMA) {
    throw new Error(`proposal file has wrong or missing schema (expected ${MIGRATION_PROPOSAL_SCHEMA})`);
  }
  if (!Array.isArray(parsed.proposals)) {
    throw new Error('proposal file has no proposals array');
  }
  return parsed;
}

// Apply an approved proposal against the registry. FAIL-CLOSED gates, in order:
//   1. proposal file readable and correct schema;
//   2. --captain-approved digest supplied;
//   3. the supplied digest equals the recomputed digest of THIS proposal file
//      (a changed proposal/corpus, or a wrong digest, is refused — no writes);
//   4. the stored `digest` field, if present, also equals the recomputed digest
//      (a tampered file whose stored digest disagrees with its content is refused);
//   5. every id in the activation set exists in the proposal;
//   6. every activation target has an activatable disposition;
//   7. the activation set is within the cap.
// Only after every gate passes does it append events: a `proposed` (candidate) event
// per proposal, and an `activated` event (captain authority, validation.ref = the
// approved digest) for each activation target. Deterministic event ids make re-apply
// a no-op. Returns a receipt written under the proposal's directory.
export async function applyMigration(registryDir, options = {}) {
  const { proposalFile, approvedDigest, activate = [], maxActivation = DEFAULT_MAX_ACTIVATION } = options;
  if (!proposalFile) throw new Error('apply requires --proposal <file>');
  if (approvedDigest === undefined || approvedDigest === null || approvedDigest === '') {
    throw new Error('apply requires --captain-approved <digest> (the exact reviewed proposal digest)');
  }
  const proposal = readProposalFile(proposalFile);
  const recomputed = computeDigest(proposal);
  if (proposal.digest && proposal.digest !== recomputed) {
    throw new Error('proposal file is inconsistent: stored digest does not match its content');
  }
  if (approvedDigest !== recomputed) {
    throw new Error(`--captain-approved digest does not match this proposal (expected ${recomputed})`);
  }

  // Every candidate's stored contentDigest must equal the hash of its own content.
  // The whole-document digest above already binds contentDigest, so a lone mutation
  // is caught there; this is the explicit internal-consistency gate QA asked for, and
  // it fails closed before any write so an inconsistent artifact is never applied.
  for (const p of proposal.proposals) {
    const expected = contentHash(recordContent(p));
    if (p.contentDigest !== expected) {
      throw new Error(`proposal candidate ${p.proposalId} contentDigest is inconsistent with its content`);
    }
  }

  const byId = new Map(proposal.proposals.map((p) => [p.proposalId, p]));
  const activationSet = [...new Set(activate)];
  for (const id of activationSet) {
    const target = byId.get(id);
    if (!target) throw new Error(`--activate names a proposal not in this file: ${id}`);
    if (!ACTIVATABLE_DISPOSITIONS.has(target.disposition)) {
      throw new Error(`--activate ${id} has non-activatable disposition '${target.disposition}'`);
    }
  }
  if (activationSet.length > maxActivation) {
    throw new Error(`activation set of ${activationSet.length} exceeds the cap of ${maxActivation} (raise with --max-activation)`);
  }

  const shortDigest = recomputed.slice(0, 12);
  const activationLookup = new Set(activationSet);
  const proposed = [];
  const activated = [];

  for (const p of proposal.proposals) {
    const content = recordContent(p);
    const proposeEventId = `mig-${shortDigest}-propose-${p.proposalId}`;
    const proposeResult = await appendRegistryEvent(registryDir, {
      eventId: proposeEventId,
      event: 'proposed',
      actor: { kind: 'migration', id: 'mem-migrate' },
      fields: {
        summary: content.summary,
        body: content.body,
        memoryType: content.memoryType,
        scope: content.scope,
        projects: content.projects,
        taskKinds: content.taskKinds,
        keywords: content.keywords,
        aliases: content.aliases,
        entities: content.entities,
        commands: content.commands,
        failureModes: content.failureModes,
        relatedTerms: content.relatedTerms,
        confidence: content.confidence,
        validFrom: content.validFrom,
        source: content.source,
        riskClass: 'standard'
      },
      evidence: p.evidence,
      reason: `migration candidate from ${p.provenance.path}#${p.provenance.anchor}`
    });
    const memId = proposeResult.event.memId;
    proposed.push({ proposalId: p.proposalId, memId, eventId: proposeEventId, skipped: proposeResult.skipped });

    if (activationLookup.has(p.proposalId)) {
      const activateEventId = `mig-${shortDigest}-activate-${p.proposalId}`;
      const activateResult = await appendRegistryEvent(registryDir, {
        eventId: activateEventId,
        event: 'activated',
        memId,
        actor: { kind: 'captain', id: 'captain' },
        fields: { confidence: 'observed' },
        evidence: p.evidence.length ? p.evidence : [{ type: 'migration', ref: p.provenance.anchor }],
        validation: { method: 'captain', by: 'captain', ref: approvedDigest }
      });
      activated.push({ proposalId: p.proposalId, memId, eventId: activateEventId, skipped: activateResult.skipped });
    }
  }

  const receipt = {
    schema: MIGRATION_RECEIPT_SCHEMA,
    appliedAt: options.appliedAt || new Date().toISOString(),
    digest: recomputed,
    proposalFile,
    proposedCount: proposed.length,
    activatedCount: activated.length,
    proposed,
    activated
  };
  const receiptFile = migrationPaths(path.dirname(proposalFile)).receipt;
  try {
    atomicWriteFile(receiptFile, `${JSON.stringify(receipt, null, 2)}\n`);
    receipt.receiptFile = receiptFile;
  } catch {
    // The receipt is a convenience record; a write failure must not undo the applied
    // (and idempotent) registry events. Report without the file path.
    receipt.receiptFile = null;
  }
  return { ok: true, ...receipt };
}

// Read-only helper: fold the registry and report how many migration-provenance
// records already exist, so a caller can preview idempotency without appending.
export function migrationFootprint(registryDir) {
  const fold = foldRegistry(registryPaths(registryDir));
  let migrated = 0;
  for (const record of fold.records.values()) {
    if (record.proposedBy?.kind === 'migration') migrated += 1;
  }
  return { migrated, total: fold.records.size };
}
