import nodeFs from 'node:fs';
import path from 'node:path';
import {
  LEGACY_STORES, readLegacyRecords, readOnlyFs, resolveLegacyHome,
  resolveAuthoritativeOrdersPath, resolveBridgeHistoryPath
} from './legacy-reader.mjs';
import { mapRecord, newMappingContext, FLAG_REASONS } from './migrate-map.mjs';
import { MigrateReportError } from './errors-s8.mjs';

// `cp migrate-report --out <path>` (spec section 12 S8 row; section 13). A strictly
// READ-ONLY shadow read of the legacy stores that emits ONE deterministic proposal file
// and applies nothing.
//
// Read-only is structural AND containment-checked: every legacy access goes through the
// read-only `io` seam (legacy-reader.mjs), which exposes no write API; and the ONLY write
// this verb performs - the atomic emission of the report to `--out` - is resolved through
// realpath so a symlinked ancestor cannot redirect it under a legacy store (QA finding 1).
//
// Totality is INDEPENDENTLY enforced, not tautological (QA finding 3): discovery is the
// reader's own record count, and buildReport requires a strict bijection between the
// independently captured records and the dispositions - a record dropped between read and
// map (a hidden mapper input) breaks the bijection and REJECTS the run before any write.
//
// Deterministic + idempotent + stateless: records are emitted in the reader's fixed order,
// no wall-clock value is generated, and two runs over the same inputs are byte-identical.

export const REPORT_SCHEMA = 'control-plane/migrate-report/v1';

function atomicWriteOwnerOnly(outPath, content, { fault } = {}) {
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
  if (typeof fault === 'function') fault();
  nodeFs.renameSync(tmp, outPath);
  nodeFs.chmodSync(outPath, 0o600);
  const dfd = nodeFs.openSync(dir, 'r');
  try {
    nodeFs.fsyncSync(dfd);
  } catch {
    // some platforms reject directory fsync; the rename is still atomic
  } finally {
    nodeFs.closeSync(dfd);
  }
}

// True when `p` is the directory `root` itself or lies beneath it.
function isAtOrUnder(root, p) {
  const rel = path.relative(root, p);
  return rel === '' || (!rel.startsWith(`..${path.sep}`) && rel !== '..' && !path.isAbsolute(rel));
}

// Realpath the nearest EXISTING ancestor of `p`, re-appending the not-yet-existing tail.
// This resolves symlinked ancestors even when the final target does not exist yet, which
// is exactly the hostile case (a symlinked output directory aliasing a legacy store).
function realDirOf(p) {
  let cur = path.resolve(p);
  const tail = [];
  for (;;) {
    if (nodeFs.existsSync(cur)) return path.join(nodeFs.realpathSync(cur), ...tail);
    const parent = path.dirname(cur);
    tail.unshift(path.basename(cur));
    if (parent === cur) return path.join(cur, ...tail); // reached the filesystem root
    cur = parent;
  }
}

// Resolve --out to its real destination and REFUSE any target that resolves under the
// legacy home (spec section 13 read-only; QA finding 1). Canonicalizing both sides and the
// nearest existing output ancestor defeats a symlinked ancestor and path traversal alike;
// the temp file lives in the same resolved directory, so the directory check covers it too.
function resolveContainedOut(outPath, realHome) {
  const outAbs = path.resolve(outPath);
  const resolvedDir = realDirOf(path.dirname(outAbs));
  const resolvedOut = path.join(resolvedDir, path.basename(outAbs));
  if (isAtOrUnder(realHome, resolvedDir) || isAtOrUnder(realHome, resolvedOut)) {
    throw new MigrateReportError('--out resolves under the legacy home (symlink or path traversal); refused', {
      out: resolvedOut, resolved_dir: resolvedDir, legacy_home: realHome
    });
  }
  return resolvedOut;
}

// Enforce a strict record<->disposition bijection and per-disposition shape, then build the
// deterministic report. `records` is the INDEPENDENT enumeration (discovery); any mismatch
// with `dispositions` is an integrity failure that REJECTS the run (nothing is written).
export function buildReport(home, records, dispositions, sources = []) {
  const integrity = [];
  const recordRefs = new Set();
  for (const r of records) {
    if (recordRefs.has(r.source_ref)) integrity.push(`duplicate reader source_ref ${r.source_ref}`);
    recordRefs.add(r.source_ref);
  }
  const dispByRef = new Set();
  for (const d of dispositions) {
    if (!recordRefs.has(d.source_ref)) integrity.push(`disposition for unknown record ${d.source_ref}`);
    if (dispByRef.has(d.source_ref)) integrity.push(`duplicate disposition ${d.source_ref}`);
    dispByRef.add(d.source_ref);
    if (d.disposition === 'mapped') {
      if (!d.mapping || !Array.isArray(d.mapping.canonical) || d.mapping.canonical.length < 1) {
        integrity.push(`empty mapping ${d.source_ref}`);
      }
    } else if (d.disposition === 'flagged') {
      if (!d.flag || !FLAG_REASONS.includes(d.flag.reason) || !d.flag.detail) {
        integrity.push(`invalid flag ${d.source_ref}`);
      }
    } else {
      integrity.push(`invalid disposition kind at ${d.source_ref}`);
    }
    if (!d.source || typeof d.source.digest !== 'string') integrity.push(`disposition ${d.source_ref} has no source record`);
  }
  for (const r of records) {
    if (!dispByRef.has(r.source_ref)) integrity.push(`record ${r.source_ref} has no disposition (hidden mapper input)`);
  }
  if (integrity.length > 0) {
    throw new MigrateReportError('migration report integrity check failed; refusing to write', {
      violations: integrity.slice(0, 20),
      violation_count: integrity.length,
      discovered: records.length,
      dispositions: dispositions.length
    });
  }

  // Discovery is the INDEPENDENT reader count, not dispositions.length.
  const discovered = records.length;
  const storeCounts = new Map(LEGACY_STORES.map((s) => [s, { discovered: 0, mapped: 0, flagged: 0 }]));
  const flagsByReason = { unmappable: 0, ambiguous: 0, duplicate: 0 };
  for (const r of records) {
    const bucket = storeCounts.get(r.store) || { discovered: 0, mapped: 0, flagged: 0 };
    bucket.discovered += 1;
    storeCounts.set(r.store, bucket);
  }
  let mappedTotal = 0;
  let flaggedTotal = 0;
  for (const d of dispositions) {
    const bucket = storeCounts.get(d.store);
    if (d.disposition === 'mapped') { bucket.mapped += 1; mappedTotal += 1; }
    else { bucket.flagged += 1; flaggedTotal += 1; flagsByReason[d.flag.reason] += 1; }
  }
  const stores = LEGACY_STORES.map((s) => ({ store: s, ...storeCounts.get(s) }));
  const totals = {
    discovered,
    mapped: mappedTotal,
    flagged: flaggedTotal,
    // A real, enforced bijection: discovered came from the independent reader, and the
    // integrity gate above already proved every record maps to exactly one disposition.
    reconciles: mappedTotal + flaggedTotal === discovered && discovered === records.length
  };
  return {
    schema: REPORT_SCHEMA,
    posture: 'read-only shadow read; nothing applied to legacy stores',
    legacy_home: home,
    sources,
    stores,
    totals,
    flags_by_reason: flagsByReason,
    records: dispositions,
    human_summary: buildHumanSummary(home, stores, totals, flagsByReason, sources)
  };
}

function buildHumanSummary(home, stores, totals, flagsByReason, sources) {
  const lines = [
    'cp migrate-report - legacy shadow read (READ-ONLY; nothing applied)',
    `legacy home: ${home}`,
    `discovered: ${totals.discovered}   mapped: ${totals.mapped}   flagged: ${totals.flagged}   reconciles: ${totals.reconciles ? 'yes' : 'NO'}`,
    'sources:'
  ];
  for (const s of sources) {
    lines.push(`  ${s.store}: ${s.resolved ? s.path : 'UNRESOLVED'} (${s.discovered} records)`);
  }
  lines.push('by store:');
  for (const s of stores) {
    lines.push(`  ${s.store}: discovered ${s.discovered} (mapped ${s.mapped}, flagged ${s.flagged})`);
  }
  lines.push(`flags: unmappable ${flagsByReason.unmappable}, ambiguous ${flagsByReason.ambiguous}, duplicate ${flagsByReason.duplicate}`);
  return lines.join('\n');
}

// Run the full shadow read and emit the report. Resolves the authoritative external order
// ledger (loud if unresolved) and the optional Bridge History export, reads every legacy
// store read-only through `io`, maps each record, enforces the totality bijection, and
// atomically writes the report to a realpath-contained --out.
export function runMigrateReport({ home, outPath, ordersPath, bridgeHistoryPath, env = process.env, io = readOnlyFs, fault } = {}) {
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new MigrateReportError('migrate-report requires --out <path>', { out: outPath ?? null });
  }
  const legacyHome = resolveLegacyHome({ explicit: home, env });
  const realHome = nodeFs.existsSync(legacyHome) ? nodeFs.realpathSync(legacyHome) : legacyHome;
  const resolvedOut = resolveContainedOut(outPath, realHome);

  const resolvedOrders = resolveAuthoritativeOrdersPath({ explicit: ordersPath, home: legacyHome, env, io });
  const resolvedBridge = resolveBridgeHistoryPath({ explicit: bridgeHistoryPath, env });

  const { records, sources } = readLegacyRecords(legacyHome, {
    io, ordersPath: resolvedOrders, bridgeHistoryPath: resolvedBridge
  });
  const ctx = newMappingContext();
  const dispositions = records.map((r) => mapRecord(r, ctx));
  const report = buildReport(legacyHome, records, dispositions, sources);

  const content = `${JSON.stringify(report, null, 2)}\n`;
  atomicWriteOwnerOnly(resolvedOut, content, { fault });

  return {
    report,
    receipt: {
      out: resolvedOut,
      legacy_home: legacyHome,
      orders_path: resolvedOrders,
      bridge_history_path: resolvedBridge,
      discovered: report.totals.discovered,
      mapped: report.totals.mapped,
      flagged: report.totals.flagged,
      reconciles: report.totals.reconciles,
      bytes: Buffer.byteLength(content)
    }
  };
}
