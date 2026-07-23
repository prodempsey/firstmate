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

// ---- F1: the approval digest binds the WHOLE canonicalized proposal ----------

// Every candidate/source field one at a time: mutating it while keeping the stored
// digest and the original approval must be refused with a byte-identical (empty)
// registry. This proves the digest covers the complete document, not a projection.
const FIELD_MUTATIONS = [
  ['summary', (p) => { p.proposals[0].summary += ' TAMPER'; }],
  ['body', (p) => { p.proposals[0].body += ' TAMPER'; }],
  ['memoryType', (p) => { p.proposals[0].memoryType = p.proposals[0].memoryType === 'factual' ? 'procedural' : 'factual'; }],
  ['scope', (p) => { p.proposals[0].scope = 'project'; }],
  ['projects', (p) => { p.proposals[0].projects = ['evil']; }],
  ['taskKinds', (p) => { p.proposals[0].taskKinds = ['evil']; }],
  ['keywords', (p) => { p.proposals[0].keywords = ['evil']; }],
  ['aliases', (p) => { p.proposals[0].aliases = ['evil']; }],
  ['entities', (p) => { p.proposals[0].entities = ['evil']; }],
  ['commands', (p) => { p.proposals[0].commands = ['evil']; }],
  ['failureModes', (p) => { p.proposals[0].failureModes = ['evil']; }],
  ['relatedTerms', (p) => { p.proposals[0].relatedTerms = ['evil']; }],
  ['confidence', (p) => { p.proposals[0].confidence = 'guarded'; }],
  ['validFrom', (p) => { p.proposals[0].validFrom = '2000-01-01T00:00:00.000Z'; }],
  ['disposition', (p) => { p.proposals[0].disposition = 'active'; }],
  ['dispositionReason', (p) => { p.proposals[0].dispositionReason = 'forged reason'; }],
  ['supersededBy', (p) => { p.proposals[0].supersededBy = 'MEM-9999'; }],
  ['activationNominee', (p) => { p.proposals[0].activationNominee = true; }],
  ['contentDigest', (p) => { p.proposals[0].contentDigest = '0'.repeat(64); }],
  ['proposalId', (p) => { p.proposals[0].proposalId = 'MIG-000000000000'; }],
  ['provenance.path', (p) => { p.proposals[0].provenance.path = 'data/evil.md'; }],
  ['provenance.anchor', (p) => { p.proposals[0].provenance.anchor = 'evil-anchor'; }],
  ['provenance.lineStart', (p) => { p.proposals[0].provenance.lineStart = 999; }],
  ['evidence', (p) => { p.proposals[0].evidence = [{ type: 'x', ref: 'y' }]; }],
  ['counts', (p) => { p.counts.total = 999; }],
  ['source.sha256', (p) => { p.sources.find((s) => s.key === 'learnings').sha256 = 'f'.repeat(64); }],
  ['source.reason', (p) => { p.sources[0].reason = 'forged'; }]
];

for (const [name, mutate] of FIELD_MUTATIONS) {
  test(`F1: mutating candidate/source field '${name}' invalidates the prior approval (no write)`, async () => {
    const { proposalFile, proposal, digest } = makeProposal();
    const clone = JSON.parse(JSON.stringify(proposal));
    mutate(clone);
    fs.writeFileSync(proposalFile, JSON.stringify(clone, null, 2));
    const registry = tmpRegistry();
    await assert.rejects(
      () => applyMigration(registry, { proposalFile, approvedDigest: digest }),
      /stored digest does not match its content|does not match this proposal/,
      `mutation of ${name} must be refused`
    );
    assert.equal(registryBytes(registry).length, 0, `${name}: registry must be byte-identical (empty)`);
  });
}

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
