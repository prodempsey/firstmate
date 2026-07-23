import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { afterEach } from 'node:test';
import { registryPaths } from '../lib/paths.mjs';
import { buildProposal, computeDigest, runDryRun } from '../lib/migrate.mjs';
import { cleanTracked, seedActive, tmpRegistry } from './helpers.mjs';

const scratch = new Set();
function mkCorpus(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-corpus-'));
  scratch.add(root);
  for (const [rel, content] of Object.entries(files)) {
    const abs = path.join(root, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, content);
  }
  return root;
}
function mkOut() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-out-'));
  scratch.add(dir);
  return dir;
}
afterEach(() => {
  for (const dir of scratch) fs.rmSync(dir, { recursive: true, force: true });
  scratch.clear();
  cleanTracked();
});

const CORPUS = {
  'data/learnings.md': `# Fleet-local learnings

## 2026-07-14 — Store full verbatim prompts

**Rule:** \`bin/fm-order.sh add\` the whole thing. bug \`bug-20260714222918-9e8a1c39\`.

## 2026-07-12 — Retired guidance [SUPERSEDED, DO NOT FOLLOW]

old. \`tmux kill-window\`.
`,
  'data/captain.md': '# Captain\n\n## Style\n\nterse\n',
  'projects/demo/AGENTS.md': '# Demo\n\n## Build\n\nmake\n'
};

test('dry-run writes a proposal + report and returns the digest and counts', () => {
  const corpus = mkCorpus(CORPUS);
  const out = mkOut();
  const result = runDryRun(corpus, out);
  assert.equal(result.ok, true);
  assert.ok(fs.existsSync(result.proposalFile));
  assert.ok(fs.existsSync(result.reportFile));
  assert.equal(result.counts.total, 2);

  const proposal = JSON.parse(fs.readFileSync(result.proposalFile, 'utf8'));
  assert.equal(proposal.schema, 'kraken-memory/migration-proposal/v1');
  assert.equal(proposal.digest, result.digest);
  assert.equal(proposal.proposals.length, 2);
  // Every proposal has a stable id and a per-record content digest.
  for (const p of proposal.proposals) {
    assert.match(p.proposalId, /^MIG-[0-9a-f]{12}$/);
    assert.match(p.contentDigest, /^[0-9a-f]{64}$/);
  }
  // Proposals are sorted by proposalId for a stable file/digest.
  const ids = proposal.proposals.map((p) => p.proposalId);
  assert.deepEqual(ids, [...ids].sort());

  const report = fs.readFileSync(result.reportFile, 'utf8');
  assert.match(report, /This is a DRY RUN/);
  assert.match(report, new RegExp(result.digest));
  assert.match(report, /Activation is the captain/);
});

test('the digest is deterministic across runs and independent of generatedAt', () => {
  const corpus = mkCorpus(CORPUS);
  const a = buildProposal(corpus, { generatedAt: '2020-01-01T00:00:00.000Z' });
  const b = buildProposal(corpus, { generatedAt: '2099-12-31T23:59:59.000Z' });
  assert.equal(a.digest, b.digest, 'generatedAt does not affect the digest');
  assert.equal(a.digest, computeDigest(a));

  // A content change to the extract source moves the digest.
  const corpus2 = mkCorpus({ ...CORPUS, 'data/learnings.md': CORPUS['data/learnings.md'] + '\n## 2026-07-15 — New thing\n\nbody\n' });
  const c = buildProposal(corpus2, { generatedAt: '2020-01-01T00:00:00.000Z' });
  assert.notEqual(a.digest, c.digest, 'a new learning changes the digest');

  // A content change to a SURVEY source also moves the digest (survey file hashes
  // are part of the digest body), so approval is invalidated by any corpus change.
  const corpus3 = mkCorpus({ ...CORPUS, 'data/captain.md': '# Captain\n\n## Style\n\nVERBOSE now\n' });
  const d = buildProposal(corpus3, { generatedAt: '2020-01-01T00:00:00.000Z' });
  assert.notEqual(a.digest, d.digest, 'a survey-source edit changes the digest');
});

test('re-running the dry-run is idempotent: identical proposal content bar the timestamp', () => {
  const corpus = mkCorpus(CORPUS);
  const out = mkOut();
  const first = JSON.parse(fs.readFileSync(runDryRun(corpus, out).proposalFile, 'utf8'));
  const second = JSON.parse(fs.readFileSync(runDryRun(corpus, out).proposalFile, 'utf8'));
  assert.equal(first.digest, second.digest);
  delete first.generatedAt;
  delete second.generatedAt;
  assert.deepEqual(second, first, 'proposal content is identical across runs (only generatedAt varies)');
});

test('dry-run performs ZERO writes to the canonical registry', async () => {
  const registry = tmpRegistry();
  // Seed a real active record so the registry files exist and are non-trivial.
  await seedActive(registry, [{ id: 'MEM-0001', summary: 'seed', keywords: ['x'] }]);
  const rp = registryPaths(registry);
  const canonicalFiles = [rp.registry, rp.index].filter((f) => fs.existsSync(f));
  assert.ok(canonicalFiles.length >= 2, 'registry + index exist after seed');
  const before = canonicalFiles.map((f) => ({ f, buf: fs.readFileSync(f), mtime: fs.statSync(f).mtimeMs }));

  const corpus = mkCorpus(CORPUS);
  const out = mkOut();
  // Point the dry-run's DEFAULT out-dir at the registry dir by NOT passing out-dir…
  // but here we pass an explicit out so artifacts never land beside canonical files.
  runDryRun(corpus, out);

  for (const { f, buf, mtime } of before) {
    assert.ok(fs.readFileSync(f).equals(buf), `${path.basename(f)} bytes unchanged by dry-run`);
    assert.equal(fs.statSync(f).mtimeMs, mtime, `${path.basename(f)} mtime unchanged by dry-run`);
  }
});

test('dry-run works with no registry present at all (corpus-only operation)', () => {
  const corpus = mkCorpus(CORPUS);
  const out = mkOut();
  const registry = path.join(os.tmpdir(), 'mem-nonexistent-' + process.pid);
  scratch.add(registry);
  // runDryRun never reads or creates the registry; it only touches the corpus + out.
  const result = runDryRun(corpus, out);
  assert.equal(result.ok, true);
  assert.equal(fs.existsSync(registry), false, 'no registry dir was created');
});
