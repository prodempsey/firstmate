import assert from 'node:assert/strict';
import fs from 'node:fs';
import test, { afterEach } from 'node:test';
import { registryPaths } from '../lib/paths.mjs';
import { cleanTracked, runMemIn, tmpRegistry } from './helpers.mjs';

// The retrieval CLI smokes build derived PGlite generations; reclaim them per test.
afterEach(cleanTracked);

test('CLI fixture smoke exercises PR-1 verbs on an isolated registry with valid transitions only', () => {
  const dir = tmpRegistry();
  let result = runMemIn(dir, ['propose', '--summary', 'Isolated smoke memory', '--body', 'Created only in a disposable registry.', '--keyword', 'smoke', '--project', '*', '--kind', 'dispatch', '--risk-class', 'critical', '--json']);
  assert.equal(result.status, 0, result.stderr);
  const memId = JSON.parse(result.stdout).memId;
  // High-impact (dispatch/critical) memory needs captain authority to activate.
  // Captain authorization requires an explicit --validation reference; --evidence
  // alone never authorizes (see the validation/evidence separation contract).
  result = runMemIn(dir, ['activate', memId, '--actor-kind', 'captain', '--actor', 'captain', '--evidence', 'test:cli-smoke', '--method', 'test', '--validation', 'auth-cli-smoke', '--json']);
  assert.equal(result.status, 0, result.stderr);
  result = runMemIn(dir, ['show', memId, '--chain', '--json']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).record.status, 'active');

  result = runMemIn(dir, ['snapshot', '--json']);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(fs.existsSync(JSON.parse(result.stdout).file));
  result = runMemIn(dir, ['audit', '--json']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).activeIndex.status, 'current');

  // Valid supersession: propose + activate a successor, then supersede the original.
  const second = runMemIn(dir, ['propose', '--summary', 'Replacement smoke memory', '--json']);
  const successor = JSON.parse(second.stdout).memId;
  result = runMemIn(dir, ['activate', successor, '--actor-kind', 'captain', '--actor', 'captain', '--evidence', 'test:cli-smoke', '--method', 'test', '--validation', 'auth-cli-smoke-successor', '--json']);
  assert.equal(result.status, 0, result.stderr);
  result = runMemIn(dir, ['supersede', memId, '--successor', successor, '--reason', 'fixture supersession', '--json']);
  assert.equal(result.status, 0, result.stderr);

  const chain = JSON.parse(runMemIn(dir, ['show', memId, '--json']).stdout).record;
  assert.equal(chain.status, 'superseded');
  assert.equal(chain.supersededBy, successor);
  assert.ok(fs.readFileSync(registryPaths(dir).registry, 'utf8').includes('Replacement smoke memory'));
});

// Finding 1 (Captain contract decision): `--validation <ref>` is the ONLY CLI
// source of the scalar `validation.ref`; `--evidence` is an ordered list that
// never populates authorization. Evidence-only activation must not satisfy a
// captain/independent-authorization requirement. Do NOT reintroduce a single-
// evidence fallback as "backward compatibility".
test('finding-1: validation/evidence separation and scalar authorization contract', () => {
  const dir = tmpRegistry();
  const reg = registryPaths(dir).registry;
  const proposeStd = (s) => JSON.parse(runMemIn(dir, ['propose', '--summary', s, '--json']).stdout).memId;
  const proposeHigh = (s) => JSON.parse(runMemIn(dir, ['propose', '--summary', s, '--kind', 'dispatch', '--risk-class', 'critical', '--json']).stdout).memId;
  const recordOf = (id) => JSON.parse(runMemIn(dir, ['show', id, '--json']).stdout).record;
  const bytes = () => fs.readFileSync(reg);

  // (1) high-impact, no --validation, no --evidence -> rejected before append; bytes unchanged.
  const g1 = proposeHigh('high no-validation no-evidence');
  let before = bytes();
  let r = runMemIn(dir, ['activate', g1, '--actor-kind', 'captain', '--actor', 'captain', '--method', 'test', '--json']);
  assert.equal(r.status, 1);
  assert.equal(bytes().equals(before), true, 'rejected activation (no evidence/validation) must not append');

  // (2) one --evidence, no --validation -> low-impact activate records evidence but does NOT authorize.
  const s2 = proposeStd('one evidence memory');
  r = runMemIn(dir, ['activate', s2, '--actor-kind', 'firstmate', '--actor', 'mem-cli', '--evidence', 'test:one', '--method', 'test', '--json']);
  assert.equal(r.status, 0, r.stderr || r.stdout);
  let rec = recordOf(s2);
  assert.deepEqual(rec.evidence.map((e) => e.ref), ['one']);
  assert.equal(rec.activatedBy.authorizationRef, null, 'single evidence must not become the authorization ref');

  // (3) multiple --evidence, no --validation -> governed activation rejects; evidence never enters validation.ref; bytes unchanged.
  const g3 = proposeHigh('high multi-evidence no-validation');
  before = bytes();
  r = runMemIn(dir, ['activate', g3, '--actor-kind', 'captain', '--actor', 'captain', '--evidence', 'test:one', '--evidence', 'test:two', '--method', 'test', '--json']);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /authorization reference/);
  assert.equal(bytes().equals(before), true, 'rejected high-impact activation must not append');

  // (4) explicit --validation authorizes the previously-rejected high-impact activation.
  r = runMemIn(dir, ['activate', g3, '--actor-kind', 'captain', '--actor', 'captain', '--evidence', 'test:one', '--method', 'test', '--validation', 'auth-g3', '--json']);
  assert.equal(r.status, 0, r.stderr || r.stdout);
  assert.equal(recordOf(g3).activatedBy.authorizationRef, 'auth-g3');

  // (5)+(6) explicit --validation plus repeated --evidence: validation scalar, evidence list, stored independently.
  const g5 = proposeHigh('validation plus repeated evidence');
  r = runMemIn(dir, ['activate', g5, '--actor-kind', 'captain', '--actor', 'captain', '--evidence', 'test:e1', '--evidence', 'test:e2', '--method', 'test', '--validation', 'auth-g5', '--json']);
  assert.equal(r.status, 0, r.stderr || r.stdout);
  rec = recordOf(g5);
  assert.equal(rec.activatedBy.authorizationRef, 'auth-g5');
  assert.deepEqual(rec.evidence.map((e) => e.ref), ['e1', 'e2']);

  // (9) invalid scalar shape: repeated --validation rejected before append; bytes unchanged.
  const s9 = proposeStd('scalar validation enforcement');
  before = bytes();
  r = runMemIn(dir, ['activate', s9, '--evidence', 'test:one', '--method', 'test', '--validation', 'first', '--validation', 'second', '--json']);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /--validation accepts exactly one reference/);
  assert.equal(bytes().equals(before), true);

  // (7) revalidate path uses the identical rule (quarantine then revalidate).
  runMemIn(dir, ['quarantine', g5, '--reason', 'test quarantine', '--json']);
  before = bytes();
  r = runMemIn(dir, ['revalidate', g5, '--evidence', 'test:one', '--method', 'test', '--validation', 'x', '--validation', 'y', '--json']);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /--validation accepts exactly one reference/);
  assert.equal(bytes().equals(before), true, 'rejected revalidation must not append');
  r = runMemIn(dir, ['revalidate', g5, '--evidence', 'test:one', '--method', 'test', '--validation', 'auth-reval', '--json']);
  assert.equal(r.status, 0, r.stderr || r.stdout);
  assert.equal(recordOf(g5).activatedBy.authorizationRef, 'auth-reval');
});

test('summary-only CLI update preserves omitted fields', () => {
  const dir = tmpRegistry();
  const memId = JSON.parse(runMemIn(dir, ['propose', '--summary', 'orig', '--body', 'keep me', '--scope', 'project', '--project', 'firstmate', '--kind', 'dispatch', '--keyword', 'k1', '--confidence', 'observed', '--risk-class', 'critical', '--json']).stdout).memId;
  const update = runMemIn(dir, ['update', memId, '--summary', 'changed', '--json']);
  assert.equal(update.status, 0, update.stderr);
  const record = JSON.parse(runMemIn(dir, ['show', memId, '--json']).stdout).record;
  assert.equal(record.summary, 'changed');
  assert.equal(record.body, 'keep me');
  assert.equal(record.scope, 'project');
  assert.deepEqual(record.projects, ['firstmate']);
  assert.deepEqual(record.keywords, ['k1']);
  assert.equal(record.confidence, 'observed');
  assert.equal(record.riskClass, 'critical');
});

// PR-2 retrieval CLI contracts. build/doctor/clean/retrieve return stable JSON on
// success and the `{ ok: false, error }` envelope on failure, exit non-zero on
// error, and never touch canonical state.
function seedActiveViaCli(dir, id, summary, extra = []) {
  const propose = runMemIn(dir, ['propose', '--summary', summary, ...extra, '--json']);
  assert.equal(propose.status, 0, propose.stderr);
  const memId = JSON.parse(propose.stdout).memId;
  const activate = runMemIn(dir, ['activate', memId, '--evidence', 'test:cli', '--validation', `auth-${memId}`, '--json']);
  assert.equal(activate.status, 0, activate.stderr);
  return memId;
}

test('retrieval build/doctor/retrieve/clean expose stable JSON success contracts', () => {
  const dir = tmpRegistry();
  seedActiveViaCli(dir, 'MEM-0001', 'stale watcher leaves idle done crew', ['--keyword', 'watcher', '--project', 'firstmate', '--kind', 'ship']);

  const build = runMemIn(dir, ['retrieval', 'build', '--full', '--json']);
  assert.equal(build.status, 0, build.stderr);
  const buildOut = JSON.parse(build.stdout);
  assert.equal(buildOut.ok, true);
  assert.equal(buildOut.mode, 'pglite-fts');
  assert.match(buildOut.generationId, /^fts-/);

  const rdoctor = runMemIn(dir, ['retrieval', 'doctor', '--json']);
  assert.equal(rdoctor.status, 0, rdoctor.stderr);
  const rd = JSON.parse(rdoctor.stdout);
  assert.equal(rd.canonical.ok, true);
  assert.equal(rd.derived.status, 'current');
  assert.equal(rd.retrievalReadiness, 'pglite-fts');

  const retrieve = runMemIn(dir, ['retrieve', '--query', 'stale watcher', '--project', 'firstmate', '--kind', 'ship', '--json']);
  assert.equal(retrieve.status, 0, retrieve.stderr);
  const ret = JSON.parse(retrieve.stdout);
  assert.equal(ret.ok, true);
  assert.equal(ret.retrievalMode, 'pglite-fts');
  assert.deepEqual(ret.selected.map((s) => s.id), ['MEM-0001']);
  assert.equal(ret.telemetry.schema, 'kraken-memory/retrieval-telemetry/v1');

  const clean = runMemIn(dir, ['retrieval', 'clean', '--json']);
  assert.equal(clean.status, 0, clean.stderr);
  assert.equal(JSON.parse(clean.stdout).kept, buildOut.generationId);
});

test('retrieval CLI failure contracts: missing --full and missing query are JSON errors, exit non-zero', () => {
  const dir = tmpRegistry();
  const noFull = runMemIn(dir, ['retrieval', 'build', '--json']);
  assert.equal(noFull.status, 1);
  assert.equal(JSON.parse(noFull.stdout).ok, false);
  assert.match(JSON.parse(noFull.stdout).error, /--full/);

  const noQuery = runMemIn(dir, ['retrieve', '--project', 'firstmate', '--kind', 'ship', '--json']);
  assert.equal(noQuery.status, 1);
  assert.equal(JSON.parse(noQuery.stdout).ok, false);
  assert.match(JSON.parse(noQuery.stdout).error, /--query|--stdin/);
});

test('retrieve enforces the documented argument contract (F5)', () => {
  const dir = tmpRegistry();
  seedActiveViaCli(dir, 'MEM-0001', 'watcher note', ['--keyword', 'watcher', '--project', 'firstmate', '--kind', 'ship']);
  runMemIn(dir, ['retrieval', 'build', '--full', '--json']);
  const errOf = (args) => {
    const r = runMemIn(dir, ['retrieve', ...args, '--json']);
    assert.equal(r.status, 1, `expected exit 1 for ${args.join(' ')}`);
    return JSON.parse(r.stdout).error;
  };
  // Two query sources is rejected, not silently prioritized.
  assert.match(errOf(['--query', 'a', '--stdin', '--project', 'firstmate', '--kind', 'ship']), /exactly one query source/);
  // Required filters.
  assert.match(errOf(['--query', 'watcher', '--kind', 'ship']), /--project/);
  assert.match(errOf(['--query', 'watcher', '--project', 'firstmate']), /--kind/);
  // Numeric validation.
  assert.match(errOf(['--query', 'watcher', '--project', 'firstmate', '--kind', 'ship', '--top', '0']), /positive integer/);
  assert.match(errOf(['--query', 'watcher', '--project', 'firstmate', '--kind', 'ship', '--top', 'abc']), /positive integer/);
  // Strict ISO-8601 --as-of: a bare year, a US-style date, a calendar-rollover date,
  // and a date without a time are all rejected; a full timestamp is accepted.
  const asOf = (v) => ['--query', 'watcher', '--project', 'firstmate', '--kind', 'ship', '--as-of', v];
  assert.match(errOf(asOf('not-a-date')), /ISO-8601/);
  assert.match(errOf(asOf('2026')), /ISO-8601/);
  assert.match(errOf(asOf('12/25/2026')), /ISO-8601/);
  assert.match(errOf(asOf('2026-02-30T00:00:00Z')), /ISO-8601/); // calendar rollover rejected
  assert.match(errOf(asOf('2026-07-23')), /ISO-8601/); // missing time
  const okAsOf = runMemIn(dir, ['retrieve', ...asOf('2026-07-23T00:00:00Z'), '--json']);
  assert.equal(okAsOf.status, 0, okAsOf.stderr);
  assert.equal(JSON.parse(okAsOf.stdout).telemetry.filters.asOf, '2026-07-23T00:00:00.000Z'); // normalized to UTC
});

test('retrieve returns failed (exit 1) when canonical is unverified, without falling back', () => {
  const dir = tmpRegistry();
  seedActiveViaCli(dir, 'MEM-0001', 'watcher note', ['--keyword', 'watcher', '--project', 'firstmate', '--kind', 'ship']);
  runMemIn(dir, ['retrieval', 'build', '--full', '--json']);
  fs.writeFileSync(registryPaths(dir).registry, '{bad');
  const r = runMemIn(dir, ['retrieve', '--query', 'watcher', '--project', 'firstmate', '--kind', 'ship', '--json']);
  assert.equal(r.status, 1);
  const parsed = JSON.parse(r.stdout);
  assert.equal(parsed.ok, false);
  assert.equal(parsed.retrievalMode, 'failed');
});

test('canonical non-mutating fixture creates an empty index without production records', () => {
  const dir = tmpRegistry();
  const project = runMemIn(dir, ['project', '--json']);
  assert.equal(project.status, 0, project.stderr);
  const audit = runMemIn(dir, ['audit', '--json']);
  assert.equal(audit.status, 0, audit.stderr);
  const parsed = JSON.parse(audit.stdout);
  assert.equal(parsed.records.total, 0);
  assert.equal(parsed.records.active, 0);
  assert.equal(parsed.activeIndex.status, 'current');
  assert.equal(fs.existsSync(registryPaths(dir).registry), false);
});
