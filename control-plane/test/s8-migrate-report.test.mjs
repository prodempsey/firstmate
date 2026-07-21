import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { runVerb } from '../lib/coordinator.mjs';
import { runMigrateReport, buildReport, REPORT_SCHEMA } from '../lib/migrate-report.mjs';
import { readLegacyRecords, readOnlyFs, resolveLegacyHome, LEGACY_STORES } from '../lib/legacy-reader.mjs';
import { mapRecord, newMappingContext, FLAG_REASONS } from '../lib/migrate-map.mjs';
import { MigrateReportError, LegacyReadError } from '../lib/errors-s8.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// S8 migrate-report: a strictly READ-ONLY shadow read of the legacy stores that emits
// a deterministic mapped-or-flagged proposal and applies nothing (spec section 13).
// The suite proves mapped-or-flagged TOTALITY over well-formed/malformed/partial/
// duplicate fixtures, MUTATION-SENSITIVE read-only enforcement (a write attempt against
// a legacy path fails the run), determinism (byte-identical repeats), and atomic output.
after(cleanupAll);

// Build a fixture legacy home exercising every store and every disposition path.
function buildLegacyHome() {
  const home = mkTempDir('cp-s8-legacy-');
  const state = path.join(home, 'state');
  const data = path.join(home, 'data');
  fs.mkdirSync(state, { recursive: true });
  fs.mkdirSync(data, { recursive: true });

  // state/*.meta: well-formed ship (-> tasks + runs), secondmate (-> tasks only), bad kind (flag)
  fs.writeFileSync(path.join(state, 'foo-a1.meta'),
    'window=fm:fm-foo\nworktree=/wt/foo\nproject=/home/x/fleet/bridge\nharness=codex\nkind=ship\nmode=local-only\n');
  fs.writeFileSync(path.join(state, 'mate-s1.meta'),
    'window=fm:fm-mate\nkind=secondmate\nharness=codex\nhome=/h/mate\n');
  fs.writeFileSync(path.join(state, 'bad-b1.meta'), 'kind=bogus\nworktree=/wt/bad\n');

  // state/*.status: working+done map; malformed (no colon) + unknown keyword flag
  fs.writeFileSync(path.join(state, 'foo-a1.status'),
    'working: started\ndone: ready in branch\nweird line no colon here\nfrobnicate: unknown keyword\n');

  // state/*.turn-ended: a marker that has no canonical target (flag unmappable)
  fs.writeFileSync(path.join(state, 'foo-a1.turn-ended'), '');

  // data/backlog.md: in-flight row + done row map; a bulleted line with no id flags
  fs.writeFileSync(path.join(data, 'backlog.md'), [
    '# FirstMate backlog',
    '',
    '## In flight',
    '- [ ] foo-a1 - Do the thing (repo: bridge) (kind: ship) (since 2026-07-21)',
    '',
    '## Done',
    '- [x] old-x9 - Old task - https://github.com/o/r/pull/5 (merged 2026-07-01)',
    '- [ ] just prose no id',
    ''
  ].join('\n'));

  // state/task-lifecycle.jsonl: recorded maps; duplicate eventId + malformed line flag
  fs.writeFileSync(path.join(state, 'task-lifecycle.jsonl'), [
    JSON.stringify({ eventId: 'e1', id: 'foo-a1', event: 'recorded', actor: 'firstmate' }),
    JSON.stringify({ eventId: 'e1', id: 'foo-a1', event: 'closed', actor: 'firstmate', disposition: 'landed' }),
    'not json at all',
    ''
  ].join('\n'));

  // state/task-runs.jsonl: landed run maps; exact duplicate flags
  fs.writeFileSync(path.join(state, 'task-runs.jsonl'), [
    JSON.stringify({ schema: 'task_run/1', task: 'foo-a1', harness: 'codex', worktree: '/wt/foo', spawned_at: '2026-07-21T00:00:00Z', outcome: 'landed' }),
    JSON.stringify({ schema: 'task_run/1', task: 'foo-a1', harness: 'codex', worktree: '/wt/foo', spawned_at: '2026-07-21T00:00:00Z', outcome: 'landed' }),
    ''
  ].join('\n'));

  // state/captain-orders.jsonl: linked order maps; dismissed-unlinked (unmappable) + duplicate id
  fs.writeFileSync(path.join(state, 'captain-orders.jsonl'), [
    JSON.stringify({ id: 'o1', text: 'do foo', status: 'done', backlogId: 'foo-a1' }),
    JSON.stringify({ id: 'o2', text: 'chatter', status: 'dismissed', backlogId: null }),
    JSON.stringify({ id: 'o1', text: 'dup', status: 'done', backlogId: 'foo-a1' }),
    ''
  ].join('\n'));

  return home;
}

function hashTree(root) {
  const h = crypto.createHash('sha256');
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir).sort()) {
      const p = path.join(dir, name);
      const st = fs.statSync(p);
      if (st.isDirectory()) { h.update(`D:${name}\n`); walk(p); }
      else { h.update(`F:${path.relative(root, p)}:${fs.readFileSync(p)}\n`); }
    }
  };
  walk(root);
  return h.digest('hex');
}

test('totality: mapped + flagged === discovered, overall and per store', () => {
  const home = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const { report } = runMigrateReport({ home, outPath: out, env: {} });

  assert.equal(report.schema, REPORT_SCHEMA);
  assert.equal(report.totals.reconciles, true);
  assert.equal(report.totals.mapped + report.totals.flagged, report.totals.discovered);
  assert.equal(report.records.length, report.totals.discovered);

  let sumDiscovered = 0;
  for (const s of report.stores) {
    assert.equal(s.mapped + s.flagged, s.discovered, `store ${s.store} reconciles`);
    sumDiscovered += s.discovered;
  }
  assert.equal(sumDiscovered, report.totals.discovered);

  // Every record carries exactly one disposition; nothing silently skipped.
  for (const r of report.records) {
    assert.ok(r.disposition === 'mapped' || r.disposition === 'flagged');
    if (r.disposition === 'mapped') {
      assert.ok(Array.isArray(r.mapping.canonical) && r.mapping.canonical.length >= 1);
      for (const row of r.mapping.canonical) {
        assert.ok(['tasks', 'runs', 'task_events'].includes(row.table), `known table ${row.table}`);
        assert.ok(row.provenance && Object.keys(row.provenance).length >= 1, 'mapping has field provenance');
      }
    } else {
      assert.ok(FLAG_REASONS.includes(r.flag.reason), `flag reason ${r.flag.reason} is sanctioned`);
      assert.ok(typeof r.flag.detail === 'string' && r.flag.detail.length > 0, 'flag has a reason detail');
    }
  }
});

test('every sanctioned flag reason is exercised by the fixtures', () => {
  const home = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const { report } = runMigrateReport({ home, outPath: out, env: {} });
  assert.ok(report.flags_by_reason.unmappable >= 1, 'unmappable exercised');
  assert.ok(report.flags_by_reason.ambiguous >= 1, 'ambiguous exercised');
  assert.ok(report.flags_by_reason.duplicate >= 1, 'duplicate exercised');

  // Specific expectations proving the mapping semantics, not just the counts.
  const byRef = new Map(report.records.map((r) => [r.source_ref, r]));
  assert.equal(byRef.get('state/bad-b1.meta').flag.reason, 'unmappable');
  assert.equal(byRef.get('state/foo-a1.turn-ended').flag.reason, 'unmappable');
  // A meta with a valid kind + worktree proposes both a task and a run.
  assert.deepEqual(
    byRef.get('state/foo-a1.meta').mapping.canonical.map((c) => c.table),
    ['tasks', 'runs']
  );
  // A secondmate proposes a task but NO run.
  assert.deepEqual(
    byRef.get('state/mate-s1.meta').mapping.canonical.map((c) => c.table),
    ['tasks']
  );
});

// --- READ-ONLY ENFORCEMENT (mutation-sensitive) ----------------------------------

test('read-only: an attempted legacy write API call fails the run (tripwire io)', () => {
  const home = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');

  // A read-through facade that ALSO exposes every fs write API, each trip-wired to
  // fail the test. If any reader code path invoked a write against a legacy store, the
  // run would throw here. It completes because the shadow read never writes.
  const tripwire = (name) => () => assert.fail(`legacy write attempted via fs.${name}`);
  const io = {
    readdirSync: readOnlyFs.readdirSync,
    readFileSync: readOnlyFs.readFileSync,
    statSync: readOnlyFs.statSync,
    existsSync: readOnlyFs.existsSync,
    writeFileSync: tripwire('writeFileSync'),
    appendFileSync: tripwire('appendFileSync'),
    openSync: tripwire('openSync'),
    renameSync: tripwire('renameSync'),
    unlinkSync: tripwire('unlinkSync'),
    rmSync: tripwire('rmSync'),
    mkdirSync: tripwire('mkdirSync'),
    chmodSync: tripwire('chmodSync'),
    truncateSync: tripwire('truncateSync')
  };
  const { report } = runMigrateReport({ home, outPath: out, env: {}, io });
  assert.equal(report.totals.reconciles, true);
});

test('read-only: legacy tree is byte-identical before and after the run', () => {
  const home = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const before = hashTree(home);
  runMigrateReport({ home, outPath: out, env: {} });
  const after = hashTree(home);
  assert.equal(after, before, 'no legacy file created, modified, or removed');
});

test('read-only: run succeeds against an on-disk read-only legacy home', () => {
  const home = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  // Make every legacy file and dir non-writable. A write attempt would EACCES and throw.
  const chmodTree = (dir, dmode, fmode) => {
    for (const name of fs.readdirSync(dir)) {
      const p = path.join(dir, name);
      const st = fs.statSync(p);
      if (st.isDirectory()) { chmodTree(p, dmode, fmode); fs.chmodSync(p, dmode); }
      else fs.chmodSync(p, fmode);
    }
  };
  try {
    chmodTree(home, 0o555, 0o444);
    fs.chmodSync(home, 0o555);
    const { report } = runMigrateReport({ home, outPath: out, env: {} });
    assert.equal(report.totals.reconciles, true);
    assert.ok(fs.existsSync(out), 'report is written to the OUT path outside the read-only home');
  } finally {
    // Restore perms so cleanupAll can remove the tree.
    fs.chmodSync(home, 0o755);
    const restore = (dir) => {
      for (const name of fs.readdirSync(dir)) {
        const p = path.join(dir, name);
        const st = fs.statSync(p);
        if (st.isDirectory()) { fs.chmodSync(p, 0o755); restore(p); }
        else fs.chmodSync(p, 0o644);
      }
    };
    restore(home);
  }
});

// --- DETERMINISM -----------------------------------------------------------------

test('determinism: two runs over the same legacy home are byte-identical', () => {
  const home = buildLegacyHome();
  const outA = path.join(mkTempDir('cp-s8-out-'), 'a.json');
  const outB = path.join(mkTempDir('cp-s8-out-'), 'b.json');
  runMigrateReport({ home, outPath: outA, env: {} });
  runMigrateReport({ home, outPath: outB, env: {} });
  assert.equal(fs.readFileSync(outA, 'utf8'), fs.readFileSync(outB, 'utf8'));
});

test('determinism: record order follows the fixed store order', () => {
  const home = buildLegacyHome();
  const records = readLegacyRecords(home);
  const seen = records.map((r) => r.store);
  // Store groups appear in LEGACY_STORES order (a store may be absent -> just skipped).
  let idx = -1;
  for (const store of seen) {
    const pos = LEGACY_STORES.indexOf(store);
    assert.ok(pos >= idx, `store ${store} not out of order`);
    idx = Math.max(idx, pos);
  }
});

// --- ATOMIC OUTPUT ---------------------------------------------------------------

test('atomic: report is written 0600 and parses as JSON', () => {
  const home = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  runMigrateReport({ home, outPath: out, env: {} });
  assert.equal(fs.statSync(out).mode & 0o777, 0o600);
  const parsed = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(parsed.schema, REPORT_SCHEMA);
  assert.ok(typeof parsed.human_summary === 'string' && parsed.human_summary.includes('READ-ONLY'));
});

test('atomic: a crash before rename leaves NO partial file at the OUT path', () => {
  const home = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  assert.throws(() => runMigrateReport({
    home, outPath: out, env: {},
    fault: () => { throw new Error('crash between temp-durable and rename'); }
  }), /crash between temp-durable and rename/);
  assert.equal(fs.existsSync(out), false, 'no torn report at the final path');
});

test('atomic: --out inside the legacy home is rejected loudly', () => {
  const home = buildLegacyHome();
  const inside = path.join(home, 'state', 'report.json');
  assert.throws(() => runMigrateReport({ home, outPath: inside, env: {} }), MigrateReportError);
});

// --- SURFACE + RESOLUTION --------------------------------------------------------

test('surface: migrate-report requires --out', async () => {
  await assert.rejects(runVerb(['migrate-report', '--home', '/nope'], { env: {} }), /requires --out/);
});

test('surface: migrate-report rejects positional args and --deliver', async () => {
  await assert.rejects(runVerb(['migrate-report', 'extra', '--out', '/x'], { env: {} }), /no positional|takes no positional/);
  await assert.rejects(runVerb(['migrate-report', '--out', '/x', '--deliver'], { env: {} }), /--deliver/);
});

test('surface: CLI runVerb path returns a receipt that reconciles', async () => {
  const home = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const outcome = await runVerb(['migrate-report', '--home', home, '--out', out], { env: {} });
  assert.equal(outcome.ok, true);
  assert.equal(outcome.result.reconciles, true);
  assert.equal(outcome.result.mapped + outcome.result.flagged, outcome.result.discovered);
  assert.equal(outcome.result.out, path.resolve(out));
});

test('resolution: legacy home resolves from CP_LEGACY_HOME then FM_HOME', () => {
  assert.equal(resolveLegacyHome({ env: { CP_LEGACY_HOME: '/a' } }), path.resolve('/a'));
  assert.equal(resolveLegacyHome({ env: { FM_HOME: '/b' } }), path.resolve('/b'));
  assert.throws(() => resolveLegacyHome({ env: {} }), LegacyReadError);
});

test('reader/mapper: a missing store yields no records; an unknown store flags', () => {
  const home = mkTempDir('cp-s8-empty-');
  const records = readLegacyRecords(home);
  assert.equal(records.length, 0, 'absent legacy stores are empty, not an error');
  const disp = mapRecord({ store: 'not-a-store', source_ref: 'x', raw: '', value: {} }, newMappingContext());
  assert.equal(disp.disposition, 'flagged');
  assert.equal(disp.flag.reason, 'unmappable');
});

test('buildReport totals reconcile for a pure-flag disposition set', () => {
  const dispositions = [
    { store: 'state-turn-ended', source_ref: 'a', disposition: 'flagged', flag: { reason: 'unmappable', detail: 'x' } },
    { store: 'state-meta', source_ref: 'b', disposition: 'mapped', mapping: { canonical: [] } }
  ];
  const report = buildReport('/home', [], dispositions);
  assert.equal(report.totals.discovered, 2);
  assert.equal(report.totals.mapped, 1);
  assert.equal(report.totals.flagged, 1);
  assert.equal(report.totals.reconciles, true);
});
