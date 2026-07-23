import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { afterEach } from 'node:test';
import { registryPaths } from '../lib/paths.mjs';
import { foldRegistry } from '../lib/registry.mjs';
import { applyMigration, computeDigest, runDryRun } from '../lib/migrate.mjs';
import { cleanTracked, tmpRegistry } from './helpers.mjs';

const scratch = new Set();
function mkdir(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  scratch.add(dir);
  return dir;
}
function mkCorpus(files) {
  const root = mkdir('mem-corpus-');
  for (const [rel, content] of Object.entries(files)) {
    const abs = path.join(root, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, content);
  }
  return root;
}
afterEach(() => {
  for (const dir of scratch) fs.rmSync(dir, { recursive: true, force: true });
  scratch.clear();
  cleanTracked();
});

const CORPUS = {
  'data/learnings.md': `# L

## 2026-07-14 — Store full verbatim prompts

**Rule:** \`bin/fm-order.sh add\` the whole thing. bug \`bug-20260714222918-9e8a1c39\`.

## 2026-07-12 — Cockpit dies on broad kills

crews \`pkill\` \`node server.js\`.

## 2026-07-10 — Retired guidance [SUPERSEDED, DO NOT FOLLOW]

replaced.
`
};

// Build a proposal file and return { proposalFile, proposal, digest, candidateIds }.
function makeProposal(corpusFiles = CORPUS) {
  const corpus = mkCorpus(corpusFiles);
  const out = mkdir('mem-out-');
  const result = runDryRun(corpus, out);
  const proposal = JSON.parse(fs.readFileSync(result.proposalFile, 'utf8'));
  const candidateIds = proposal.proposals.filter((p) => p.disposition === 'candidate').map((p) => p.proposalId);
  return { proposalFile: result.proposalFile, proposal, digest: result.digest, candidateIds };
}

function registryBytes(dir) {
  const rp = registryPaths(dir);
  return fs.existsSync(rp.registry) ? fs.readFileSync(rp.registry) : Buffer.alloc(0);
}

// A deliberately RICH corpus so the generated proposal exercises every source shape:
// extract records (candidate + superseded), a survey file with populated
// surveyedHeadings, a glob source with BOTH an accepted file (populated `files`) and a
// refused symlinked child (populated `refusedFiles`), and an absent glob (empty
// arrays). This makes the whole-document leaf walk below cover every leaf the schema
// can produce, not just the ones present in a minimal corpus.
function makeRichProposal() {
  const corpus = mkCorpus({
    ...CORPUS,
    'data/captain.md': '# Captain\n\n## Working style\n\nterse\n\n## Escalation\n\nfull urls\n',
    'projects/demo/AGENTS.md': '# Demo\n\n## Build\n\nmake\n'
  });
  const outer = mkdir('mem-outer-');
  fs.writeFileSync(path.join(outer, 'creds.env'), 'TOKEN=SECRET\n');
  fs.mkdirSync(path.join(corpus, 'projects', 'evil'), { recursive: true });
  fs.symlinkSync(path.join(outer, 'creds.env'), path.join(corpus, 'projects', 'evil', 'AGENTS.md'));
  const out = mkdir('mem-out-');
  const result = runDryRun(corpus, out);
  const proposal = JSON.parse(fs.readFileSync(result.proposalFile, 'utf8'));
  return { proposalFile: result.proposalFile, proposal, digest: result.digest };
}

// The volatile top-level keys that are intentionally NOT bound by the approval digest.
const SKIP_TOP = new Set(['generatedAt', 'corpusRoot', 'digest']);

// Enumerate every leaf path of a proposal document (arrays element-wise; an empty
// array/object is itself a leaf), skipping the three volatile top-level keys.
function leafPaths(node, prefix = []) {
  if (Array.isArray(node)) {
    if (node.length === 0) return [prefix];
    return node.flatMap((v, i) => leafPaths(v, [...prefix, i]));
  }
  if (node && typeof node === 'object') {
    const keys = Object.keys(node).filter((k) => !(prefix.length === 0 && SKIP_TOP.has(k)));
    if (keys.length === 0) return [prefix];
    return keys.flatMap((k) => leafPaths(node[k], [...prefix, k]));
  }
  return [prefix];
}

function setPath(obj, p, value) {
  let node = obj;
  for (let i = 0; i < p.length - 1; i += 1) node = node[p[i]];
  node[p[p.length - 1]] = value;
}

// A guaranteed-different value for any leaf type, so the mutation always changes the
// canonical document.
function tamperValue(v) {
  if (typeof v === 'string') return `${v}__TAMPER`;
  if (typeof v === 'number') return v + 1;
  if (typeof v === 'boolean') return !v;
  if (Array.isArray(v)) return ['__TAMPER__'];
  if (v && typeof v === 'object') return { __TAMPER__: 1 };
  return '__TAMPER__'; // null
}

test('apply refuses with no --captain-approved and never writes', async () => {
  const { proposalFile } = makeProposal();
  const registry = tmpRegistry();
  await assert.rejects(
    () => applyMigration(registry, { proposalFile }),
    /requires --captain-approved/
  );
  assert.equal(registryBytes(registry).length, 0);
});

test('apply refuses a wrong digest and never writes', async () => {
  const { proposalFile } = makeProposal();
  const registry = tmpRegistry();
  await assert.rejects(
    () => applyMigration(registry, { proposalFile, approvedDigest: 'deadbeef' }),
    /does not match this proposal/
  );
  assert.equal(registryBytes(registry).length, 0);
});

test('apply refuses a proposal file with the wrong schema', async () => {
  const bad = path.join(mkdir('mem-bad-'), 'p.json');
  fs.writeFileSync(bad, JSON.stringify({ schema: 'nope', proposals: [] }));
  await assert.rejects(
    () => applyMigration(tmpRegistry(), { proposalFile: bad, approvedDigest: 'x' }),
    /wrong or missing schema/
  );
});

test('apply refuses an unreadable / missing proposal file', async () => {
  await assert.rejects(
    () => applyMigration(tmpRegistry(), { proposalFile: '/no/such/proposal.json', approvedDigest: 'x' }),
    /unreadable/
  );
});

test('apply refuses a tampered file whose stored digest disagrees with its content', async () => {
  const { proposalFile, proposal, digest } = makeProposal();
  // Mutate a record's content but leave the stored digest as-is.
  proposal.proposals[0].summary = 'TAMPERED SUMMARY';
  fs.writeFileSync(proposalFile, JSON.stringify(proposal, null, 2));
  const registry = tmpRegistry();
  await assert.rejects(
    () => applyMigration(registry, { proposalFile, approvedDigest: digest }),
    /stored digest does not match its content/
  );
  assert.equal(registryBytes(registry).length, 0);
});

test('apply refuses activating a proposal id that is not in the file', async () => {
  const { proposalFile, digest } = makeProposal();
  const registry = tmpRegistry();
  await assert.rejects(
    () => applyMigration(registry, { proposalFile, approvedDigest: digest, activate: ['MIG-000000000000'] }),
    /names a proposal not in this file/
  );
  assert.equal(registryBytes(registry).length, 0);
});

test('apply refuses activating a non-activatable (superseded) disposition', async () => {
  const { proposalFile, proposal, digest } = makeProposal();
  const supersededId = proposal.proposals.find((p) => p.disposition === 'superseded').proposalId;
  const registry = tmpRegistry();
  await assert.rejects(
    () => applyMigration(registry, { proposalFile, approvedDigest: digest, activate: [supersededId] }),
    /non-activatable disposition 'superseded'/
  );
  assert.equal(registryBytes(registry).length, 0);
});

test('apply refuses an activation set larger than the cap', async () => {
  const { proposalFile, digest, candidateIds } = makeProposal();
  const registry = tmpRegistry();
  await assert.rejects(
    () => applyMigration(registry, { proposalFile, approvedDigest: digest, activate: candidateIds, maxActivation: 1 }),
    /exceeds the cap of 1/
  );
  assert.equal(registryBytes(registry).length, 0);
});

test('a correct apply proposes every record as candidate and activates only the named subset', async () => {
  const { proposalFile, proposal, digest, candidateIds } = makeProposal();
  const registry = tmpRegistry();
  const target = candidateIds[0];
  const receipt = await applyMigration(registry, { proposalFile, approvedDigest: digest, activate: [target] });
  assert.equal(receipt.ok, true);
  assert.equal(receipt.proposedCount, proposal.proposals.length);
  assert.equal(receipt.activatedCount, 1);

  const fold = foldRegistry(registryPaths(registry));
  const records = [...fold.records.values()];
  assert.equal(records.length, proposal.proposals.length, 'every proposal became a record');
  const active = records.filter((r) => r.status === 'active');
  assert.equal(active.length, 1, 'only the named record is active');
  // Every proposed record is migration-sourced; non-activated ones stay candidate.
  for (const r of records) assert.equal(r.proposedBy.kind, 'migration');
  const candidates = records.filter((r) => r.status === 'candidate');
  assert.equal(candidates.length, proposal.proposals.length - 1);

  // Activation authorization is bound to the approved digest (captain consent).
  assert.equal(active[0].activatedBy.kind, 'captain');
  assert.equal(active[0].activatedBy.authorizationRef, digest);
  assert.equal(active[0].confidence, 'observed');
});

test('re-applying the same approved proposal is a no-op (idempotent)', async () => {
  const { proposalFile, digest, candidateIds } = makeProposal();
  const registry = tmpRegistry();
  await applyMigration(registry, { proposalFile, approvedDigest: digest, activate: [candidateIds[0]] });
  const afterFirst = registryBytes(registry);

  const second = await applyMigration(registry, { proposalFile, approvedDigest: digest, activate: [candidateIds[0]] });
  assert.ok(second.proposed.every((p) => p.skipped), 'every propose was skipped on re-run');
  assert.ok(second.activated.every((a) => a.skipped), 'every activate was skipped on re-run');
  assert.ok(registryBytes(registry).equals(afterFirst), 'registry bytes unchanged by the idempotent re-apply');
});

// ---- F1: the approval digest binds EVERY leaf of the canonicalized proposal ---

// Table-driven, one test per leaf: mutating any single leaf while keeping the stored
// digest and the original approval must be refused with a byte-identical (empty)
// registry. The leaf set is derived from the whole rich proposal document, so it
// covers every candidate leaf (type/content/provenance.{source,path,anchor,
// lineStart,lineEnd}/confidence/evidence/disposition/.../contentDigest), both nested
// `counts` maps, and every source-review leaf across all shapes (file, survey with
// `surveyedHeadings`, glob `files[]` and `refusedFiles[]`, and empty-array leaves).
// This is the exhaustive per-field mutation-regression proof.
const RICH_LEAVES = leafPaths(makeRichProposal().proposal);

for (const leaf of RICH_LEAVES) {
  const name = leaf.join('.');
  test(`F1 leaf tamper refused (empty registry): ${name}`, async () => {
    const { proposalFile, proposal, digest } = makeRichProposal();
    const clone = JSON.parse(JSON.stringify(proposal));
    const current = leaf.reduce((node, key) => node[key], clone);
    setPath(clone, leaf, tamperValue(current));
    fs.writeFileSync(proposalFile, JSON.stringify(clone, null, 2));
    const registry = tmpRegistry();
    await assert.rejects(
      () => applyMigration(registry, { proposalFile, approvedDigest: digest }),
      /stored digest does not match its content|wrong or missing schema|no proposals array/,
      `mutating ${name} must be refused`
    );
    assert.equal(registryBytes(registry).length, 0, `${name}: registry must be byte-identical (empty)`);
  });
}

// Sanity guard on the matrix itself: the enumerated leaf set must actually include
// the specific fields QA called out, so the coverage can never silently regress.
test('F1 coverage guard: the leaf matrix includes every named candidate and source leaf', () => {
  const flat = new Set(RICH_LEAVES.map((l) => l.join('.')));
  // A field is covered when its (possibly dotted) segment sequence appears anywhere in
  // some leaf path — including as `field.N` when the field is a non-empty array whose
  // elements are enumerated individually.
  const has = (field) => {
    const parts = field.split('.');
    return RICH_LEAVES.some((leaf) => {
      for (let i = 0; i + parts.length <= leaf.length; i += 1) {
        if (parts.every((seg, j) => String(leaf[i + j]) === seg)) return true;
      }
      return false;
    });
  };
  for (const field of [
    'memoryType', 'summary', 'body', 'scope', 'projects', 'taskKinds', 'keywords',
    'aliases', 'entities', 'commands', 'failureModes', 'relatedTerms', 'confidence',
    'provenance.source', 'provenance.path', 'provenance.anchor', 'provenance.lineStart',
    'provenance.lineEnd', 'validFrom', 'disposition', 'dispositionReason', 'supersededBy',
    'activationNominee', 'proposalId', 'contentDigest'
  ]) {
    assert.ok(has(field), `candidate leaf ${field} must be in the mutation matrix`);
  }
  // Source-review leaves and both counts maps.
  for (const field of ['key', 'policy', 'label', 'reason', 'path', 'exists', 'refused',
    'refusedReason', 'itemCount', 'surveyedHeadings', 'sha256', 'fileCount']) {
    assert.ok(has(field), `source leaf ${field} must be in the mutation matrix`);
  }
  assert.ok([...flat].some((p) => p.startsWith('counts.byDisposition.')), 'counts.byDisposition mutated');
  assert.ok([...flat].some((p) => p.startsWith('counts.byType.')), 'counts.byType mutated');
  assert.ok([...flat].some((p) => /sources\.\d+\.files\.\d+\.(path|sections|sha256)/.test(p)), 'nested files leaves mutated');
  assert.ok([...flat].some((p) => /sources\.\d+\.refusedFiles\.\d+\.(path|reason)/.test(p)), 'nested refusedFiles leaves mutated');
});

test('F1: an internally-inconsistent candidate contentDigest is refused even when re-digested and re-approved', async () => {
  const { proposalFile, proposal } = makeProposal();
  const clone = JSON.parse(JSON.stringify(proposal));
  // Tamper the contentDigest, then RE-COMPUTE the top-level digest so the stored/approved
  // digest are internally consistent — the whole-doc gate would pass. The dedicated
  // contentDigest-consistency gate must still catch it.
  clone.proposals[0].contentDigest = '0'.repeat(64);
  const rehashed = computeDigest(clone);
  clone.digest = rehashed;
  fs.writeFileSync(proposalFile, JSON.stringify(clone, null, 2));
  const registry = tmpRegistry();
  await assert.rejects(
    () => applyMigration(registry, { proposalFile, approvedDigest: rehashed }),
    /contentDigest is inconsistent with its content/
  );
  assert.equal(registryBytes(registry).length, 0);
});

test('apply with an empty activation set proposes all candidates and activates nothing', async () => {
  const { proposalFile, proposal, digest } = makeProposal();
  const registry = tmpRegistry();
  const receipt = await applyMigration(registry, { proposalFile, approvedDigest: digest });
  assert.equal(receipt.activatedCount, 0);
  const fold = foldRegistry(registryPaths(registry));
  assert.equal([...fold.records.values()].filter((r) => r.status === 'active').length, 0);
  assert.equal(fold.records.size, proposal.proposals.length);
});
