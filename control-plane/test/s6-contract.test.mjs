import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createTask, beginRun, appendEvent, sha256hex } from '../lib/domain-store.mjs';
import { recordSpawn, commitRunning } from '../lib/domain-store-s3.mjs';
import { reconcileMarkLost, recordReconcilerAnomaly } from '../lib/domain-store-s5.mjs';
import { createSnapshot, getSnapshot } from '../lib/domain-store-s6.mjs';
import { acquireStableOrderPrefix } from '../lib/order-prefix.mjs';
import { projectBridge, projectHelm, buildExportEnvelope, verifyExportedSnapshot, exportSnapshot } from '../lib/projections.mjs';
import { SnapshotSourceError, SnapshotNotFoundError, SnapshotVerificationError } from '../lib/errors-s6.mjs';
import { mkFixtureHome, mkTempDir, cleanupAll } from './helpers.mjs';

// S6 owns snapshots, the stable order prefix, the Bridge/Helm projections, the orphan
// inspector, and the atomic export + reader verifier. Every snapshot is a PROJECTION of
// domain state, not a domain mutation: `cp snapshot` is the ONLY writer of
// projection_revision, it bumps projection_revision + commit_sequence and NEVER
// domain_revision or any tasks.revision, and its idempotent-return path bumps nothing.
// Projections read the snapshots table ONLY - never a live domain table. No test here
// uses a table or verb owned by a later slice.
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
  const r = await rows(
    store, 'SELECT domain_revision, projection_revision, commit_sequence FROM coordinator_state WHERE id = 1'
  );
  return { domain: Number(r[0].domain_revision), projection: Number(r[0].projection_revision), commit: Number(r[0].commit_sequence) };
}
async function snapshotCount(store) {
  const r = await rows(store, 'SELECT count(*)::int AS n FROM snapshots');
  return Number(r[0].n);
}

// An ISOLATED fixture inbox - NEVER the real captain inbox. Every order-prefix test
// writes and rotates one of these under a sandboxed temp dir.
function fixtureInbox(lines = []) {
  const dir = mkTempDir('cp-s6-inbox-');
  const p = path.join(dir, 'captain-orders.jsonl');
  fs.writeFileSync(p, lines.map((l) => (typeof l === 'string' ? l : JSON.stringify(l))).join('\n') + (lines.length ? '\n' : ''));
  return p;
}

// ---- lifecycle builders (same shapes S3/S5 tests use) ----
async function createTaskQueued(store, taskId, orderRef = null) {
  if (orderRef) {
    await createTask(store, { taskId, kind: 'ship', title: `T ${taskId}`, origin: 'captain_order', orderRef, commandId: `c-create-${taskId}` });
  } else {
    await createTask(store, { taskId, kind: 'ship', title: `T ${taskId}`, origin: 'internal', internalReason: 'r', commandId: `c-create-${taskId}` });
  }
}
async function runningTask(store, taskId) {
  await createTaskQueued(store, taskId);
  const beg = await beginRun(store, { taskId, expectedRevision: 1, commandId: `c-begin-${taskId}` });
  const rs = await recordSpawn(store, {
    taskId, generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: IDENTITY.endpointId, pane: IDENTITY.paneId, regFile: '/reg', commandId: `c-spawn-${taskId}`
  }, { captureIdentity: captureOk });
  const cr = await commitRunning(store, { taskId, generation: 1, expectedRevision: rs.revision, commandId: `c-run-${taskId}` }, { probeIdentity: probeMatch });
  return cr.revision;
}

// =====================================================================================
// Snapshot semantics
// =====================================================================================

test('t_snapshot_increments_projection_revision_only', async () => {
  const { store } = await freshStore();
  await createTaskQueued(store, 't1');
  const before = await counters(store);
  const taskRevBefore = Number((await rows(store, 'SELECT revision FROM tasks WHERE task_id = $1', ['t1']))[0].revision);
  assert.equal(before.projection, 0, 'projection_revision is 0 before any snapshot');

  const s = await createSnapshot(store, { orderSourcePath: fixtureInbox([{ id: 'ORD-1' }]) });
  assert.equal(s.deduped, false);
  assert.equal(s.projection_revision, 1);

  const after = await counters(store);
  assert.equal(after.projection, before.projection + 1, 'projection_revision +1');
  assert.equal(after.commit, before.commit + 1, 'commit_sequence +1');
  assert.equal(after.domain, before.domain, 'domain_revision UNTOUCHED (a snapshot is not a domain mutation)');

  // tasks.revision is untouched by a snapshot (a projection never mutates a domain row).
  const taskRevAfter = Number((await rows(store, 'SELECT revision FROM tasks WHERE task_id = $1', ['t1']))[0].revision);
  assert.equal(taskRevAfter, taskRevBefore, 'tasks.revision is untouched by the snapshot');
});

test('t_snapshot_idempotent_by_dedup_key', async () => {
  const { store } = await freshStore();
  await createTaskQueued(store, 't1');
  const inbox = fixtureInbox([{ id: 'ORD-1' }, { id: 'ORD-2' }]);

  const s1 = await createSnapshot(store, { orderSourcePath: inbox });
  const c1 = await counters(store);
  assert.equal(s1.deduped, false);

  // Re-snapshot over unchanged (domain_revision, order bytes, order hash, checksum):
  // the four-column dedup key matches the latest row -> return it, bump NOTHING.
  const s2 = await createSnapshot(store, { orderSourcePath: inbox });
  const c2 = await counters(store);
  assert.equal(s2.deduped, true, 'idempotent return');
  assert.equal(s2.projection_revision, s1.projection_revision, 'same revision');
  assert.equal(s2.checksum, s1.checksum, 'same checksum');
  assert.deepEqual(c2, c1, 'no counter moved on the idempotent return');
  assert.equal(await snapshotCount(store), 1, 'exactly one snapshot row');

  // A domain change (new task) breaks the dedup key -> a genuinely new snapshot.
  await createTaskQueued(store, 't2');
  const s3 = await createSnapshot(store, { orderSourcePath: inbox });
  assert.equal(s3.deduped, false);
  assert.equal(s3.projection_revision, s1.projection_revision + 1);
  assert.equal(await snapshotCount(store), 2);
});

// =====================================================================================
// Stable order prefix
// =====================================================================================

test('t_partial_inbox_line_truncated_to_prefix', async () => {
  // A complete record, then a partial final record with NO trailing newline. The prefix
  // is truncated to the last complete newline: the partial is rejected, excluded from
  // both the recorded byte count and the parsed records.
  const dir = mkTempDir('cp-s6-inbox-');
  const p = path.join(dir, 'orders.jsonl');
  const complete = JSON.stringify({ id: 'ORD-1', text: 'done' }) + '\n';
  const partial = '{"id":"ORD-2","text":"half-writ';
  fs.writeFileSync(p, complete + partial);

  const pre = await acquireStableOrderPrefix(p);
  assert.equal(pre.bytes, Buffer.byteLength(complete), 'recorded bytes stop at the last complete newline');
  assert.equal(pre.records.length, 1, 'only the complete record is parsed');
  assert.equal(pre.records[0].id, 'ORD-1');
  assert.equal(pre.hash, sha256hex(Buffer.from(complete)), 'hash covers exactly the complete prefix');

  // A file that is ONLY a partial line (no newline at all) -> empty stable prefix.
  const p2 = path.join(dir, 'orders2.jsonl');
  fs.writeFileSync(p2, '{"id":"ORD-9","partial":tru');
  const pre2 = await acquireStableOrderPrefix(p2);
  assert.equal(pre2.bytes, 0);
  assert.equal(pre2.records.length, 0);
  assert.equal(pre2.hash, sha256hex(Buffer.alloc(0)));
});

test('t_order_hash_covers_exact_recorded_bytes', async () => {
  const lines = [JSON.stringify({ id: 'ORD-1' }), JSON.stringify({ id: 'ORD-2' })];
  const body = lines.join('\n') + '\n';
  const p = fixtureInbox(lines);

  const pre = await acquireStableOrderPrefix(p);
  assert.equal(pre.bytes, Buffer.byteLength(body));
  assert.equal(pre.hash, sha256hex(Buffer.from(body)), 'hash is over exactly the recorded byte range');

  // Appending a partial (unterminated) record does NOT change the stable prefix or its
  // hash: the partial is excluded, so the hash is byte-identical to before.
  fs.appendFileSync(p, '{"id":"ORD-3","partial":');
  const pre2 = await acquireStableOrderPrefix(p);
  assert.equal(pre2.bytes, pre.bytes, 'partial append does not extend the stable prefix');
  assert.equal(pre2.hash, pre.hash, 'hash unchanged by an excluded partial');

  // Completing that record (adding the newline) DOES extend the prefix and change the hash.
  fs.appendFileSync(p, 'true}\n');
  const pre3 = await acquireStableOrderPrefix(p);
  assert.ok(pre3.bytes > pre.bytes, 'a completed record extends the stable prefix');
  assert.notEqual(pre3.hash, pre.hash, 'hash covers the newly-complete bytes');
  assert.equal(pre3.records.length, 3);
});

test('t_inbox_shrink_rotation_retries_then_errors', async () => {
  const p = fixtureInbox([{ id: 'ORD-1' }]);

  // Persistent rotation: every re-stat reports a DIFFERENT inode, so the prefix never
  // stabilizes. After the bounded retry budget the protocol fails LOUD rather than
  // hashing a torn range.
  let ino = 100;
  const rotatingStat = () => ({ dev: 1, ino: (ino += 1), size: 20 });
  await assert.rejects(
    () => acquireStableOrderPrefix(p, { maxRetries: 4, statFile: rotatingStat, openRead: (fp) => fs.openSync(fp, 'r') }),
    (err) => {
      assert.ok(err instanceof SnapshotSourceError);
      assert.equal(err.code, 'snapshot_source');
      assert.equal(err.detail.max_retries, 4);
      return true;
    }
  );

  // Persistent shrink: every re-stat reports a smaller size than the read range.
  let sz = 100;
  const shrinkingStat = () => ({ dev: 1, ino: 7, size: (sz -= 10) });
  await assert.rejects(
    () => acquireStableOrderPrefix(p, {
      maxRetries: 3,
      statFile: (() => { let first = true; return () => { if (first) { first = false; return { dev: 1, ino: 7, size: 200 }; } return shrinkingStat(); }; })(),
      openRead: (fp) => fs.openSync(fp, 'r')
    }),
    SnapshotSourceError
  );

  // An unreadable (permission-denied style) inbox is also a loud SnapshotSourceError.
  await assert.rejects(
    () => acquireStableOrderPrefix(p, { statFile: () => { const e = new Error('EACCES'); e.code = 'EACCES'; throw e; } }),
    SnapshotSourceError
  );
});

// =====================================================================================
// Bridge / Helm / orphan inspector projections
// =====================================================================================

test('t_project_bridge_one_card_per_task_cites_revision_checksum', async () => {
  const { store } = await freshStore();
  await createTaskQueued(store, 't1', 'ORD-1');
  await createTaskQueued(store, 't2');
  await runningTask(store, 't3');
  const s = await createSnapshot(store, { orderSourcePath: fixtureInbox([{ id: 'ORD-1' }]) });

  const snap = await getSnapshot(store, {});
  const bridge = projectBridge(snap);
  assert.equal(bridge.cards.length, 3, 'exactly one card per canonical task row');
  const ids = bridge.cards.map((c) => c.task_id).sort();
  assert.deepEqual(ids, ['t1', 't2', 't3']);
  for (const card of bridge.cards) {
    assert.equal(card.projection_revision, s.projection_revision, 'every card cites the projection revision');
    assert.equal(card.checksum, s.checksum, 'every card cites the checksum');
    assert.ok(typeof card.status === 'string', 'status is straight from tasks.status');
  }
  assert.equal(bridge.cards.find((c) => c.task_id === 't3').status, 'running');
});

test('t_project_helm_live_iff_bound_verified', async () => {
  const { store } = await freshStore();
  await runningTask(store, 't-live'); // bound_verified
  // A spawning-with-endpoint run: recorded endpoint but binding NOT bound_verified.
  await createTaskQueued(store, 't-spawn');
  const beg = await beginRun(store, { taskId: 't-spawn', expectedRevision: 1, commandId: 'c-begin-spawn' });
  await recordSpawn(store, {
    taskId: 't-spawn', generation: 1, expectedRevision: beg.revision, launchMarker: beg.launch_marker,
    endpoint: '@1', pane: '%1', regFile: '/reg', commandId: 'c-spawn-spawn'
  }, { captureIdentity: captureOk });

  await createSnapshot(store, { orderSourcePath: fixtureInbox([]) });
  const helm = projectHelm(await getSnapshot(store, {}));

  const liveIds = helm.live.map((p) => p.task_id);
  assert.deepEqual(liveIds, ['t-live'], 'live contains ONLY the bound_verified pane');
  assert.ok(helm.live.every((p) => p.binding_state === 'bound_verified'), 'live iff bound_verified');
  // The spawning-with-endpoint pane is retained (endpoint present, not verified, not lost),
  // and it is NOT live and NOT orphan.
  assert.ok(helm.retained.some((p) => p.task_id === 't-spawn'), 'unverified endpoint pane is retained');
  assert.ok(!helm.orphan_inspector.some((p) => p.task_id === 't-spawn'), 'unverified is not an orphan');
});

test('t_project_helm_retained_live_not_orphan', async () => {
  const { store } = await freshStore();
  const rev = await runningTask(store, 't1'); // running + bound_verified
  // Transition running -> blocked. Binding is RETAINED (still bound_verified).
  await appendEvent(store, {
    taskId: 't1', generation: 1, eventType: 'blocked', producer: 'crewmate', seq: 1,
    expectedRevision: rev, commandId: 'c-block-t1'
  });

  await createSnapshot(store, { orderSourcePath: fixtureInbox([]) });
  const helm = projectHelm(await getSnapshot(store, {}));

  const pane = helm.live.find((p) => p.task_id === 't1');
  assert.ok(pane, 'a blocked task with a verified process is retained-live, in the live set');
  assert.equal(pane.task_status, 'blocked', 'task status is blocked...');
  assert.equal(pane.binding_state, 'bound_verified', '...but the process is still verified');
  assert.ok(!helm.orphan_inspector.some((p) => p.task_id === 't1'), 'retained-live is NOT in the orphan inspector');
});

test('t_orphan_inspector_only_for_mismatched', async () => {
  const { store } = await freshStore();
  // A bound_verified pane (must NOT appear in the orphan inspector).
  await runningTask(store, 't-ok');
  // An identity-mismatched pane: a running run whose binding the reconciler marked 'lost'
  // while it still holds a recorded endpoint.
  const rev = await runningTask(store, 't-lost');
  await reconcileMarkLost(store, {
    taskId: 't-lost', generation: 1, expectedRevision: rev, failingClause: 'agent_pid',
    commandId: 'c-lost-t-lost'
  });
  // A shell-only / markerless orphan pane observed by the reconciler (an anomaly, no run).
  await recordReconcilerAnomaly(store, {
    anomalyClass: 'orphan_pane', endpointId: '@99', paneId: '%99',
    detail: { note: 'markerless shell' }, commandId: 'c-orphan-anom'
  });

  await createSnapshot(store, { orderSourcePath: fixtureInbox([]) });
  const helm = projectHelm(await getSnapshot(store, {}));

  const orphanTaskIds = helm.orphan_inspector.filter((o) => o.source === 'run').map((o) => o.task_id);
  assert.deepEqual(orphanTaskIds, ['t-lost'], 'only the identity-mismatched (lost) pane is a run-orphan');
  assert.ok(helm.orphan_inspector.some((o) => o.source === 'anomaly' && o.reason === 'shell_only_or_markerless'),
    'the markerless orphan_pane anomaly is a shell-only orphan');
  // The bound_verified pane is live and never an orphan.
  assert.ok(helm.live.some((p) => p.task_id === 't-ok'));
  assert.ok(!helm.orphan_inspector.some((o) => o.task_id === 't-ok'), 'a bound_verified pane never appears in the orphan inspector');
});

test('t_project_reads_snapshots_only', async () => {
  // Mutation-sensitive: point a projection at a fabricated domain row that was inserted
  // AFTER the snapshot. Because projections read the snapshots table ONLY, the fabricated
  // row must NOT appear - the projection can only surface captured state.
  const { store } = await freshStore();
  await createTaskQueued(store, 't-captured');
  const s = await createSnapshot(store, { orderSourcePath: fixtureInbox([]) });

  // Fabricate a task row directly, bypassing the snapshot entirely.
  await runExclusive(store, async (conn) => {
    await conn.query(
      `INSERT INTO tasks (task_id, home_uuid, kind, title, task_origin, internal_reason, status, created_at, updated_at)
         SELECT 't-ghost', home_uuid, 'ship', 'ghost', 'internal', 'fabricated', 'queued', now(), now()
           FROM tasks WHERE task_id = 't-captured'`
    );
  });

  const bridge = projectBridge(await getSnapshot(store, { revision: s.projection_revision }));
  const ids = bridge.cards.map((c) => c.task_id);
  assert.ok(ids.includes('t-captured'), 'the captured task appears');
  assert.ok(!ids.includes('t-ghost'), 'the fabricated post-snapshot row does NOT appear (projections read snapshots only)');
});

// =====================================================================================
// Export + reader verifier
// =====================================================================================

test('t_export_snapshot_atomic_and_owner_only', async () => {
  const { store } = await freshStore();
  await createTaskQueued(store, 't1');
  const s = await createSnapshot(store, { orderSourcePath: fixtureInbox([{ id: 'ORD-1' }]) });

  const outDir = mkTempDir('cp-s6-export-');
  const outPath = path.join(outDir, 'nested', 'snap.json'); // nested -> parent created 0700
  const res = await exportSnapshot(store, { outPath });
  assert.equal(res.projection_revision, s.projection_revision);

  const fileMode = fs.statSync(outPath).mode & 0o777;
  assert.equal(fileMode, 0o600, 'exported file is owner-only 0600 regardless of umask');
  const parentMode = fs.statSync(path.dirname(outPath)).mode & 0o777;
  assert.equal(parentMode, 0o700, 'a created parent dir is owner-only 0700');

  // The written file round-trips through the verifier and reproduces the checksum.
  const env = JSON.parse(fs.readFileSync(outPath, 'utf8'));
  assert.equal(env.checksum, s.checksum);
  assert.deepEqual(verifyExportedSnapshot(env, { expectedSourcePath: env.order_source_path, minRevision: 1 }), {
    ok: true, projection_revision: s.projection_revision, checksum: s.checksum
  });

  // No leftover temp file at the final path's sibling.
  const stray = fs.readdirSync(path.dirname(outPath)).filter((f) => f.includes('.tmp.'));
  assert.equal(stray.length, 0, 'no temp file remains after a clean export');
});

test('t_export_reader_rejects_checksum_revision_path_mismatch', async () => {
  const { store } = await freshStore();
  await createTaskQueued(store, 't1');
  await createSnapshot(store, { orderSourcePath: fixtureInbox([{ id: 'ORD-1' }]) });
  const snap = await getSnapshot(store, {});
  const good = buildExportEnvelope(snap);

  // A clean envelope verifies.
  verifyExportedSnapshot(good, { expectedSourcePath: good.order_source_path, minRevision: 1 });

  // 1) Checksum mismatch: tamper the payload without fixing the recorded checksum.
  const tampered = { ...good, payload: { ...good.payload, tasks: [{ task_id: 'INJECTED' }] } };
  assert.throws(() => verifyExportedSnapshot(tampered, {}), (e) => e instanceof SnapshotVerificationError && /checksum mismatch/.test(e.message));

  // 2) Revision regression: the envelope's revision is below the reader's last-seen.
  assert.throws(
    () => verifyExportedSnapshot(good, { minRevision: good.projection_revision + 5 }),
    (e) => e instanceof SnapshotVerificationError && /revision regress/.test(e.message)
  );

  // 3) Source path mismatch: a foreign home's inbox path.
  assert.throws(
    () => verifyExportedSnapshot(good, { expectedSourcePath: '/some/other/home/inbox.jsonl' }),
    (e) => e instanceof SnapshotVerificationError && /source path mismatch/.test(e.message)
  );
});

// =====================================================================================
// Revision addressing (Q6) and the seam invariant
// =====================================================================================

test('t_project_absent_revision_is_typed_not_found_never_latest', async () => {
  const { store } = await freshStore();
  await createTaskQueued(store, 't1');
  const s1 = await createSnapshot(store, { orderSourcePath: fixtureInbox([{ id: 'ORD-1' }]) });
  await createTaskQueued(store, 't2');
  const s2 = await createSnapshot(store, { orderSourcePath: fixtureInbox([{ id: 'ORD-1' }]) });
  assert.equal(s2.projection_revision, s1.projection_revision + 1);

  // A requested revision that was never taken is a typed not-found, NOT a silent latest.
  await assert.rejects(
    () => getSnapshot(store, { revision: 999 }),
    (e) => e instanceof SnapshotNotFoundError && e.detail.requested_revision === 999
  );
  // Omitted revision -> the latest (the natural default), not an error.
  const latest = await getSnapshot(store, {});
  assert.equal(latest.projection_revision, s2.projection_revision);

  // A fresh store with NO snapshots: latest is a typed not-found (never a fabricated empty).
  const { store: empty } = await freshStore();
  await assert.rejects(() => getSnapshot(empty, {}), SnapshotNotFoundError);
});

test('t_prior_slices_projection_revision_still_zero', async () => {
  // The S6 seam invariant, re-asserted here: a full S1->S3->S5 lifecycle moves
  // domain_revision and commit_sequence and tasks.revision, but leaves
  // projection_revision at 0 until (and unless) `cp snapshot` runs. This is exactly what
  // every S1-S5 mutation-sensitive suite asserts; S6 must not have disturbed it.
  const { store } = await freshStore();
  await runningTask(store, 't1'); // create-task, begin-run, record-spawn, commit-running
  const rev = await runningTask(store, 't2');
  await reconcileMarkLost(store, { taskId: 't2', generation: 1, expectedRevision: rev, failingClause: 'agent_pid', commandId: 'c-lost-t2' });
  await recordReconcilerAnomaly(store, { anomalyClass: 'orphan_pane', endpointId: '@x', paneId: '%x', detail: {}, commandId: 'c-anom' });

  const c = await counters(store);
  assert.ok(c.domain > 0, 'domain_revision advanced across the lifecycle');
  assert.ok(c.commit > 0, 'commit_sequence advanced across the lifecycle');
  assert.equal(c.projection, 0, 'projection_revision is STILL 0 with no snapshot taken');

  // Now one snapshot moves projection_revision to 1 and nothing else regresses.
  await createSnapshot(store, { orderSourcePath: fixtureInbox([]) });
  const c2 = await counters(store);
  assert.equal(c2.projection, 1);
  assert.equal(c2.domain, c.domain, 'the snapshot did not move domain_revision');
});
