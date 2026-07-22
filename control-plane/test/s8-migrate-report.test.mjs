import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { runVerb } from '../lib/coordinator.mjs';
import { runMigrateReport, buildReport, REPORT_SCHEMA } from '../lib/migrate-report.mjs';
import {
  readLegacyRecords, readOnlyFs, resolveLegacyHome, resolveAuthoritativeOrdersPath, LEGACY_STORES
} from '../lib/legacy-reader.mjs';
import { mapRecord, newMappingContext, FLAG_REASONS } from '../lib/migrate-map.mjs';
import { MigrateReportError, LegacyReadError } from '../lib/errors-s8.mjs';
import { mkTempDir, cleanupAll } from './helpers.mjs';

// S8 migrate-report: a strictly READ-ONLY shadow read of the legacy stores that emits a
// deterministic mapped-or-flagged proposal and applies nothing (spec section 13). The
// suite proves mapped-or-flagged TOTALITY over well-formed/malformed/partial/duplicate
// fixtures across ALL section-13 stores (including the authoritative external order ledger
// and a Bridge History projection), INDEPENDENTLY enforced totality (a hidden mapper input
// is rejected), MUTATION-SENSITIVE read-only enforcement (a symlinked --out that resolves
// under a legacy store is refused; a write attempt via the reader fails the run), source-
// record auditability, determinism, and atomic output.
after(cleanupAll);

function digestOf(raw) { return crypto.createHash('sha256').update(raw).digest('hex'); }

// Build a fixture legacy home + external order ledger + Bridge History export exercising
// every store and every disposition path. Returns { home, ordersPath, bridgeHistoryPath }.
function buildLegacyHome() {
  const home = mkTempDir('cp-s8-legacy-');
  const state = path.join(home, 'state');
  const data = path.join(home, 'data');
  fs.mkdirSync(state, { recursive: true });
  fs.mkdirSync(data, { recursive: true });

  fs.writeFileSync(path.join(state, 'foo-a1.meta'),
    'window=fm:fm-foo\nworktree=/wt/foo\nproject=/home/x/fleet/bridge\nharness=codex\nkind=ship\nmode=local-only\n');
  fs.writeFileSync(path.join(state, 'mate-s1.meta'),
    'window=fm:fm-mate\nkind=secondmate\nharness=codex\nhome=/h/mate\n');
  fs.writeFileSync(path.join(state, 'bad-b1.meta'), 'kind=bogus\nworktree=/wt/bad\n');

  fs.writeFileSync(path.join(state, 'foo-a1.status'),
    'working: started\ndone: ready in branch\nweird line no colon here\nfrobnicate: unknown keyword\n');

  fs.writeFileSync(path.join(state, 'foo-a1.turn-ended'), '');

  fs.writeFileSync(path.join(data, 'backlog.md'), [
    '# FirstMate backlog', '', '## In flight',
    '- [ ] foo-a1 - Do the thing (repo: bridge) (kind: ship) (since 2026-07-21)',
    '', '## Done',
    '- [x] old-x9 - Old task - https://github.com/o/r/pull/5 (merged 2026-07-01)',
    '- [ ] just prose no id', ''
  ].join('\n'));

  // done-archive.md: an archived task maps; a bulleted line with no id flags.
  fs.writeFileSync(path.join(data, 'done-archive.md'), [
    '# Done archive', '', '## Archived 2026-07-01',
    '- [x] arch-z1 - Archived thing (repo: bridge) (merged 2026-07-01)',
    '- [x] - malformed archive bullet', ''
  ].join('\n'));

  fs.writeFileSync(path.join(state, 'task-lifecycle.jsonl'), [
    JSON.stringify({ eventId: 'e1', id: 'foo-a1', event: 'recorded', actor: 'firstmate' }),
    JSON.stringify({ eventId: 'e1', id: 'foo-a1', event: 'closed', actor: 'firstmate', disposition: 'landed' }),
    'not json at all', ''
  ].join('\n'));

  fs.writeFileSync(path.join(state, 'task-runs.jsonl'), [
    JSON.stringify({ schema: 'task_run/1', task: 'foo-a1', harness: 'codex', worktree: '/wt/foo', spawned_at: '2026-07-21T00:00:00Z', outcome: 'landed' }),
    JSON.stringify({ schema: 'task_run/1', task: 'foo-a1', harness: 'codex', worktree: '/wt/foo', spawned_at: '2026-07-21T00:00:00Z', outcome: 'landed' }),
    ''
  ].join('\n'));

  // In-home LEGACY folded order ledger (old id/backlogId schema).
  fs.writeFileSync(path.join(state, 'captain-orders.jsonl'), [
    JSON.stringify({ id: 'o1', text: 'do foo', status: 'done', backlogId: 'foo-a1' }),
    JSON.stringify({ id: 'o2', text: 'chatter', status: 'dismissed', backlogId: null }),
    JSON.stringify({ id: 'o1', text: 'dup', status: 'done', backlogId: 'foo-a1' }),
    ''
  ].join('\n'));

  // AUTHORITATIVE external order ledger (firstmate/captain-order/v1 event schema), stored
  // OUTSIDE the home like the real inbox. Linked event maps; unlinked received is ambiguous;
  // dismissed-unlinked is unmappable; an exact replayed line is a duplicate; malformed flags.
  const ext = mkTempDir('cp-s8-orders-');
  const ordersPath = path.join(ext, 'captain-orders.jsonl');
  const linkedLine = JSON.stringify({ schema: 'firstmate/captain-order/v1', order_id: 'ORD-9', event: 'complete', status: 'completed', linked_task_ids: ['foo-a1'] });
  fs.writeFileSync(ordersPath, [
    JSON.stringify({ schema: 'firstmate/captain-order/v1', order_id: 'ORD-1', event: 'received', status: 'received', linked_task_ids: [] }),
    linkedLine,
    JSON.stringify({ schema: 'firstmate/captain-order/v1', order_id: 'ORD-2', event: 'dismiss', status: 'dismissed', linked_task_ids: [] }),
    linkedLine, // exact replay -> duplicate
    'not json', ''
  ].join('\n'));

  // Bridge History projection export (a derived view): every record flags as a duplicate.
  const bridgeDir = mkTempDir('cp-s8-bridge-');
  const bridgeHistoryPath = path.join(bridgeDir, 'bridge-history.json');
  fs.writeFileSync(bridgeHistoryPath, JSON.stringify([
    { id: 'foo-a1', kind: 'ship', sources: ['backlog'], date: '2026-07-21' },
    { id: 'arch-z1', kind: 'ship', sources: ['archive'], date: '2026-07-01' }
  ]));

  return { home, ordersPath, bridgeHistoryPath };
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

function run(fx, out, extra = {}) {
  return runMigrateReport({ home: fx.home, ordersPath: fx.ordersPath, bridgeHistoryPath: fx.bridgeHistoryPath, outPath: out, env: {}, ...extra });
}

test('totality: mapped + flagged === discovered, overall and per store', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const { report } = run(fx, out);

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

  for (const r of report.records) {
    assert.ok(r.disposition === 'mapped' || r.disposition === 'flagged');
    assert.ok(r.source && typeof r.source.digest === 'string' && typeof r.source.raw === 'string', 'disposition carries its source record');
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

test('section-13 inventory: authoritative order ledger and Bridge History are enumerated', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const { report } = run(fx, out);

  const byStore = new Map(report.stores.map((s) => [s.store, s]));
  assert.ok(byStore.get('authoritative-orders').discovered >= 4, 'authoritative order events enumerated');
  assert.ok(byStore.get('bridge-history').discovered === 2, 'bridge history projection records enumerated');
  assert.ok(byStore.get('done-archive').discovered >= 1, 'done-archive enumerated');

  // Sources manifest declares every store and whether it resolved (no silent omission).
  const srcStores = report.sources.map((s) => s.store);
  for (const s of LEGACY_STORES) assert.ok(srcStores.includes(s), `sources manifest lists ${s}`);
  const authSrc = report.sources.find((s) => s.store === 'authoritative-orders');
  assert.equal(authSrc.resolved, true);
  assert.equal(authSrc.path, fx.ordersPath);

  // New-schema order events: linked -> mapped(order_ref); unlinked -> ambiguous;
  // dismissed-unlinked -> unmappable; replayed identical line -> duplicate.
  const auth = report.records.filter((r) => r.store === 'authoritative-orders');
  const mappedAuth = auth.find((r) => r.disposition === 'mapped');
  assert.ok(mappedAuth, 'a linked authoritative order maps to order_ref');
  assert.equal(mappedAuth.mapping.canonical[0].fields.order_ref, 'ORD-9');
  assert.equal(mappedAuth.mapping.canonical[0].fields.task_id, 'foo-a1');
  assert.ok(auth.some((r) => r.disposition === 'flagged' && r.flag.reason === 'ambiguous'));
  assert.ok(auth.some((r) => r.disposition === 'flagged' && r.flag.reason === 'unmappable'));
  assert.ok(auth.some((r) => r.disposition === 'flagged' && r.flag.reason === 'duplicate'), 'replayed order line is a duplicate');

  // Every Bridge History record is flagged duplicate (derived projection, no new row).
  const bh = report.records.filter((r) => r.store === 'bridge-history');
  assert.ok(bh.length === 2 && bh.every((r) => r.disposition === 'flagged' && r.flag.reason === 'duplicate'));
});

test('every sanctioned flag reason is exercised; specific mapping semantics hold', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const { report } = run(fx, out);
  assert.ok(report.flags_by_reason.unmappable >= 1);
  assert.ok(report.flags_by_reason.ambiguous >= 1);
  assert.ok(report.flags_by_reason.duplicate >= 1);

  const byRef = new Map(report.records.map((r) => [r.source_ref, r]));
  assert.equal(byRef.get('state/bad-b1.meta').flag.reason, 'unmappable');
  assert.equal(byRef.get('state/foo-a1.turn-ended').flag.reason, 'unmappable');
  assert.deepEqual(byRef.get('state/foo-a1.meta').mapping.canonical.map((c) => c.table), ['tasks', 'runs']);
  assert.deepEqual(byRef.get('state/mate-s1.meta').mapping.canonical.map((c) => c.table), ['tasks']);
});

// --- READ-ONLY ENFORCEMENT (mutation-sensitive) ----------------------------------

test('read-only: a symlinked --out that resolves under a legacy store is REFUSED', () => {
  const fx = buildLegacyHome();
  const before = hashTree(fx.home);
  // Hostile alias: an output "directory" that is really a symlink into the legacy store.
  const link = path.join(mkTempDir('cp-s8-link-'), 'out-link');
  fs.symlinkSync(path.join(fx.home, 'state'), link);
  assert.throws(
    () => run(fx, path.join(link, 'legacy-write.json')),
    (err) => err instanceof MigrateReportError && /resolves under the legacy home/.test(err.message)
  );
  // Nothing was written into the legacy store.
  assert.equal(fs.existsSync(path.join(fx.home, 'state', 'legacy-write.json')), false);
  assert.equal(hashTree(fx.home), before, 'legacy tree byte-identical after the refused write');
});

test('read-only: an attempted legacy write API call fails the run (tripwire io)', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
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
  const { report } = run(fx, out, { io });
  assert.equal(report.totals.reconciles, true);
});

test('read-only: legacy tree is byte-identical before and after the run', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const before = hashTree(fx.home);
  run(fx, out);
  assert.equal(hashTree(fx.home), before, 'no legacy file created, modified, or removed');
});

test('read-only: run succeeds against an on-disk read-only legacy home', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const chmodTree = (dir, dmode, fmode) => {
    for (const name of fs.readdirSync(dir)) {
      const p = path.join(dir, name);
      const st = fs.statSync(p);
      if (st.isDirectory()) { chmodTree(p, dmode, fmode); fs.chmodSync(p, dmode); }
      else fs.chmodSync(p, fmode);
    }
  };
  try {
    chmodTree(fx.home, 0o555, 0o444);
    fs.chmodSync(fx.home, 0o555);
    const { report } = run(fx, out);
    assert.equal(report.totals.reconciles, true);
    assert.ok(fs.existsSync(out));
  } finally {
    fs.chmodSync(fx.home, 0o755);
    const restore = (dir) => {
      for (const name of fs.readdirSync(dir)) {
        const p = path.join(dir, name);
        const st = fs.statSync(p);
        if (st.isDirectory()) { fs.chmodSync(p, 0o755); restore(p); }
        else fs.chmodSync(p, 0o644);
      }
    };
    restore(fx.home);
  }
});

// --- INDEPENDENT TOTALITY (a hidden mapper input must break the totals) -----------

test('totality is independent: a record dropped before mapping REJECTS the run', () => {
  const fx = buildLegacyHome();
  const { records } = readLegacyRecords(fx.home, { ordersPath: fx.ordersPath, bridgeHistoryPath: fx.bridgeHistoryPath });
  const ctx = newMappingContext();
  // Hide every state-status record between reading and mapping.
  const hidden = records.filter((r) => r.store === 'state-status').length;
  assert.ok(hidden >= 1, 'fixture has status records to hide');
  const mutant = records.filter((r) => r.store !== 'state-status').map((r) => mapRecord(r, ctx));
  assert.throws(
    () => buildReport(fx.home, records, mutant, []),
    (err) => err instanceof MigrateReportError && /integrity check failed/.test(err.message)
  );
});

test('buildReport rejects an empty-canonical mapped disposition', () => {
  const records = [{ store: 'state-meta', source_ref: 'a', raw: 'x', value: {}, digest: digestOf('x') }];
  const bad = [{ store: 'state-meta', source_ref: 'a', disposition: 'mapped', mapping: { canonical: [] }, source: { digest: digestOf('x'), raw: 'x', value: {} } }];
  assert.throws(() => buildReport('/home', records, bad, []), MigrateReportError);
});

test('buildReport accepts a well-formed bijection', () => {
  const records = [
    { store: 'state-turn-ended', source_ref: 'a', raw: 'a', value: {}, digest: digestOf('a') },
    { store: 'state-meta', source_ref: 'b', raw: 'b', value: {}, digest: digestOf('b') }
  ];
  const disp = [
    { store: 'state-turn-ended', source_ref: 'a', disposition: 'flagged', flag: { reason: 'unmappable', detail: 'x' }, source: { digest: digestOf('a'), raw: 'a', value: {} } },
    { store: 'state-meta', source_ref: 'b', disposition: 'mapped', mapping: { canonical: [{ table: 'tasks', key: 'b', fields: {}, provenance: { task_id: 'b' }, unresolved: [] }] }, source: { digest: digestOf('b'), raw: 'b', value: {} } }
  ];
  const report = buildReport('/home', records, disp, []);
  assert.equal(report.totals.discovered, 2);
  assert.equal(report.totals.mapped, 1);
  assert.equal(report.totals.flagged, 1);
  assert.equal(report.totals.reconciles, true);
});

// --- SOURCE-RECORD AUDITABILITY --------------------------------------------------

test('auditability: a flagged malformed record is fully recoverable from the report', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  run(fx, out);
  const report = JSON.parse(fs.readFileSync(out, 'utf8'));
  const malformed = report.records.find((r) => r.store === 'task-lifecycle' && r.disposition === 'flagged' && /malformed/.test(r.flag.detail));
  assert.ok(malformed, 'malformed lifecycle line is flagged');
  assert.equal(malformed.source.raw, 'not json at all', 'the raw source line is present in the artifact');
  assert.equal(malformed.source.digest, digestOf('not json at all'), 'the source digest matches the raw content');
});

// --- DETERMINISM -----------------------------------------------------------------

test('determinism: two runs over the same inputs are byte-identical', () => {
  const fx = buildLegacyHome();
  const outA = path.join(mkTempDir('cp-s8-out-'), 'a.json');
  const outB = path.join(mkTempDir('cp-s8-out-'), 'b.json');
  run(fx, outA);
  run(fx, outB);
  assert.equal(fs.readFileSync(outA, 'utf8'), fs.readFileSync(outB, 'utf8'));
});

test('determinism: record order follows the fixed store order', () => {
  const fx = buildLegacyHome();
  const { records } = readLegacyRecords(fx.home, { ordersPath: fx.ordersPath, bridgeHistoryPath: fx.bridgeHistoryPath });
  let idx = -1;
  for (const r of records) {
    const pos = LEGACY_STORES.indexOf(r.store);
    assert.ok(pos >= idx, `store ${r.store} not out of order`);
    idx = Math.max(idx, pos);
  }
});

// --- ATOMIC OUTPUT ---------------------------------------------------------------

test('atomic: report is written 0600 and parses as JSON with a human summary', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  run(fx, out);
  assert.equal(fs.statSync(out).mode & 0o777, 0o600);
  const parsed = JSON.parse(fs.readFileSync(out, 'utf8'));
  assert.equal(parsed.schema, REPORT_SCHEMA);
  assert.ok(parsed.human_summary.includes('READ-ONLY') && parsed.human_summary.includes('sources:'));
});

test('atomic: a crash before rename leaves NO partial file at the OUT path', () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  assert.throws(() => run(fx, out, { fault: () => { throw new Error('crash between temp-durable and rename'); } }),
    /crash between temp-durable and rename/);
  assert.equal(fs.existsSync(out), false, 'no torn report at the final path');
});

test('atomic: --out lexically inside the legacy home is rejected', () => {
  const fx = buildLegacyHome();
  assert.throws(() => run(fx, path.join(fx.home, 'state', 'report.json')), MigrateReportError);
});

// --- SURFACE + RESOLUTION --------------------------------------------------------

test('surface: migrate-report requires --out', async () => {
  await assert.rejects(runVerb(['migrate-report', '--home', '/nope'], { env: {} }), /requires --out/);
});

test('surface: migrate-report rejects positional args and --deliver', async () => {
  await assert.rejects(runVerb(['migrate-report', 'extra', '--out', '/x'], { env: {} }), /positional/);
  await assert.rejects(runVerb(['migrate-report', '--out', '/x', '--deliver'], { env: {} }), /--deliver/);
});

test('surface: the authoritative order ledger is required (loud when unresolved)', async () => {
  const fx = buildLegacyHome();
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  await assert.rejects(
    runVerb(['migrate-report', '--home', fx.home, '--out', out], { env: {} }),
    /authoritative order ledger unresolved/
  );
});

test('surface: CLI runVerb path resolves via config/orders-path pointer and reconciles', async () => {
  const fx = buildLegacyHome();
  fs.mkdirSync(path.join(fx.home, 'config'), { recursive: true });
  fs.writeFileSync(path.join(fx.home, 'config', 'orders-path'), `${fx.ordersPath}\n`);
  const out = path.join(mkTempDir('cp-s8-out-'), 'report.json');
  const outcome = await runVerb(['migrate-report', '--home', fx.home, '--out', out, '--bridge-history', fx.bridgeHistoryPath], { env: {} });
  assert.equal(outcome.ok, true);
  assert.equal(outcome.result.reconciles, true);
  assert.equal(outcome.result.mapped + outcome.result.flagged, outcome.result.discovered);
  assert.equal(outcome.result.out, path.resolve(out));
  assert.equal(outcome.result.orders_path, fx.ordersPath);
});

test('resolution: legacy home resolves from CP_LEGACY_HOME then FM_HOME', () => {
  assert.equal(resolveLegacyHome({ env: { CP_LEGACY_HOME: '/a' } }), path.resolve('/a'));
  assert.equal(resolveLegacyHome({ env: { FM_HOME: '/b' } }), path.resolve('/b'));
  assert.throws(() => resolveLegacyHome({ env: {} }), LegacyReadError);
});

test('resolution: authoritative orders resolve from explicit, env, then pointer', () => {
  assert.equal(resolveAuthoritativeOrdersPath({ explicit: '/x/orders.jsonl', home: '/h', env: {} }), path.resolve('/x/orders.jsonl'));
  assert.equal(resolveAuthoritativeOrdersPath({ home: '/h', env: { CP_ORDERS_PATH: '/y/o.jsonl' } }), path.resolve('/y/o.jsonl'));
  assert.throws(() => resolveAuthoritativeOrdersPath({ home: '/h', env: {} }), MigrateReportError);
});

test('reader: a missing store yields no records but is still declared in the manifest', () => {
  const empty = mkTempDir('cp-s8-empty-');
  const ordersPath = path.join(mkTempDir('cp-s8-o-'), 'o.jsonl');
  fs.writeFileSync(ordersPath, '');
  const { records, sources } = readLegacyRecords(empty, { ordersPath });
  assert.equal(records.length, 0, 'absent legacy stores are empty, not an error');
  assert.equal(sources.length, LEGACY_STORES.length, 'every store is declared');
  const disp = mapRecord({ store: 'not-a-store', source_ref: 'x', raw: '', value: {}, digest: digestOf('') }, newMappingContext());
  assert.equal(disp.disposition, 'flagged');
  assert.equal(disp.flag.reason, 'unmappable');
});
