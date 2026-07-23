import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { afterEach } from 'node:test';
import { CORPUS_SOURCES, enumerateCorpus, isSecretClassName } from '../lib/migrate-sources.mjs';

// Corpus fixtures live in disposable temp dirs; never a real fleet home.
const corpora = new Set();
function mkCorpus(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-corpus-'));
  corpora.add(root);
  for (const [rel, content] of Object.entries(files)) {
    const abs = path.join(root, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, content);
  }
  return root;
}
afterEach(() => {
  for (const dir of corpora) fs.rmSync(dir, { recursive: true, force: true });
  corpora.clear();
});

const LEARNINGS = `# Fleet-local learnings

Intro paragraph before any dated entry — not a record.

## 2026-07-14 — Captain order inbox must store FULL verbatim prompts

**Evidence:** bug \`bug-20260714222918-9e8a1c39\`; order ORD-084; prior \`MEM-0007\`.

**Rule (non-negotiable):**
1. \`bin/fm-order.sh add\` the entire request. Do not summarize.

## 2026-07-12 — Cockpit crashes come from broad pattern kills

Never let a crew run \`pkill\` by name against \`node server.js\`.

## 2026-07-11 — Old guidance [SUPERSEDED, DO NOT FOLLOW]

Replaced by a newer lesson. Uses \`tmux kill-window\`.
`;

test('learnings.md extracts one candidate per dated section; preamble is skipped', () => {
  const root = mkCorpus({ 'data/learnings.md': LEARNINGS });
  const { proposals } = enumerateCorpus(root);
  assert.equal(proposals.length, 3);
  const byAnchor = Object.fromEntries(proposals.map((p) => [p.provenance.anchor, p]));

  const inbox = byAnchor['2026-07-14-captain-order-inbox-must-store-full-verbatim-prompts'];
  assert.ok(inbox, 'first dated section became a proposal');
  assert.equal(inbox.summary, 'Captain order inbox must store FULL verbatim prompts');
  assert.equal(inbox.memoryType, 'procedural', '**Rule** header => procedural');
  assert.equal(inbox.confidence, 'unverified', 'migration never manufactures confidence');
  assert.equal(inbox.scope, 'fleet');
  assert.equal(inbox.validFrom, '2026-07-14T00:00:00.000Z');
  assert.equal(inbox.disposition, 'candidate');
  assert.equal(inbox.provenance.source, 'learnings');
  assert.equal(inbox.provenance.path, 'data/learnings.md', 'provenance path is corpus-relative');
});

test('procedural vs factual classification, command and evidence extraction', () => {
  const root = mkCorpus({ 'data/learnings.md': LEARNINGS });
  const { proposals } = enumerateCorpus(root);
  const byAnchor = Object.fromEntries(proposals.map((p) => [p.provenance.anchor, p]));

  const inbox = byAnchor['2026-07-14-captain-order-inbox-must-store-full-verbatim-prompts'];
  assert.deepEqual(inbox.evidence, [
    { type: 'bug', ref: 'bug-20260714222918-9e8a1c39' },
    { type: 'order', ref: 'ORD-084' },
    { type: 'memory', ref: 'MEM-0007' }
  ]);
  assert.ok(inbox.commands.includes('fm-order.sh'), 'bin/fm-order.sh normalized to fm-order.sh');

  const crashes = byAnchor['2026-07-12-cockpit-crashes-come-from-broad-pattern-kills'];
  assert.equal(crashes.memoryType, 'procedural', 'command + "against" imperative => procedural');
  assert.ok(crashes.commands.includes('pkill'));
});

test('explicit [SUPERSEDED]/DO NOT FOLLOW marker maps to a superseded disposition without guessing a successor', () => {
  const root = mkCorpus({ 'data/learnings.md': LEARNINGS });
  const { proposals } = enumerateCorpus(root);
  const superseded = proposals.find((p) => p.provenance.anchor.includes('old-guidance'));
  assert.ok(superseded);
  assert.equal(superseded.disposition, 'superseded');
  assert.equal(superseded.supersededBy, null, 'successor link is the captain\'s to make');
  assert.match(superseded.dispositionReason, /SUPERSEDED|DO NOT FOLLOW/);
});

test('duplicate date+title headings get disambiguated, collision-free anchors', () => {
  const dup = `# L

## 2026-07-10 — Same title

body one

## 2026-07-10 — Same title

body two
`;
  const root = mkCorpus({ 'data/learnings.md': dup });
  const { proposals } = enumerateCorpus(root);
  const anchors = proposals.map((p) => p.provenance.anchor);
  assert.equal(new Set(anchors).size, anchors.length, 'anchors are unique');
  assert.equal(anchors.length, 2);
  assert.ok(anchors.some((a) => a.endsWith('-2')), 'second occurrence is suffixed');
});

test('survey sources are enumerated (counted, headings captured) but produce no proposals', () => {
  const root = mkCorpus({
    'data/learnings.md': '# L\n\n## 2026-07-01 — Only entry\n\nbody\n',
    'data/captain.md': '# Captain\n\n## Working style\n\nterse\n\n## Escalation\n\nfull urls\n',
    'projects/demo/AGENTS.md': '# Demo\n\n## Build\n\nmake\n',
    'data/scout-x1/report.md': '# Report\n\n## Findings\n\nstuff\n'
  });
  const { sources, proposals } = enumerateCorpus(root);
  // Only learnings extracts.
  assert.equal(proposals.length, 1);
  assert.equal(proposals[0].provenance.source, 'learnings');

  const captain = sources.find((s) => s.key === 'captain');
  assert.equal(captain.policy, 'survey');
  assert.equal(captain.itemCount, 2);
  assert.deepEqual(captain.surveyedHeadings, ['Working style', 'Escalation']);

  const agents = sources.find((s) => s.key === 'project-agents');
  assert.equal(agents.policy, 'survey');
  assert.equal(agents.fileCount, 1);
  assert.equal(agents.files[0].path, 'projects/demo/AGENTS.md');

  const reports = sources.find((s) => s.key === 'reports');
  assert.equal(reports.fileCount, 1);
  assert.equal(reports.files[0].path, 'data/scout-x1/report.md');
});

test('a missing corpus yields present-marked-false sources and zero proposals (no throw)', () => {
  const root = mkCorpus({ 'placeholder.txt': 'x' });
  const { sources, proposals } = enumerateCorpus(root);
  assert.equal(proposals.length, 0);
  assert.equal(sources.length, CORPUS_SOURCES.length);
  for (const s of sources) {
    assert.equal(s.exists, false);
    assert.equal(s.itemCount, 0);
  }
});

// ---- F2: secret-safe source enumeration -------------------------------------

test('isSecretClassName flags .env-class, key/credential/token files and passes ordinary corpus names', () => {
  for (const bad of ['.env', '.env.production', '.env.local', 'prod.env', 'app.env',
    'id_rsa', 'id_ed25519', '.npmrc', '.netrc', '.pgpass', 'credentials',
    'server.key', 'cert.pem', 'store.p12', 'db-password.txt', 'api_token.json', 'my-secret.yml']) {
    assert.equal(isSecretClassName(bad), true, `${bad} must be secret-class`);
  }
  for (const ok of ['learnings.md', 'captain.md', 'report.md', 'AGENTS.md', 'notes.txt', 'readme.md']) {
    assert.equal(isSecretClassName(ok), false, `${ok} must not be secret-class`);
  }
});

test('F2: a learnings.md symlinked to an .env file OUTSIDE the corpus is refused and never read', () => {
  const outer = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-outer-'));
  corpora.add(outer);
  fs.writeFileSync(path.join(outer, '.env.production'),
    '# env\n\n## 2026-07-23 — Credential\n\nDATABASE_URL=postgres://admin:ULTRA_SECRET@db/prod\n');
  const root = mkCorpus({ 'data/keep.txt': 'x' });
  fs.symlinkSync(path.join(outer, '.env.production'), path.join(root, 'data', 'learnings.md'));

  const { sources, proposals } = enumerateCorpus(root);
  assert.equal(proposals.length, 0, 'no candidate produced from a symlinked source');
  const learnings = sources.find((s) => s.key === 'learnings');
  assert.equal(learnings.refused, true);
  assert.match(learnings.refusedReason, /symlink/i);
  assert.equal(learnings.sha256, undefined, 'refused source was never hashed/read');
  // The secret must appear nowhere in the enumeration output.
  assert.ok(!JSON.stringify(sources).includes('ULTRA_SECRET'));
  assert.ok(!JSON.stringify(proposals).includes('ULTRA_SECRET'));
});

test('F2: a symlinked SURVEY file (report.md -> secret) is refused and recorded, not read', () => {
  const outer = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-outer-'));
  corpora.add(outer);
  fs.writeFileSync(path.join(outer, 'creds'), 'TOKEN=ULTRA_SECRET\n');
  const root = mkCorpus({ 'data/learnings.md': '# L\n\n## 2026-07-01 — Only\n\nbody\n', 'data/scout-x1/placeholder': 'x' });
  fs.symlinkSync(path.join(outer, 'creds'), path.join(root, 'data', 'scout-x1', 'report.md'));

  const { sources } = enumerateCorpus(root);
  const reports = sources.find((s) => s.key === 'reports');
  assert.equal(reports.refused, true);
  assert.equal(reports.fileCount, 0, 'the symlinked report was not accepted as a match');
  assert.ok(reports.refusedFiles.some((f) => /report\.md/.test(f.path)));
  assert.ok(!JSON.stringify(sources).includes('ULTRA_SECRET'));
});

test('F2: a symlink whose target ESCAPES the corpus root is refused (containment)', () => {
  const outer = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-outer-'));
  corpora.add(outer);
  fs.writeFileSync(path.join(outer, 'ordinary.md'), '# outside\n\n## 2026-07-01 — Escaped\n\nbody\n');
  const root = mkCorpus({ 'data/keep.txt': 'x' });
  // Even a non-secret target is refused: it is a symlink and it leaves the root.
  fs.symlinkSync(path.join(outer, 'ordinary.md'), path.join(root, 'data', 'learnings.md'));
  const { sources, proposals } = enumerateCorpus(root);
  assert.equal(proposals.length, 0);
  assert.equal(sources.find((s) => s.key === 'learnings').refused, true);
});

test('F2: a symlinked project directory is refused wholesale', () => {
  const outer = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-outer-'));
  corpora.add(outer);
  const root = mkCorpus({ 'data/learnings.md': '# L\n\n## 2026-07-01 — Only\n\nbody\n' });
  fs.symlinkSync(outer, path.join(root, 'projects'));
  const { sources } = enumerateCorpus(root);
  const agents = sources.find((s) => s.key === 'project-agents');
  assert.equal(agents.refused, true);
  assert.match(agents.refusedFiles[0].reason, /symlink/i);
});
