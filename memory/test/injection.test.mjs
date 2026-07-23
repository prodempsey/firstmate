import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { afterEach } from 'node:test';
import { buildRetrievalIndex } from '../lib/retrieval-index.mjs';
import { recall } from '../lib/recall.mjs';
import {
  BRIEF_INJECTION_PROOF_SCHEMA,
  MARKER_BEGIN,
  MARKER_END,
  extractTaskSection,
  findMarkerBlocks,
  hasUnresolvedPlaceholder,
  injectBrief,
  parseStamp,
  proofPathFor,
  verifyBrief,
  writeProof
} from '../lib/injection.mjs';
import { cleanTracked, seedActive, tmpRegistry } from './helpers.mjs';

afterEach(cleanTracked);

const CORPUS = [
  { id: 'MEM-0001', summary: 'stale watcher leaves idle done crew waiting', keywords: ['watcher', 'stale'], memoryType: 'procedural', scope: 'fleet', projects: ['*'], taskKinds: ['*'] },
  { id: 'MEM-0002', summary: 'worktree project mismatch on primary checkout', keywords: ['worktree', 'isolation'], memoryType: 'factual', scope: 'project', projects: ['firstmate'], taskKinds: ['ship'] }
];

const TASK_BRIEF = '# Task\nFix the stale watcher and worktree isolation problem.\n\n# Setup\ndetails here\n';

function tmpBrief(content = TASK_BRIEF) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-brief-'));
  const brief = path.join(dir, 'brief.md');
  fs.writeFileSync(brief, content);
  return { dir, brief };
}

async function builtCorpus(specs = CORPUS) {
  const dir = tmpRegistry();
  await seedActive(dir, specs);
  await buildRetrievalIndex(dir);
  return dir;
}

async function packFor(registry, query = 'stale watcher worktree', opts = {}) {
  return recall({ registryDir: registry, query, project: 'firstmate', kind: 'ship', ...opts });
}

test('helpers: extractTaskSection / placeholder / marker scan', () => {
  assert.equal(extractTaskSection(TASK_BRIEF), 'Fix the stale watcher and worktree isolation problem.');
  assert.equal(extractTaskSection('no task heading here'), '');
  assert.equal(hasUnresolvedPlaceholder('# Task\n{TASK}\n'), true);
  assert.equal(hasUnresolvedPlaceholder(TASK_BRIEF), false);
  assert.equal(findMarkerBlocks(`x ${MARKER_BEGIN} y ${MARKER_END} z`).length, 1);
});

test('injection writes a pointer-only block, a proof, and verifies clean', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry);
  assert.ok(pack.pointers.length >= 1);
  const { brief } = tmpBrief();
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(res.injected, true);
  writeProof(proofPathFor(brief), res.proof);

  const text = fs.readFileSync(brief, 'utf8');
  const blocks = findMarkerBlocks(text);
  assert.equal(blocks.length, 1);
  const block = text.slice(blocks[0].begin, blocks[0].end);
  // Pointer-only: ids and show commands present, memory bodies absent.
  for (const p of pack.pointers) {
    assert.ok(block.includes(p.id));
    assert.ok(block.includes(`mem show ${p.id}`));
  }
  const stamp = parseStamp(block);
  assert.equal(stamp.schema, BRIEF_INJECTION_PROOF_SCHEMA);
  assert.deepEqual(stamp.injectedIds, pack.pointers.map((p) => p.id));

  const proof = JSON.parse(fs.readFileSync(proofPathFor(brief), 'utf8'));
  assert.equal(proof.injected, true);
  assert.equal(proof.wholeFileSha256.length, 64);
  assert.equal(proof.retrievalGeneration, pack.retrievalGeneration);
  assert.deepEqual(proof.canonicalWatermark, pack.canonicalWatermark);

  const verdict = verifyBrief({ briefPath: brief });
  assert.equal(verdict.ok, true, JSON.stringify(verdict.failures));
});

test('verify detects a one-byte edit anywhere after injection (whole-file hash)', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry);
  const { brief } = tmpBrief();
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  writeProof(proofPathFor(brief), res.proof);
  // Edit OUTSIDE the memory block (in the task section).
  const text = fs.readFileSync(brief, 'utf8').replace('problem.', 'problem!!');
  fs.writeFileSync(brief, text);
  const verdict = verifyBrief({ briefPath: brief });
  assert.equal(verdict.ok, false);
  assert.ok(verdict.failures.includes('whole-file-sha256'));
});

test('verify detects a deleted selected id inside the block', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry);
  assert.ok(pack.pointers.length >= 2, 'need two pointers');
  const { brief } = tmpBrief();
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  writeProof(proofPathFor(brief), res.proof);
  const dropped = pack.pointers[1].id;
  const text = fs.readFileSync(brief, 'utf8').split('\n').filter((l) => !l.includes(`**${dropped}**`)).join('\n');
  fs.writeFileSync(brief, text);
  const verdict = verifyBrief({ briefPath: brief });
  assert.equal(verdict.ok, false);
  assert.ok(verdict.failures.some((f) => f === 'whole-file-sha256' || f.startsWith('id-present')));
});

test('verify detects a forged stamp (manifest id tampered)', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry);
  const { brief } = tmpBrief();
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  // Tamper the sidecar proof's whole-file hash so it no longer matches disk.
  const proof = res.proof;
  proof.wholeFileSha256 = 'deadbeef'.repeat(8);
  writeProof(proofPathFor(brief), proof);
  const verdict = verifyBrief({ briefPath: brief });
  assert.equal(verdict.ok, false);
  assert.ok(verdict.failures.includes('whole-file-sha256'));
});

test('recall-failure fails open: brief unchanged, proof records the failure', async () => {
  const registry = await builtCorpus();
  // Corrupt canonical -> recall-failed.
  const pack = await recall({ registryDir: path.join(registry, 'gone'), query: 'x', project: 'firstmate', kind: 'ship' });
  assert.equal(pack.state, 'recall-failed');
  const { brief } = tmpBrief();
  const before = fs.readFileSync(brief, 'utf8');
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(res.injected, false);
  assert.equal(res.reason, 'recall-failed');
  assert.equal(fs.readFileSync(brief, 'utf8'), before, 'brief unchanged on recall failure');
  writeProof(proofPathFor(brief), res.proof);
  // A declined-injection proof still verifies (proves no block + unchanged hash).
  const verdict = verifyBrief({ briefPath: brief });
  assert.equal(verdict.ok, true, JSON.stringify(verdict.failures));
});

test('empty registry is inert: brief unchanged, proof reason inert-empty-registry', async () => {
  const registry = tmpRegistry();
  const { appendRegistryEvent, buildActiveIndex } = await import('../lib/registry.mjs');
  await appendRegistryEvent(registry, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'firstmate', id: 'p' }, fields: { summary: 'candidate only' } });
  buildActiveIndex(registry);
  const pack = await packFor(registry, 'watcher');
  const { brief } = tmpBrief();
  const before = fs.readFileSync(brief, 'utf8');
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(res.injected, false);
  assert.equal(res.reason, 'inert-empty-registry');
  assert.equal(fs.readFileSync(brief, 'utf8'), before);
});

test('proven zero-hit is inert with a distinct reason', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry, 'zzzznotarealtoken');
  assert.equal(pack.state, 'proven');
  assert.equal(pack.pointers.length, 0);
  const { brief } = tmpBrief();
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(res.injected, false);
  assert.equal(res.reason, 'proven-zero-hit');
});

test('an unresolved {TASK} placeholder is never injected into', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry);
  const { brief } = tmpBrief('# Task\n{TASK}\n');
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(res.injected, false);
  assert.equal(res.reason, 'unresolved-task-placeholder');
});

test('injection is idempotent: a second injection is refused, not doubled', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry);
  const { brief } = tmpBrief();
  injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  const res2 = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(res2.injected, false);
  assert.equal(res2.reason, 'already-injected');
  assert.equal(findMarkerBlocks(fs.readFileSync(brief, 'utf8')).length, 1, 'still exactly one block');
});

test('a symlinked brief target is refused', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry);
  const { dir, brief } = tmpBrief();
  const link = path.join(dir, 'brief-link.md');
  fs.symlinkSync(brief, link);
  const res = injectBrief({ briefPath: link, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(res.injected, false);
  assert.equal(res.reason, 'brief-not-regular-file');
});

test('source pointers are escaped for Markdown control characters', async () => {
  const registry = tmpRegistry();
  await seedActive(registry, [
    { id: 'MEM-0001', summary: 'watcher note with a nasty source', keywords: ['watcher', 'stale'], memoryType: 'factual', scope: 'fleet', projects: ['*'], taskKinds: ['*'], source: { path: 'a`b|c', anchor: 'L1' } }
  ]);
  await buildRetrievalIndex(registry);
  const pack = await packFor(registry, 'watcher note');
  assert.ok(pack.pointers.length >= 1);
  const { brief } = tmpBrief();
  const res = injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(res.injected, true);
  const block = res.block;
  // The raw backtick must not survive inside the backtick span (would break it).
  assert.equal(block.includes('a`b'), false);
  assert.ok(block.includes('a\'b'));
});

test('the mode is preserved by the atomic replace', async () => {
  const registry = await builtCorpus();
  const pack = await packFor(registry);
  const { brief } = tmpBrief();
  fs.chmodSync(brief, 0o640);
  injectBrief({ briefPath: brief, recallPack: pack, taskId: 't1', project: 'firstmate', kind: 'ship' });
  assert.equal(fs.statSync(brief).mode & 0o777, 0o640);
});
