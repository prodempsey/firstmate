import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { runVerb } from '../lib/coordinator.mjs';
import { createTask, beginRun, appendEvent } from '../lib/domain-store.mjs';
import { recordSpawn, commitRunning, verifyRunning, cleanupIntent, cleanupFinish } from '../lib/domain-store-s3.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import { readCursor } from '../lib/domain-store-s4.mjs';
import { archiveTask } from '../lib/domain-store-archive.mjs';
import { killExactPane, tmuxListPane } from '../lib/tmux-adapter.mjs';
import { listAnomalies } from '../lib/domain-store-s5.mjs';
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

// The cumulative integration gate (finding-2 rebuild) drives a REAL marker-bound lifecycle
// on an ISOLATED `tmux -L <socket>` namespace via the production launcher/probes/cleanup,
// exactly as the S3/S5 smokes do, and SKIPS when tmux is absent. No fabricated identities.
const hasTmux = (() => {
  try {
    return spawnSync('tmux', ['-V'], { encoding: 'utf8' }).status === 0;
  } catch {
    return false;
  }
})();
let socketCounter = 0;
function isolatedSocket() {
  socketCounter += 1;
  return `cp-s6-gate-${process.pid}-${socketCounter}`;
}
function tmux(socket, args) {
  return spawnSync('tmux', ['-L', socket, ...args], { encoding: 'utf8' });
}
function killSocket(socket) {
  tmux(socket, ['kill-server']);
  try {
    const sockDir = process.env.TMUX_TMPDIR || `/tmp/tmux-${process.getuid()}`;
    fs.unlinkSync(path.join(sockDir, socket));
  } catch {
    // best effort: kill-server usually removes it already
  }
}
function waitFor(predicate, { tries = 200, stepMs = 25 } = {}) {
  for (let i = 0; i < tries; i += 1) {
    if (predicate()) return true;
    spawnSync('sleep', [String(stepMs / 1000)]);
  }
  return predicate();
}
function readCmdlineStr(pid) {
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`).toString('latin1').replace(/\0/g, ' ').trim();
  } catch {
    return null;
  }
}
const cpLaunchSh = fileURLToPath(new URL('../bin/cp-launch.sh', import.meta.url));

// Launch a REAL marker-bearing pane on the isolated socket (cp-launch.sh EXECs the harness
// in place, PID preserved), then drive record-spawn (real capture) and commit-running (real
// probe) to a verified running binding. Same shape as s3-smoke's launchToRunning.
async function launchToRunning(store, socket, fmHome, taskId, harnessArgv = ['sleep', '300']) {
  const regFile = path.join(fmHome, `${taskId}.reg`);
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}`, registrationPath: regFile });
  const env = [
    `CP_LAUNCH_MARKER=${beg.launch_marker}`, `CP_TASK_ID=${taskId}`, 'CP_RUN_GENERATION=1',
    `CP_BIND_NONCE=${beg.bind_nonce}`, `CP_REG_FILE=${regFile}`
  ].join(' ');
  const winName = `cp-${beg.launch_marker.slice(0, 8)}`;
  const paneCmd = `${env} exec sh ${cpLaunchSh} ${harnessArgv.join(' ')}`;
  const created = tmux(socket, ['new-session', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-s', `cp-${taskId}`, '-n', winName, paneCmd]);
  assert.equal(created.status, 0, `tmux new-session failed: ${created.stderr}`);
  const [endpointId, paneId] = created.stdout.trim().split(/\s+/);
  assert.equal(waitFor(() => fs.existsSync(regFile)), true, 'cp-launch wrote the registration record');
  const reg = JSON.parse(fs.readFileSync(regFile, 'utf8'));
  assert.equal(
    waitFor(() => { const cl = readCmdlineStr(reg.agentPid); return cl !== null && !cl.includes('cp-launch'); }),
    true, 'the registered PID exec\'d into the harness'
  );
  assert.equal(waitFor(() => tmuxListPane(socket, endpointId, paneId).listed), true, 'tmux lists the marker-bearing pane');
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: endpointId, pane: paneId, regFile, commandId: `c-spawn-${taskId}`
  });
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: `c-run-${taskId}` });
  return { endpointId, paneId, regFile, reg, revision: cr.revision };
}

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

test('t_snapshot_prefix_capture_serialized_no_revision_regression', async () => {
  // FINDING-1 regression (qa-s6-q72): a NEWER projection_revision must never carry an
  // OLDER order prefix than an earlier one under an append-only source. The reproduction
  // is the exact two-caller ordered inversion:
  //   1. Caller A reads a one-order prefix and PAUSES (afterReadHook).
  //   2. A second order is appended.
  //   3. Caller B captures both orders and commits.
  //   4. Caller A is released and commits.
  // On the buggy (capture-before-lock) build, B commits revision 1 with two orders while A
  // is paused, then A commits revision 2 with only ONE order - a later revision with fewer
  // order bytes. With the fix (capture INSIDE the exclusive transaction) A holds the flock
  // across its pause, so B cannot commit ahead of A; whoever commits later saw the append,
  // and order bytes are monotonic with revision.
  const { store, fmHome } = await freshStore();
  const inbox = fixtureInbox([{ id: 'ORD-1' }]);
  await store.close(); // the children own the flock; close the setup store first
  const dir = mkTempDir('cp-s6-sync-');
  const pauseFile = path.join(dir, 'pauseA');
  const releaseFile = path.join(dir, 'releaseA');
  const bDoneFile = path.join(dir, 'bDone');

  // Caller A: reads the one-order prefix, then pauses (holding the flock, with the fix).
  const aPromise = runWorker(SNAP_WORKER, {
    ...process.env, CP_FM_HOME: fmHome, CP_ORDER_SOURCE: inbox, CP_MODE: 'pause-after-read',
    CP_PAUSE_FILE: pauseFile, CP_RELEASE_FILE: releaseFile
  });

  // Wait until A has read its prefix and paused.
  for (let i = 0; i < 400 && !fs.existsSync(pauseFile); i += 1) await new Promise((r) => setTimeout(r, 25));
  assert.ok(fs.existsSync(pauseFile), 'caller A read its prefix and paused');

  // Append a second order while A is paused.
  fs.appendFileSync(inbox, JSON.stringify({ id: 'ORD-2' }) + '\n');

  // Caller B captures the two-order prefix. On the fixed build it BLOCKS on the flock A
  // holds; on the buggy build it commits immediately (touching bDone).
  const bPromise = runWorker(SNAP_WORKER, {
    ...process.env, CP_FM_HOME: fmHome, CP_ORDER_SOURCE: inbox, CP_MODE: 'plain', CP_DONE_FILE: bDoneFile
  });

  // Give B a bounded window to commit ahead of A (the buggy path). On the fixed build B is
  // blocked and this simply times out, which is fine.
  for (let i = 0; i < 120 && !fs.existsSync(bDoneFile); i += 1) await new Promise((r) => setTimeout(r, 25));

  // Release A so it commits; then let both finish.
  fs.writeFileSync(releaseFile, 'go');
  const [a, b] = await Promise.all([aPromise, bPromise]);
  assert.equal(a.status, 0, `caller A exited clean (stderr: ${a.stderr})`);
  assert.equal(b.status, 0, `caller B exited clean (stderr: ${b.stderr})`);
  const ra = JSON.parse(a.stdout);
  const rb = JSON.parse(b.stdout);

  // The core invariant: order the two snapshots by projection_revision; the LATER revision
  // must carry >= the order bytes of the earlier one. The buggy build produces a later
  // revision with FEWER order bytes and trips this.
  const [earlier, later] = [ra, rb].sort((x, y) => x.projection_revision - y.projection_revision);
  assert.ok(
    later.order_source_bytes >= earlier.order_source_bytes,
    `later revision ${later.projection_revision} (${later.order_source_bytes}B) must not regress earlier ` +
      `revision ${earlier.projection_revision} (${earlier.order_source_bytes}B)`
  );

  // And the store agrees: no snapshot row has a higher projection_revision but fewer order
  // bytes than a lower one.
  const reopened = new PgliteLocalStore({ fmHome });
  const snaps = await rows(reopened, 'SELECT projection_revision, order_source_bytes FROM snapshots ORDER BY projection_revision');
  for (let i = 1; i < snaps.length; i += 1) {
    assert.ok(
      Number(snaps[i].order_source_bytes) >= Number(snaps[i - 1].order_source_bytes),
      'order_source_bytes is monotonic non-decreasing with projection_revision'
    );
  }
  assert.ok(snaps.length >= 1, 'at least one snapshot was committed');
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

test('t_full_lifecycle_integration_gate', { skip: hasTmux ? false : 'tmux not available' }, async () => {
  // FINDING-2 REBUILD (qa-s6-q72): the cumulative integration gate (spec 895-901) as a REAL
  // end-to-end marker-bound lifecycle - no fabricated identities, no fabricated cleanup:
  //   create-task -> begin-run -> MARKER-BOUND spawn (cp-launch.sh) -> record-spawn (real
  //   /proc capture) -> commit-running (real probe) -> progress -> complete -> next ->
  //   claim-delivery -> REAL sink effect -> mark-applied -> ack -> cleanup-intent -> REAL
  //   adapter cleanup effect (killExactPane) -> cleanup-finish -> archive (real cp archive)
  //   -> snapshot -> project bridge|helm.
  // It runs on an ISOLATED tmux socket and a real marker-bearing stub process, and SKIPS
  // when tmux is absent (like the S3/S5 smokes). Final assertions are direct DB + process
  // truths: zero unacked rows, zero active anomalies, archived task, cleaned/closed run,
  // matching Bridge/Helm revision+checksum, and the exact fixture pane provably gone.
  const { fmHome } = mkFixtureHome();
  const socket = isolatedSocket();
  const store = new PgliteLocalStore({ fmHome });
  await store.init({ homeLabel: 'gate' });
  process.env.CP_TMUX_SOCKET = socket;
  const inbox = fixtureInbox([{ id: 'ORD-1', text: 'ship it' }]);
  try {
    // create-task -> begin-run -> marker-bound spawn -> record-spawn -> commit-running.
    await createTask(store, { taskId: 't1', kind: 'ship', title: 'Ship', origin: 'captain_order', orderRef: 'ORD-1', commandId: 'g-create' });
    const h = await launchToRunning(store, socket, fmHome, 't1');
    const vr = await verifyRunning(store, { taskId: 't1', generation: 1 });
    assert.equal(vr.running_verified, true, 'the real predicate confirms the running binding');

    // progress -> complete.
    const pr = await appendEvent(store, {
      taskId: 't1', generation: 1, eventType: 'progress', producer: 'crewmate', seq: 1,
      expectedRevision: h.revision, commandId: 'g-progress'
    });
    let rev = typeof pr.revision === 'number' ? pr.revision : h.revision;
    const done = await completeRun(store, {
      taskId: 't1', generation: 1, expectedRevision: rev, outcome: 'success', producer: 'crewmate', seq: 2, evidence: {}, commandId: 'g-complete'
    });
    rev = done.revision;

    // next -> claim-delivery -> REAL sink effect -> mark-applied -> ack (real consumer + sink).
    const sink = new FileLedgerSink({ dir: mkTempDir('cp-s6-sink-') });
    const consumer = new FirstMateConsumer(store, { bootId: 'boot-g', pid: 2000, sink });
    await consumer.claim();
    const summary = await consumer.drainUntilIdle();
    assert.equal(summary.idle, true, 'the consumer drained the terminal delivery to idle');

    // cleanup-intent -> REAL adapter cleanup effect (kills only the exact recorded pane) ->
    // cleanup-finish (records the real effect result, never a fabricated one).
    const intent = await cleanupIntent(store, { taskId: 't1', generation: 1, expectedRevision: rev, commandId: 'g-ci' });
    const effect = killExactPane({ socket, endpointId: intent.target.endpoint_id, paneId: intent.target.pane_id, run: intent.target });
    assert.equal(effect.killed, true, 'the real cleanup effect killed the exact recorded pane');
    assert.equal(effect.confirmed_absent, true, 'the real cleanup effect confirmed the pane is gone');
    assert.equal(waitFor(() => !tmuxListPane(socket, h.endpointId, h.paneId).listed), true, 'the exact fixture pane is gone');
    const fin = await cleanupFinish(store, { taskId: 't1', generation: 1, expectedRevision: intent.revision, effectResult: effect, commandId: 'g-cf' });
    assert.equal(fin.binding_state, 'closed', 'the binding closed after the real cleanup');
    rev = fin.revision;

    // archive (the REAL cp archive: terminal + acked terminal outbox + cleaned).
    const arch = await archiveTask(store, { taskId: 't1', expectedRevision: rev, commandId: 'g-archive' });
    assert.equal(arch.revision, rev + 1, 'the real archive committed the archived transition');

    // snapshot -> project bridge|helm.
    const snap = await createSnapshot(store, { orderSourcePath: inbox });
    const bridge = projectBridge(await getSnapshot(store, {}));
    const helm = projectHelm(await getSnapshot(store, {}));

    // ---- Direct end-state truth assertions (finding-2) ----
    // Bridge card cites the projection revision + checksum and shows the real end state.
    const card = bridge.cards.find((c) => c.task_id === 't1');
    assert.ok(card, 'the task surfaces as a Bridge card built from the snapshot');
    assert.equal(card.status, 'archived', 'the real chain drove the task all the way to archived');
    assert.equal(card.projection_revision, snap.projection_revision, 'the card cites the projection revision');
    assert.equal(card.checksum, snap.checksum, 'the card cites the checksum');
    assert.equal(helm.projection_revision, snap.projection_revision, 'Bridge and Helm share the projection revision');
    assert.equal(helm.checksum, snap.checksum, 'Bridge and Helm share the checksum');
    assert.ok(snap.order_source_bytes > 0, 'the captured order prefix folded into the snapshot');

    // Zero unacked outbox rows.
    const unacked = Number((await rows(store, 'SELECT count(*)::int AS n FROM outbox WHERE acked_at IS NULL'))[0].n);
    assert.equal(unacked, 0, 'no unacked outbox rows remain');
    const cursor = await readCursor(store);
    assert.ok(cursor.last_acked_outbox_id > 0, 'the ack cursor advanced past the delivered rows');

    // Zero active anomalies - a clean lifecycle produced no unexplained anomaly.
    const active = await listAnomalies(store, { activeOnly: true });
    assert.equal(active.anomalies.length, 0, 'a clean real lifecycle left zero active anomalies');

    // Archived task, cleaned/closed run - from the canonical rows.
    const t = (await rows(store, 'SELECT status FROM tasks WHERE task_id = $1', ['t1']))[0];
    assert.equal(t.status, 'archived', 'the task row is archived');
    const run = (await rows(store, 'SELECT cleanup_state, binding_state, closed_at FROM runs WHERE task_id = $1 AND run_generation = 1', ['t1']))[0];
    assert.equal(run.cleanup_state, 'cleaned', 'the run cleanup is cleaned');
    assert.equal(run.binding_state, 'closed', 'the binding is closed');
    assert.notEqual(run.closed_at, null, 'the run is closed');

    // The exact fixture process/pane is provably gone (no surviving spawned process/pane).
    assert.equal(tmuxListPane(socket, h.endpointId, h.paneId).listed, false, 'the fixture pane is gone from the socket');
    assert.equal(readCmdlineStr(h.reg.agentPid), null, 'the fixture agent process is gone');

    // A cleaned run is neither a live pane nor an orphan pane.
    assert.ok(!helm.live.some((p) => p.task_id === 't1'), 'a cleaned run is not a live Helm pane');
    assert.ok(!helm.orphan_inspector.some((o) => o.task_id === 't1'), 'a cleanly-cleaned run is not an orphan');
  } finally {
    killSocket(socket);
    delete process.env.CP_TMUX_SOCKET;
    await store.close();
  }
});
