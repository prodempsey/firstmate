import nodeFs from 'node:fs';
import path from 'node:path';
import {
  readOnlyFs, resolveLegacyHome, readLegacyRecords,
  resolveAuthoritativeOrdersPath, resolveBridgeHistoryPath
} from './legacy-reader.mjs';
import { newMappingContext, mapRecord } from './migrate-map.mjs';
import { buildReport } from './migrate-report.mjs';
import { assembleTasks, deriveCurrentState } from './migrate-apply.mjs';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { readOnlyQuery } from './cw1-readonly.mjs';
import { ShadowDiffError } from './errors-cw2.mjs';

// `cp shadow-diff --out <path> --data-dir <store> [--home <legacy>]` (CW2 divergence
// monitor). A strictly READ-ONLY comparison that regenerates the S8 mapper's view of the
// LEGACY stores on demand, translates it through the SAME ratified CW1 classification the
// production migration used (assembleTasks + deriveCurrentState), and diffs that expected
// live-surface state against the committed control-plane store. It emits ONE deterministic
// divergence report and applies NOTHING - to the legacy home OR the store.
//
// Read-only is structural on both sides: legacy access goes through the read-only `io` seam
// (legacy-reader), which exposes no write API; store access goes through the SELECT-only
// read-only-transaction seam (cw1-readonly), which the database itself refuses to let mutate.
// The only write is the atomic emission of the report to --out, which is refused if it
// resolves under the legacy home or the store directory.
//
// The CW1 classification is the load-bearing choice: the store was materialized by CW1's
// executor, so the faithful "legacy truth" to compare against is what that same executor
// would produce today, not the raw mapped rows. Reusing assembleTasks/deriveCurrentState
// guarantees the diff speaks the store's language:
//   * derived running  -> store `queued`  (CW1 materializes in-flight work queued, no run)
//   * derived queued    -> store `queued`
//   * derived completed -> store `completed`
//   * derived failed    -> store `failed`
//   * derived archived  -> NOT a live task; expected in the CW2 archived_history back-fill
//
// Divergence buckets:
//   missing            an expected live task absent from the store
//   mismatched         present but its status differs from the CW1-expected status
//   extra              a live store task the regenerated legacy view does not know (e.g. a
//                      task filed after the S8 report, or a shadow-mirrored new task) -
//                      informational, NOT a failure
//   archived_deferred  a derived-archived task not yet present in archived_history
//   archived_backfilled a derived-archived task present in archived_history
//
// `ok` is true when missing and mismatched are both zero; extras and archived_deferred are
// review signal, not divergence failures (the store legitimately runs ahead of a stale S8
// report, and archived history is a separately staged back-fill).

export const SHADOW_DIFF_SCHEMA = 'control-plane/shadow-diff/v1';

// Translate a CW1-derived current state to the status the store holds for a live task, or
// 'archived' for the history class (never a live task row).
function expectedStoreStatus(derived) {
  if (derived === 'running') return 'queued';
  return derived;
}

function isAtOrUnder(root, p) {
  const rel = path.relative(root, p);
  return rel === '' || (!rel.startsWith(`..${path.sep}`) && rel !== '..' && !path.isAbsolute(rel));
}

function realDirOf(p) {
  let cur = path.resolve(p);
  const tail = [];
  for (;;) {
    if (nodeFs.existsSync(cur)) return path.join(nodeFs.realpathSync(cur), ...tail);
    const parent = path.dirname(cur);
    tail.unshift(path.basename(cur));
    if (parent === cur) return path.join(cur, ...tail);
    cur = parent;
  }
}

function realOf(p) {
  return nodeFs.existsSync(p) ? nodeFs.realpathSync(p) : path.resolve(p);
}

// Refuse an --out that resolves under the legacy home OR the store directory: a divergence
// report must never be written into the very state it observes (same containment migrate-
// report/apply enforce; a symlinked ancestor is defeated by resolving the nearest existing
// output ancestor).
function resolveContainedOut(outPath, legacyHome, dataDir) {
  const outAbs = path.resolve(outPath);
  const resolvedDir = realDirOf(path.dirname(outAbs));
  const resolvedOut = path.join(resolvedDir, path.basename(outAbs));
  const realHome = realOf(legacyHome);
  const realStore = realOf(dataDir);
  for (const [label, root] of [['legacy home', realHome], ['store data-dir', realStore]]) {
    if (isAtOrUnder(root, resolvedDir) || isAtOrUnder(root, resolvedOut)) {
      throw new ShadowDiffError(`--out resolves under the ${label} (symlink or path traversal); refused`, {
        out: resolvedOut, resolved_dir: resolvedDir, root
      });
    }
  }
  return resolvedOut;
}

function atomicWriteOwnerOnly(outPath, content) {
  const dir = path.dirname(outPath);
  if (!nodeFs.existsSync(dir)) {
    nodeFs.mkdirSync(dir, { recursive: true });
    nodeFs.chmodSync(dir, 0o700);
  }
  const tmp = `${outPath}.tmp.${process.pid}`;
  const fd = nodeFs.openSync(tmp, 'w', 0o600);
  try {
    nodeFs.writeFileSync(fd, content);
    nodeFs.fsyncSync(fd);
  } finally {
    nodeFs.closeSync(fd);
  }
  nodeFs.chmodSync(tmp, 0o600);
  nodeFs.renameSync(tmp, outPath);
  nodeFs.chmodSync(outPath, 0o600);
}

async function tableExists(store, name) {
  const rows = await readOnlyQuery(
    store,
    "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
    [name]
  );
  return rows.length > 0;
}

async function countRows(store, table) {
  if (!(await tableExists(store, table))) return 0;
  const rows = await readOnlyQuery(store, `SELECT count(*)::int AS n FROM ${table}`);
  return Number(rows[0].n);
}

// Regenerate the S8 mapper's view of the legacy stores in memory (NO file written; the
// exact migrate-report pipeline). Read-only by construction.
export function regenerateMapperView({ home, ordersPath, bridgeHistoryPath, env = process.env, io = readOnlyFs } = {}) {
  const legacyHome = resolveLegacyHome({ explicit: home, env });
  const resolvedOrders = resolveAuthoritativeOrdersPath({ explicit: ordersPath, home: legacyHome, env, io });
  const resolvedBridge = resolveBridgeHistoryPath({ explicit: bridgeHistoryPath, env });
  const { records, sources } = readLegacyRecords(legacyHome, { io, ordersPath: resolvedOrders, bridgeHistoryPath: resolvedBridge });
  const ctx = newMappingContext();
  const dispositions = records.map((r) => mapRecord(r, ctx));
  const report = buildReport(legacyHome, records, dispositions, sources);
  return { report, legacyHome, resolvedOrders, resolvedBridge };
}

// Compute the per-task expected live-surface state from the regenerated mapper view.
// Returns Maps keyed by task_id: live (expected store status) and archived (history class).
export function expectedFromReport(report) {
  const tasks = assembleTasks(report);
  const live = new Map();
  const archived = new Map();
  for (const t of tasks.values()) {
    if (!t.kind) continue; // kind-un-prescribed tasks were never materialized by CW1 (residual)
    const derived = deriveCurrentState(t);
    if (derived === 'archived') {
      archived.set(t.taskId, { task_id: t.taskId, derived, kind: t.kind });
    } else {
      live.set(t.taskId, { task_id: t.taskId, expected_status: expectedStoreStatus(derived), derived, kind: t.kind });
    }
  }
  return { live, archived };
}

// Diff a regenerated mapper report against an OPEN store handle (read-only). Returns the
// full divergence result minus the ambient paths (legacy_home/data_dir), which the CLI
// wrapper adds. Exposed so the diff engine can be tested against a real store without a
// legacy-home fixture. Reads the store ONLY through the SELECT-only read-only seam.
export async function diffAgainstStore(report, store) {
  const { live, archived } = expectedFromReport(report);

  // A freshly-`init`ed store (S0 core tables only) has no `tasks` table until the first
  // domain command creates it lazily; treat that as an empty live surface, not an error.
  const rows = (await tableExists(store, 'tasks'))
    ? await readOnlyQuery(store, 'SELECT task_id, status FROM tasks ORDER BY task_id')
    : [];
  const actualTasks = new Map(rows.map((r) => [r.task_id, r.status]));
  const storeCounts = {
    tasks: await countRows(store, 'tasks'),
    runs: await countRows(store, 'runs'),
    task_events: await countRows(store, 'task_events'),
    archived_history: await countRows(store, 'archived_history')
  };
  let archivedHistory = new Set();
  if (await tableExists(store, 'archived_history')) {
    const ah = await readOnlyQuery(store, 'SELECT task_id FROM archived_history');
    archivedHistory = new Set(ah.map((r) => r.task_id));
  }

  const missing = [];
  const mismatched = [];
  for (const [taskId, exp] of [...live.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    if (!actualTasks.has(taskId)) {
      missing.push({ task_id: taskId, expected_status: exp.expected_status, derived: exp.derived });
    } else if (actualTasks.get(taskId) !== exp.expected_status) {
      mismatched.push({ task_id: taskId, expected_status: exp.expected_status, actual_status: actualTasks.get(taskId), derived: exp.derived });
    }
  }

  // extra: a live store task the regenerated view does not classify live (not in `live`).
  // Derived-archived tasks that DID materialize as live in the store would surface here too
  // (a real divergence for review), so extras are annotated with whether the legacy view
  // considers them archived history.
  const extra = [];
  for (const [taskId, status] of [...actualTasks.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    if (live.has(taskId)) continue;
    extra.push({ task_id: taskId, actual_status: status, archived_in_legacy_view: archived.has(taskId) });
  }

  const archivedDeferred = [];
  const archivedBackfilled = [];
  for (const [taskId] of [...archived.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    if (archivedHistory.has(taskId)) archivedBackfilled.push({ task_id: taskId });
    else archivedDeferred.push({ task_id: taskId });
  }

  const totals = {
    missing: missing.length,
    mismatched: mismatched.length,
    extra: extra.length,
    archived_deferred: archivedDeferred.length,
    archived_backfilled: archivedBackfilled.length
  };
  const ok = totals.missing === 0 && totals.mismatched === 0;

  return {
    generated: {
      discovered: report.totals.discovered,
      mapped: report.totals.mapped,
      flagged: report.totals.flagged,
      live_tasks: live.size,
      archived_tasks: archived.size
    },
    store: storeCounts,
    divergence: {
      missing,
      mismatched,
      extra,
      archived_deferred: archivedDeferred,
      archived_backfilled: archivedBackfilled
    },
    totals,
    ok
  };
}

export async function runShadowDiff({ home, dataDir, outPath, ordersPath, bridgeHistoryPath, env = process.env } = {}) {
  if (typeof dataDir !== 'string' || dataDir.length === 0) {
    throw new ShadowDiffError('shadow-diff requires --data-dir <control-plane store path>', { data_dir: dataDir ?? null });
  }
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new ShadowDiffError('shadow-diff requires --out <divergence-report-path>', { out: outPath ?? null });
  }

  const { report, legacyHome } = regenerateMapperView({ home, ordersPath, bridgeHistoryPath, env });
  const resolvedOut = resolveContainedOut(outPath, legacyHome, dataDir);

  const store = PgliteLocalStore.create({ dataDir, env });
  let core;
  try {
    core = await diffAgainstStore(report, store);
  } finally {
    await store.close();
  }

  const result = {
    schema: SHADOW_DIFF_SCHEMA,
    posture: 'read-only; regenerated S8 mapper view translated through the CW1 classification vs committed store; applies nothing to legacy or store',
    legacy_home: legacyHome,
    data_dir: dataDir,
    ...core
  };

  atomicWriteOwnerOnly(resolvedOut, `${JSON.stringify(result, null, 2)}\n`);

  return {
    out: resolvedOut,
    legacy_home: legacyHome,
    data_dir: dataDir,
    totals: core.totals,
    ok: core.ok
  };
}
