import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { afterEach } from 'node:test';
import { registryPaths } from '../lib/paths.mjs';
import { foldRegistry } from '../lib/registry.mjs';
import { applyMigration, runDryRun } from '../lib/migrate.mjs';
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

test('apply with an empty activation set proposes all candidates and activates nothing', async () => {
  const { proposalFile, proposal, digest } = makeProposal();
  const registry = tmpRegistry();
  const receipt = await applyMigration(registry, { proposalFile, approvedDigest: digest });
  assert.equal(receipt.activatedCount, 0);
  const fold = foldRegistry(registryPaths(registry));
  assert.equal([...fold.records.values()].filter((r) => r.status === 'active').length, 0);
  assert.equal(fold.records.size, proposal.proposals.length);
});
