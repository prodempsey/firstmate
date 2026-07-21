import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PgliteLocalStore } from '../lib/pglite-local-store.mjs';
import { runExclusive } from '../lib/internal-runtime.mjs';
import { createSnapshot, getSnapshot } from '../lib/domain-store-s6.mjs';
import { listAnomalies } from '../lib/domain-store-s5.mjs';
import { projectBridge, projectHelm } from '../lib/projections.mjs';
import { acquireStableOrderPrefix } from '../lib/order-prefix.mjs';
import { writeInbox, ordRecord } from './fixtures/inbox.mjs';
import { hasTmux, scanPanes, killSocket } from './fixtures/agent.mjs';
import { runProjectionConsumer, boardCardIds } from './fixtures/board.mjs';
import { cursorOf } from './fixtures/consumer.mjs';
import { isAlive, killExactPid } from './fixtures/proc.mjs';

// The disposable E2E harness runner (spec section 11). One Harness instance owns ONE fully
// isolated fixture world for ONE workflow: a fresh temp fixture root, an isolated FM-home,
// an isolated order inbox with a real ORD reference, an isolated PGlite dataDir, an
// isolated worktree/scratch dir, an isolated Bridge/Helm board, a durable reference sink,
// and a DEDICATED tmux socket on a contained TMUX_TMPDIR (never the default or fm-maint
// socket). It records every child PID it spawns so teardown kills ONLY exact recorded PIDs
// and the dedicated socket - never a pattern, never a name match. It encodes the global
// final assertions once and runs them after every workflow, and the finals are themselves
// mutation-checked (a broken input must make them FAIL).

const CP_MJS = fileURLToPath(new URL('../bin/cp.mjs', import.meta.url));
let socketCounter = 0;

export class Harness {
  #store = null;

  constructor({ label = 'wf', tmuxRequired = false } = {}) {
    this.label = label;
    this.tmuxRequired = tmuxRequired;
    this.hasTmux = hasTmux();
    // agents: { pid, marker, endpointId, paneId, alive } - live marker-bearing panes.
    // children: { pid, kind } - short-lived recorded child procs, expected dead by finals.
    this.agents = [];
    this.children = [];
    this.keepalives = [];
    this.torndown = false;
  }

  get store() { return this.#store; }
  get dataDir() { return this._dataDir; }
  get fmHome() { return this._fmHome; }
  get inbox() { return this._inbox; }
  get worktree() { return this._worktree; }
  get socket() { return this._socket; }
  get sinkDir() { return this._sinkDir; }
  get boardDir() { return this._boardDir; }

  // Create the isolated fixture world and assert nothing escapes it, then open the store.
  async setup({ inboxOrders = [ordRecord(1)] } = {}) {
    this._root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'cp-s7-')));
    this._fmHome = path.join(this._root, 'home');
    this._dataDir = path.join(this._fmHome, 'state', 'control-plane', 'pgdata');
    this._inbox = path.join(this._fmHome, 'orders', 'captain-orders.jsonl');
    this._worktree = path.join(this._root, 'worktree');
    this._sinkDir = path.join(this._root, 'sink');
    this._boardDir = path.join(this._root, 'board');
    this._tmuxTmpDir = path.join(this._root, 'tmux');
    for (const d of [this._fmHome, this._worktree, this._sinkDir, this._boardDir, this._tmuxTmpDir, path.dirname(this._inbox)]) {
      fs.mkdirSync(d, { recursive: true });
    }
    this.#assertContained();

    // The dedicated socket and its contained socket dir. Setting TMUX_TMPDIR under the
    // fixture root means even the socket FILE never lands in a shared location.
    socketCounter += 1;
    this._socket = `cp-s7-${process.pid}-${socketCounter}`;
    process.env.TMUX_TMPDIR = this._tmuxTmpDir;
    process.env.CP_TMUX_SOCKET = this._socket;

    writeInbox(this._inbox, inboxOrders);
    this.#store = new PgliteLocalStore({ fmHome: this._fmHome });
    await this.#store.init({ homeLabel: this.label });
    return this;
  }

  // No resolved fixture path may escape the fixture root, and the root must be under the OS
  // temp dir - the spec's "refuse if any resolved path escapes the fixture root; no
  // production-writable paths". This is a fail-CLOSED backstop behind the mkdtemp guarantee.
  #assertContained() {
    const root = this._root;
    if (!root.startsWith(fs.realpathSync(os.tmpdir()) + path.sep)) {
      throw new Error(`fixture root escapes the OS temp dir: ${root}`);
    }
    for (const [name, p] of Object.entries({
      fmHome: this._fmHome, dataDir: this._dataDir, inbox: this._inbox,
      worktree: this._worktree, sink: this._sinkDir, board: this._boardDir, tmux: this._tmuxTmpDir
    })) {
      const resolved = path.resolve(p);
      if (resolved !== root && !resolved.startsWith(root + path.sep)) {
        throw new Error(`fixture path ${name} escapes the fixture root: ${resolved} !< ${root}`);
      }
    }
  }

  // ---- PID registry ---------------------------------------------------------------

  recordAgent(agent) { this.agents.push({ ...agent, alive: true }); return agent; }
  recordChild(pid, kind) { if (Number.isInteger(pid)) this.children.push({ pid, kind }); return pid; }
  // A fixture process the workflow INTENTIONALLY keeps alive through the finals (e.g. the
  // shell-only markerless orphan pane, which this slice never kills). It is reclaimed by
  // exact PID at teardown but is not a leak, so the finals' zero-orphan-process check
  // excludes it - only the anomaly it produces is asserted.
  recordKeepalive(pid, kind) { if (Number.isInteger(pid)) this.keepalives.push({ pid, kind }); return pid; }
  // Mark an agent the workflow intentionally killed (wf4/wf7) so the finals expect it dead
  // and its marker is no longer "recorded-live".
  markAgentDead(pid) { for (const a of this.agents) if (a.pid === pid) a.alive = false; }
  liveAgentMarkers() { return new Set(this.agents.filter((a) => a.alive).map((a) => a.marker)); }

  // Fail-CLOSED kill authority (ratified ruling Q3): a kill target must be proven
  // fixture-recorded IMMEDIATELY before the signal, in the kill primitive itself - never a
  // raw integer PID trusted by a caller. A future wiring error that passed an unrecorded PID
  // would throw here rather than signalling a stranger's process.
  killRecordedAgent(pid) {
    if (!this.agents.some((a) => a.pid === pid)) throw new Error(`refusing to kill unrecorded agent PID ${pid} (not in the fixture registry)`);
    killExactPid(pid);
    this.markAgentDead(pid);
  }
  killRecordedChild(pid) {
    if (!this.children.some((c) => c.pid === pid) && !this.keepalives.some((k) => k.pid === pid)) {
      throw new Error(`refusing to kill unrecorded child PID ${pid} (not in the fixture registry)`);
    }
    killExactPid(pid);
  }

  // Abruptly CRASH a spawned driver child by its exact recorded PID and reap it. A child of
  // this test process becomes a zombie (still "alive" to kill(pid,0)) until reaped, so a
  // clean death is proven by awaiting its own `exit` event rather than by isAlive polling.
  // Fail-closed on the registry membership exactly like the other kill primitives (Q3).
  async crashRecordedChild(pid, child) {
    if (!this.children.some((c) => c.pid === pid)) {
      throw new Error(`refusing to crash unrecorded child PID ${pid} (not in the fixture registry)`);
    }
    if (child.exitCode === null && child.signalCode === null) {
      const exited = new Promise((resolve) => child.once('exit', resolve));
      child.kill('SIGKILL');
      await exited;
    }
    return { exitCode: child.exitCode, signalCode: child.signalCode };
  }

  // ---- store helpers --------------------------------------------------------------

  async read(sql, params) { return runExclusive(this.#store, async (conn) => (await conn.query(sql, params)).rows); }

  // True iff a table exists. Later-slice tables (outbox S2, consumer_* S4, snapshots S6) are
  // applied lazily by the slice that owns them, so a workflow that never exercises a slice
  // leaves its table absent - the finals must treat that as "zero rows", exactly as the
  // snapshot payload builder guards its own domain reads.
  async #tableExists(name) {
    const r = await this.read("SELECT to_regclass($1) AS reg", [`public.${name}`]);
    return r[0].reg !== null;
  }

  // Close and reopen the store on the SAME dataDir (wf1 restarts, wf9 reopen, cursor
  // durability). Proves no in-memory state survives a process boundary.
  async reopenStore() {
    await this.#store.close();
    this.#store = new PgliteLocalStore({ fmHome: this._fmHome });
    await this.#store.init({ homeLabel: this.label });
    return this.#store;
  }

  // Run the real `cp` CLI as a child process against this fixture's dataDir/socket/home.
  // Returns { status, stdout, stderr, json }. The genuine end-to-end path: real coordinator,
  // real flock, real store lifecycle per invocation.
  cp(argv, { allowFail = false } = {}) {
    const env = {
      ...process.env, FM_HOME: this._fmHome, CP_TMUX_SOCKET: this._socket, TMUX_TMPDIR: this._tmuxTmpDir
    };
    const res = spawnSync('node', [CP_MJS, ...argv, '--data-dir', this._dataDir], { encoding: 'utf8', env });
    if (res.status !== 0 && !allowFail) throw new Error(`cp ${argv.join(' ')} failed (${res.status}): ${res.stderr}`);
    let json = null;
    try { json = JSON.parse((res.stdout || '').trim()); } catch { /* not JSON (e.g. help) */ }
    return { status: res.status, stdout: res.stdout, stderr: res.stderr, json };
  }

  // Spawn a fixture DRIVER child process (a real coordinator/adapter/store/consumer driver
  // that reaches a state and then either hangs to be killed or waits for a release signal).
  // Returns the live ChildProcess. The caller records its PID and kills it via the fail-closed
  // killRecordedChild. Carries the fixture home/socket/dataDir so the child drives the same
  // isolated store.
  spawnDriver(scriptPath, extraEnv = {}) {
    const env = {
      ...process.env, FM_HOME: this._fmHome, CP_FM_HOME: this._fmHome, CP_SINK_DIR: this._sinkDir,
      CP_TMUX_SOCKET: this._socket, TMUX_TMPDIR: this._tmuxTmpDir, CP_DATA_DIR: this._dataDir, ...extraEnv
    };
    return spawn('node', [scriptPath], { env });
  }

  // Async variant of cp() for genuinely CONCURRENT invocations (wf9 serialization): several
  // real `cp` child processes launched at once must serialize on the store flock rather than
  // corrupt each other. Resolves { status, stdout, stderr }.
  cpAsync(argv) {
    const env = { ...process.env, FM_HOME: this._fmHome, CP_TMUX_SOCKET: this._socket, TMUX_TMPDIR: this._tmuxTmpDir };
    return new Promise((resolve) => {
      const child = spawn('node', [CP_MJS, ...argv, '--data-dir', this._dataDir], { env });
      let stdout = ''; let stderr = '';
      child.stdout.on('data', (d) => { stdout += d; });
      child.stderr.on('data', (d) => { stderr += d; });
      child.on('close', (status) => resolve({ status, stdout, stderr }));
    });
  }

  // Take a snapshot through the real CLI, sourcing the isolated inbox. Returns the latest
  // snapshot object read back in-process.
  async snapshot() {
    this.cp(['snapshot', '--order-source', this._inbox]);
    return getSnapshot(this.#store, {});
  }

  // ---- global final assertions ----------------------------------------------------

  // Run every global final assertion (spec 848-859) and throw one aggregated error if any
  // fails. `expectedActiveAnomalies` is the set of fingerprints a workflow legitimately
  // leaves ACTIVE-but-explained (spec 833-834: a markerless/ambiguous orphan is resolvable
  // only by later human disposition, so it is explained, not remediable in this slice); any
  // OTHER active anomaly is an unexplained/remediable one and fails the final.
  async assertGlobalFinals({ expectedActiveAnomalies = [] } = {}) {
    const failures = [];
    const fail = (m) => failures.push(m);

    // A fresh snapshot reflecting final state, sourced from the isolated inbox.
    const snap = await this.snapshot();

    // (4) zero unacked test outbox rows (the outbox table is absent iff no S2 verb ran).
    const outboxExists = await this.#tableExists('outbox');
    if (outboxExists) {
      const unacked = await this.read('SELECT count(*)::int AS n FROM outbox WHERE acked_at IS NULL');
      if (Number(unacked[0].n) !== 0) fail(`unacked outbox rows: ${unacked[0].n}`);
    }

    // (5) zero active unexplained/remediable anomalies (resolved rows may remain).
    const allowed = new Set(expectedActiveAnomalies);
    const active = (await listAnomalies(this.#store, { activeOnly: true })).anomalies;
    const unexplained = active.filter((a) => !allowed.has(a.fingerprint));
    if (unexplained.length !== 0) {
      fail(`active unexplained anomalies: ${unexplained.map((a) => `${a.anomaly_class}:${a.fingerprint}`).join(', ')}`);
    }

    // (6) zero active live bindings after archive: an archived task has no live binding.
    const archivedLive = await this.read(
      `SELECT r.task_id FROM runs r JOIN tasks t ON t.task_id = r.task_id
        WHERE t.status = 'archived' AND r.binding_state NOT IN ('closed','lost')`
    );
    if (archivedLive.length !== 0) fail(`archived tasks with live bindings: ${archivedLive.map((r) => r.task_id).join(', ')}`);

    // (7) DB constraints intact: invariant queries return zero violations. Skip any invariant
    // that references a later-slice table not yet materialized in this workflow.
    for (const [name, sql, needs] of this.#invariantQueries()) {
      if (needs === 'outbox' && !outboxExists) continue;
      const rows = await this.read(sql);
      if (Number(rows[0].n) !== 0) fail(`DB invariant violated (${name}): ${rows[0].n}`);
    }

    // (8) Bridge and Helm cite the SAME projection revision/checksum - proven from BOTH the
    // in-process projections and the out-of-process render (real child processes).
    const bridge = projectBridge(snap);
    const helm = projectHelm(snap);
    if (bridge.projection_revision !== snap.projection_revision || bridge.checksum !== snap.checksum) {
      fail('bridge projection does not cite the snapshot revision/checksum');
    }
    if (helm.projection_revision !== snap.projection_revision || helm.checksum !== snap.checksum) {
      fail('helm projection does not cite the snapshot revision/checksum');
    }
    const bridgeChild = runProjectionConsumer({ surface: 'bridge', dataDir: this._dataDir, boardDir: this._boardDir, revision: snap.projection_revision });
    const helmChild = runProjectionConsumer({ surface: 'helm', dataDir: this._dataDir, boardDir: this._boardDir, revision: snap.projection_revision });
    this.recordChild(bridgeChild.pid, 'bridge-consumer');
    this.recordChild(helmChild.pid, 'helm-consumer');
    if (bridgeChild.manifest.projection_revision !== snap.projection_revision || bridgeChild.manifest.checksum !== snap.checksum
      || helmChild.manifest.projection_revision !== snap.projection_revision || helmChild.manifest.checksum !== snap.checksum
      || bridgeChild.manifest.checksum !== helmChild.manifest.checksum) {
      fail('out-of-process Bridge/Helm consumers do not cite one identical revision/checksum');
    }

    // (3) zero orphan Bridge cards: every rendered card maps to a canonical task in the
    // current snapshot; no leftover card for a task the snapshot no longer carries.
    const snapTaskIds = new Set(snap.payload.tasks.map((t) => t.task_id));
    const orphanCards = boardCardIds(this._boardDir).filter((id) => !snapTaskIds.has(id));
    if (orphanCards.length !== 0) fail(`orphan Bridge cards: ${orphanCards.join(', ')}`);
    if (bridge.cards.length !== snap.payload.tasks.length) fail('Bridge card count != canonical task count');

    // (10) order source hash matches the isolated inbox stable prefix.
    const prefix = await acquireStableOrderPrefix(this._inbox);
    if (snap.order_source_hash !== prefix.hash) fail('snapshot order hash != isolated inbox stable-prefix hash');
    if (path.resolve(snap.order_source_path) !== path.resolve(this._inbox)) fail('snapshot order source path != isolated inbox');

    // (9) consumer cursor durable across a store reopen.
    const before = await cursorOf(this.#store);
    await this.reopenStore();
    const after = await cursorOf(this.#store);
    if (before.last_acked_outbox_id !== after.last_acked_outbox_id) fail('consumer cursor did not survive store reopen');

    // (1) zero orphan fixture processes: every recorded expected-dead child is dead, and
    // every agent marked dead is dead.
    for (const c of this.children) if (isAlive(c.pid)) fail(`orphan child process still alive: pid ${c.pid} (${c.kind})`);
    for (const a of this.agents) if (!a.alive && isAlive(a.pid)) fail(`agent marked dead still alive: pid ${a.pid}`);

    // (2) zero unrecorded marker-bearing panes on the dedicated socket: every marker-bearing
    // pane's marker must belong to a recorded, still-live agent. An unrecorded marker pane
    // (the decoy) is an orphan and fails here - it is never killed by teardown.
    if (this.hasTmux) {
      const liveMarkers = this.liveAgentMarkers();
      for (const pane of scanPanes(this._socket)) {
        if (pane.marker && !liveMarkers.has(pane.marker)) {
          fail(`unrecorded marker-bearing pane on dedicated socket: ${pane.endpointId} ${pane.paneId} marker=${pane.marker}`);
        }
      }
    }

    if (failures.length > 0) {
      throw new Error(`global final assertions FAILED (${failures.length}):\n  - ${failures.join('\n  - ')}`);
    }
    return { ok: true };
  }

  // The DB-constraint invariant queries (each returns a single column `n` = violation count).
  #invariantQueries() {
    return [
      ['runs_reference_tasks', 'SELECT count(*)::int AS n FROM runs r LEFT JOIN tasks t ON t.task_id = r.task_id WHERE t.task_id IS NULL'],
      ['outbox_references_events', 'SELECT count(*)::int AS n FROM outbox o LEFT JOIN task_events e ON e.event_id = o.event_id WHERE e.event_id IS NULL', 'outbox'],
      ['events_reference_tasks', 'SELECT count(*)::int AS n FROM task_events e LEFT JOIN tasks t ON t.task_id = e.task_id WHERE t.task_id IS NULL'],
      ['single_coordinator_row', 'SELECT (count(*) - 1)::int AS n FROM coordinator_state WHERE id = 1'],
      ['at_most_one_open_run', "SELECT COALESCE(sum(c - 1), 0)::int AS n FROM (SELECT count(*) c FROM runs WHERE closed_at IS NULL GROUP BY task_id) g"],
      ['at_most_one_terminal_per_gen', "SELECT COALESCE(sum(c - 1), 0)::int AS n FROM (SELECT count(*) c FROM task_events WHERE is_terminal GROUP BY task_id, run_generation) g"],
      ['non_negative_counters', 'SELECT count(*)::int AS n FROM coordinator_state WHERE domain_revision < 0 OR projection_revision < 0 OR commit_sequence < 0']
    ];
  }

  // ---- teardown -------------------------------------------------------------------

  // Kill ONLY exact recorded fixture PIDs and the dedicated socket (spec 846), then close
  // the store and remove the fixture root. NEVER a pattern kill. An unrecorded process (the
  // decoy) is deliberately left untouched - the finals are what flag it, not teardown.
  async teardown() {
    if (this.torndown) return;
    this.torndown = true;
    for (const a of this.agents) killExactPid(a.pid);
    for (const c of this.children) killExactPid(c.pid);
    for (const k of this.keepalives) killExactPid(k.pid);
    if (this.hasTmux && this._socket) killSocket(this._socket, { ...process.env, TMUX_TMPDIR: this._tmuxTmpDir });
    try { await this.#store?.close(); } catch { /* best effort */ }
    delete process.env.CP_TMUX_SOCKET;
    try { fs.rmSync(this._root, { recursive: true, force: true }); } catch { /* best effort */ }
  }
}
