import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { runVerb } from '../lib/coordinator.mjs';
import { createTask, beginRun, appendEvent } from '../lib/domain-store.mjs';
import { recordSpawn, commitRunning, cleanupIntent, cleanupFinish } from '../lib/domain-store-s3.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import { readCursor } from '../lib/domain-store-s4.mjs';
import { FirstMateConsumer } from '../lib/firstmate-consumer.mjs';
import { FileLedgerSink } from '../lib/sinks.mjs';
import { createSnapshot, getSnapshot } from '../lib/domain-store-s6.mjs';
import { acquireStableOrderPrefix } from '../lib/order-prefix.mjs';
import { projectBridge, projectHelm } from '../lib/projections.mjs';
import { mkFixtureHome, mkTempDir, cleanupAll } from './helpers.mjs';

// S6 adversarial: crash cutpoints and races that a wrong implementation would get wrong.
// Real child-process exits prove the durable cutpoints (snapshot crash between insert
// and return; export crash mid-write; two racers on the flock); injected file/stat seams
// prove the order-prefix stability contract; and the cumulative integration gate walks
// the whole spec-895-901 chain end to end (archive handled per the Q3 ruling). Every
// order-prefix test uses an ISOLATED fixture inbox - never the real captain inbox.
after(cleanupAll);

const IDENTITY = {
  endpointId: '@0', paneId: '%0', bootId: 'boot-xyz',
  paneLeaderPid: 4242, paneStartTicks: 111111,
  agentPid: 4243, agentStartTicks: 222222, agentExe: '/usr/bin/node',
  agentArgvHash: 'argvhash-abc', agentPpid: 4242, agentPty: 'pts/7',
  worktree: '/tmp/wt', harness: 'claude'
};
const captureOk = () => ({ ok: true, identity: { ...IDENTITY } });
const probeMatch = () => ({ matches: true, failingClause: null, anomalyClass: null });

async function freshStore() {
  const { fmHome } = mkFixtureHome();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'test' });
  return { store, fmHome };
}
async function rows(store, sql, params) {
  return runExclusive(store, async (conn) => (await conn.query(sql, params)).rows);
}
async function counters(store) {
  const r = await rows(store, 'SELECT domain_revision, projection_revision, commit_sequence FROM coordinator_state WHERE id = 1');
  return { domain: Number(r[0].domain_revision), projection: Number(r[0].projection_revision), commit: Number(r[0].commit_sequence) };
}
async function snapshotCount(store) {
  const r = await rows(store, 'SELECT count(*)::int AS n FROM snapshots');
  return Number(r[0].n);
}
function fixtureInbox(lines = []) {
  const dir = mkTempDir('cp-s6-inbox-');
  const p = path.join(dir, 'captain-orders.jsonl');
  fs.writeFileSync(p, lines.map((l) => (typeof l === 'string' ? l : JSON.stringify(l))).join('\n') + (lines.length ? '\n' : ''));
  return p;
}
async function createTaskQueued(store, taskId) {
  await createTask(store, { taskId, kind: 'ship', title: `T ${taskId}`, origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
}

// Run a worker child to completion; resolve with { status, stdout, stderr }.
function runWorker(worker, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [worker], { env, encoding: 'utf8' });
    let stdout = ''; let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('error', reject);
    child.on('close', (status) => resolve({ status, stdout, stderr }));
  });
}
const SNAP_WORKER = fileURLToPath(new URL('./workers/crash-snapshot-writer.mjs', import.meta.url));
const EXPORT_WORKER = fileURLToPath(new URL('./workers/crash-export-writer.mjs', import.meta.url));

// =====================================================================================

test('t_snapshot_crash_between_insert_and_return_recovers_idempotently', async () => {
  const { store, fmHome } = await freshStore();
  await createTaskQueued(store, 't1');
  const inbox = fixtureInbox([{ id: 'ORD-1' }]);
  const before = await counters(store);
  await store.close();

  // A REAL child runs one snapshot and HARD-EXITS after the transaction durably commits
  // and before it can report the result - the "between insert and return" cut. The row is
  // already on disk; the OS releases the flock.
  const crash = await runWorker(SNAP_WORKER, {
    ...process.env, CP_FM_HOME: fmHome, CP_ORDER_SOURCE: inbox, CP_MODE: 'crash-after-commit'
  });
  assert.equal(crash.status, 47, `snapshot writer must hard-exit after commit (stderr: ${crash.stderr})`);

  const reopened = new PgliteLocalStore({ fmHome });
  assert.equal(await snapshotCount(reopened), 1, 'the snapshot committed before the crash');
  const afterCrash = await counters(reopened);
  assert.equal(afterCrash.projection, before.projection + 1, 'projection_revision moved exactly once');
  assert.equal(afterCrash.commit, before.commit + 1, 'commit_sequence moved exactly once');
  assert.equal(afterCrash.domain, before.domain, 'domain_revision untouched by the snapshot');

  // Recovery is a plain rerun: it DEDUPS to the already-committed row, never a second row
  // and never a second increment.
  const rerun = await createSnapshot(reopened, { orderSourcePath: inbox });
  assert.equal(rerun.deduped, true, 'the rerun idempotently returns the durable snapshot');
  assert.equal(rerun.projection_revision, afterCrash.projection);
  assert.equal(await snapshotCount(reopened), 1, 'still exactly one snapshot row');
  assert.deepEqual(await counters(reopened), afterCrash, 'the idempotent rerun bumped nothing');
});

test('t_concurrent_snapshot_single_increment', async () => {
  const { store, fmHome } = await freshStore();
  await createTaskQueued(store, 't1');
  const inbox = fixtureInbox([{ id: 'ORD-1' }, { id: 'ORD-2' }]);
  const before = await counters(store);
  await store.close();

  // Two REAL children race the same snapshot concurrently. The whole-transaction flock
  // serializes them: one inserts a new row, the other's in-transaction dedup SELECT sees
  // that just-committed row and returns it. Exactly ONE new row, ONE increment.
  const env = { ...process.env, CP_FM_HOME: fmHome, CP_ORDER_SOURCE: inbox, CP_MODE: 'plain' };
  const [a, b] = await Promise.all([runWorker(SNAP_WORKER, env), runWorker(SNAP_WORKER, env)]);
  assert.equal(a.status, 0, `racer A exited clean (stderr: ${a.stderr})`);
  assert.equal(b.status, 0, `racer B exited clean (stderr: ${b.stderr})`);
  const ra = JSON.parse(a.stdout);
  const rb = JSON.parse(b.stdout);

  assert.equal(ra.projection_revision, rb.projection_revision, 'both racers report the SAME projection revision');
  assert.equal(ra.checksum, rb.checksum, 'both report the same checksum');
  const dedupFlags = [ra.deduped, rb.deduped].sort();
  assert.deepEqual(dedupFlags, [false, true], 'exactly one inserted, exactly one deduped');

  const reopened = new PgliteLocalStore({ fmHome });
  assert.equal(await snapshotCount(reopened), 1, 'exactly one snapshot row from the race');
  const after = await counters(reopened);
  assert.equal(after.projection, before.projection + 1, 'projection_revision incremented exactly once');
  assert.equal(after.commit, before.commit + 1, 'commit_sequence incremented exactly once');
});

test('t_inbox_append_during_capture_lands_in_next_snapshot', async () => {
  // spec 753: an append after the captured byte boundary appears in a LATER snapshot only.
  const { store } = await freshStore();
  await createTaskQueued(store, 't1');
  const inbox = fixtureInbox([{ id: 'ORD-1' }, { id: 'ORD-2' }]);

  // Snapshot 1 captures the two-record prefix. An append is injected DURING the capture,
  // between the read and the re-stat (afterReadHook), so it grows the file past the
  // already-read boundary. The re-stat sees growth (not shrink/rotation) and accepts; the
  // appended bytes are excluded from THIS snapshot.
  let appended = false;
  const s1 = await createSnapshot(store, {
    orderSourcePath: inbox,
    orderPrefixOptions: {
      afterReadHook: () => {
        if (appended) return;
        appended = true;
        fs.appendFileSync(inbox, JSON.stringify({ id: 'ORD-3', text: 'mid-capture append' }) + '\n');
      }
    }
  });
  const snap1 = await getSnapshot(store, { revision: s1.projection_revision });
  assert.equal(snap1.payload.orders.count, 2, 'the mid-capture append is NOT in this snapshot');
  assert.ok(!snap1.payload.orders.records.some((r) => r.id === 'ORD-3'), 'ORD-3 excluded from snapshot 1');

  // Snapshot 2 captures the grown file: the appended order now lands.
  const s2 = await createSnapshot(store, { orderSourcePath: inbox });
  assert.equal(s2.deduped, false, 'the changed order prefix makes a genuinely new snapshot');
  const snap2 = await getSnapshot(store, { revision: s2.projection_revision });
  assert.equal(snap2.payload.orders.count, 3, 'the appended order lands in the NEXT snapshot');
  assert.ok(snap2.payload.orders.records.some((r) => r.id === 'ORD-3'), 'ORD-3 present in snapshot 2');
  assert.ok(s2.order_source_bytes > s1.order_source_bytes, 'the later snapshot covers more order bytes');
});

test('t_inbox_rotation_mid_read_detected', async () => {
  // A REAL file rotation between the read and the re-stat must be DETECTED (identity
  // change) and force a retry; the returned prefix must reflect the post-rotation file,
  // never a torn mix of the two.
  const dir = mkTempDir('cp-s6-inbox-');
  const p = path.join(dir, 'orders.jsonl');
  fs.writeFileSync(p, JSON.stringify({ id: 'OLD-1' }) + '\n' + JSON.stringify({ id: 'OLD-2' }) + '\n');

  let attempts = 0;
  let rotated = false;
  const pre = await acquireStableOrderPrefix(p, {
    afterReadHook: (attempt) => {
      attempts += 1;
      if (rotated) return; // only rotate once, on the first attempt
      rotated = true;
      // Rotate: move the old file aside and drop a NEW inode at the same path. The next
      // re-stat sees a different inode -> rotation detected -> retry.
      fs.renameSync(p, `${p}.1`);
      fs.writeFileSync(p, JSON.stringify({ id: 'NEW-1' }) + '\n');
      void attempt;
    }
  });

  assert.ok(attempts >= 2, 'the rotation forced at least one retry (detected, not read-through)');
  assert.equal(pre.records.length, 1, 'the stable prefix is from the post-rotation file');
  assert.equal(pre.records[0].id, 'NEW-1', 'no torn mix of pre/post rotation content');
});

test('t_export_crash_mid_write_leaves_no_partial_file', async () => {
  const { store, fmHome } = await freshStore();
  await createTaskQueued(store, 't1');
  await createSnapshot(store, { orderSourcePath: fixtureInbox([{ id: 'ORD-1' }]) });
  await store.close();

  const outDir = mkTempDir('cp-s6-export-');
  const outPath = path.join(outDir, 'snap.json');

  // A REAL child exports but HARD-EXITS after the temp file is durable and before the
  // atomic rename. The final path must NOT exist (temp+rename means no torn final file).
  const crash = await runWorker(EXPORT_WORKER, {
    ...process.env, CP_FM_HOME: fmHome, CP_OUT: outPath
  });
  assert.equal(crash.status, 48, `export writer must hard-exit before rename (stderr: ${crash.stderr})`);
  assert.equal(fs.existsSync(outPath), false, 'no partial file at the final path after a mid-write crash');
  const strays = fs.readdirSync(outDir).filter((f) => f.startsWith('snap.json.tmp.'));
  assert.ok(strays.length >= 1, 'only a stray temp file remains, never the final file');

  // A clean rerun completes the export atomically at the final path with 0600.
  const reopened = new PgliteLocalStore({ fmHome });
  await runVerb(['export-snapshot', '--out', outPath, '--data-dir', reopened.dataDir], { env: { ...process.env } });
  assert.equal(fs.existsSync(outPath), true, 'the rerun produced the final file');
  assert.equal(fs.statSync(outPath).mode & 0o777, 0o600, 'owner-only 0600');
});

test('t_full_lifecycle_integration_gate', async () => {
  // The cumulative integration gate (spec 895-901): the whole canonical chain end to end.
  //   create-task -> begin-run -> marker-bound spawn -> record-spawn -> commit-running ->
  //   progress -> complete -> next -> claim-delivery -> sink effect -> mark-applied -> ack
  //   -> cleanup-intent -> cleanup effect -> cleanup-finish -> [archive] -> snapshot -> project
  const { store, fmHome } = await freshStore();
  const inbox = fixtureInbox([{ id: 'ORD-1', text: 'ship it' }]);

  await createTask(store, { taskId: 't1', kind: 'ship', title: 'Ship', origin: 'captain_order', orderRef: 'ORD-1', commandId: 'g-create' });
  const beg = await beginRun(store, { taskId: 't1', expectedRevision: 1, commandId: 'g-begin' });
  const rs = await recordSpawn(store, {
    taskId: 't1', generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: 'g-spawn'
  }, { captureIdentity: captureOk });
  const cr = await commitRunning(store, { taskId: 't1', generation: 1, expectedRevision: rs.revision, commandId: 'g-run' }, { probeIdentity: probeMatch });

  const pr = await appendEvent(store, {
    taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1,
    expectedRevision: cr.revision, commandId: 'g-progress'
  });
  let rev = typeof pr.revision === 'number' ? pr.revision : cr.revision;
  const done = await completeRun(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 2, evidence: {}, commandId: 'g-complete'
  });
  rev = done.revision;

  // next -> claim-delivery -> sink effect -> mark-applied -> ack, driven by the real
  // FirstMate consumer against a real idempotent file-ledger sink.
  const sink = new FileLedgerSink({ dir: mkTempDir('cp-s6-sink-') });
  const consumer = new FirstMateConsumer(store, { bootId: 'boot-g', pid: 2000, sink });
  await consumer.claim();
  const summary = await consumer.drainUntilIdle();
  assert.equal(summary.idle, true, 'the consumer drained the terminal delivery to idle');
  const cursor = await readCursor(store);
  assert.ok(cursor.last_acked_outbox_id > 0, 'the ack cursor advanced past the delivered rows');

  // cleanup-intent -> cleanup effect -> cleanup-finish.
  const ci = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'g-ci' });
  rev = ci.revision;
  const cf = await cleanupFinish(store, {
    taskId: 't1', generation: 1, expectedRevision: rev, effectResult: { confirmed_absent: true }, commandId: 'g-cf'
  });
  rev = cf.revision;

  // archive (spec 899) is cp-archive-a1, a SIBLING task. Q3 ruling: use `cp archive` IF
  // the verb exists at test time, else run the chain WITHOUT it and RECORD the gap
  // explicitly (never silently skip). In this isolated S6 branch the verb is absent, so
  // the gate exercises the chain through cleanup-finish and the S6 snapshot/project tail,
  // and the sibling lands archive to close the gap.
  const archiveExists = await archiveVerbExists();
  if (archiveExists) {
    await runVerb(['archive', 't1', '--expected-revision', String(rev), '--command-id', 'g-archive', '--data-dir', store.dataDir], { env: { ...process.env } });
  }

  // snapshot -> project (the S6 tail; always runs).
  const snap = await createSnapshot(store, { orderSourcePath: inbox });
  const bridge = projectBridge(await getSnapshot(store, {}));
  const helm = projectHelm(await getSnapshot(store, {}));

  const card = bridge.cards.find((c) => c.task_id === 't1');
  assert.ok(card, 'the task surfaces as a Bridge card built from the snapshot');
  assert.equal(card.projection_revision, snap.projection_revision, 'the card cites the projection revision');
  assert.equal(card.checksum, snap.checksum, 'the card cites the checksum');
  assert.ok(snap.order_source_bytes > 0, 'the captured order prefix folded into the snapshot');

  if (archiveExists) {
    assert.equal(card.status, 'archived', 'ARCHIVE PRESENT: the gate ran the full chain and the task is archived');
    // eslint-disable-next-line no-console
    console.log('# integration-gate: exercised the REAL cp archive (cp-archive-a1 landed); full spec-895-901 chain create-task..archive -> snapshot -> project green');
  } else {
    // KNOWN GAP, recorded not skipped: the archive step is owned by cp-archive-a1. The
    // chain ran through cleanup-finish; the task rests at 'completed' with cleanup done.
    assert.equal(card.status, 'completed', 'ARCHIVE GAP (cp-archive-a1): task rests at completed after cleanup-finish');
    // eslint-disable-next-line no-console
    console.log('# integration-gate known gap: archive step deferred to cp-archive-a1 (spec 899); chain ran create-task..cleanup-finish + snapshot/project');
  }

  // A cleanly-cleaned run is neither a live pane nor an orphan pane.
  assert.ok(!helm.live.some((p) => p.task_id === 't1'), 'a cleaned run is not a live Helm pane');
  assert.ok(!helm.orphan_inspector.some((o) => o.task_id === 't1'), 'a cleanly-cleaned run is not an orphan');
  void fmHome;
});

// Probe whether the `cp archive` verb (cp-archive-a1) is registered, WITHOUT side
// effects: an unknown verb throws the S0 "unknown or not-yet-implemented verb" error
// before any store work; a registered verb fails later (missing data dir / args), which
// is a different error and means the verb exists.
async function archiveVerbExists() {
  try {
    await runVerb(['archive'], { env: {} });
    return true;
  } catch (err) {
    return !/unknown or not-yet-implemented verb/.test(err.message);
  }
}
