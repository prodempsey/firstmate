import nodeFs from 'node:fs';
import path from 'node:path';
import { LEGACY_STORES, readLegacyRecords, readOnlyFs, resolveLegacyHome } from './legacy-reader.mjs';
import { mapRecord, newMappingContext } from './migrate-map.mjs';
import { MigrateReportError } from './errors-s8.mjs';

// `cp migrate-report --out <path>` (spec section 12 S8 row; section 13). A strictly
// READ-ONLY shadow read of the legacy stores that emits ONE deterministic proposal
// file and applies nothing.
//
// Read-only is structural, not merely promised: every legacy access goes through the
// read-only `io` seam (legacy-reader.mjs), which exposes no write API. The ONLY write
// this verb performs is the atomic emission of the report to `--out`, and `--out` is
// asserted to lie OUTSIDE the legacy home so the emission can never touch a legacy path.
//
// Deterministic + idempotent + stateless: records are emitted in the reader's fixed
// order, no wall-clock value is generated (only values sourced from the legacy records
// themselves appear), and the run holds no state - two runs over the same legacy home
// produce byte-identical output.

export const REPORT_SCHEMA = 'control-plane/migrate-report/v1';

// Owner-only atomic write (spec 768 pattern, mirrored from projections.mjs): temp in the
// same dir -> fsync -> atomic rename -> fsync dir. A crash mid-write can only leave a stray
// temp file, never a torn report at the final path. `fault` is a test-only crash seam fired
// after the temp is durable and before the rename.
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

// `--out` must not be inside the legacy home: the report is the ONLY write this verb
// makes, and it may never land under a store it just read read-only. Rejected loudly.
function assertOutOutsideHome(outPath, home) {
  const resolvedOut = path.resolve(outPath);
  const rel = path.relative(home, resolvedOut);
  if (rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel))) {
    throw new MigrateReportError('--out must be outside the legacy home being read', {
      out: resolvedOut, legacy_home: home
    });
  }
  return resolvedOut;
}

// Build the deterministic report object from the mapped records. Pure: no fs, no clock.
export function buildReport(home, records, dispositions) {
  const storeCounts = new Map(LEGACY_STORES.map((s) => [s, { discovered: 0, mapped: 0, flagged: 0 }]));
  const flagsByReason = { unmappable: 0, ambiguous: 0, duplicate: 0 };
  let mappedTotal = 0;
  let flaggedTotal = 0;
  for (const d of dispositions) {
    const bucket = storeCounts.get(d.store) || { discovered: 0, mapped: 0, flagged: 0 };
    bucket.discovered += 1;
    if (d.disposition === 'mapped') { bucket.mapped += 1; mappedTotal += 1; }
    else { bucket.flagged += 1; flaggedTotal += 1; flagsByReason[d.flag.reason] += 1; }
    storeCounts.set(d.store, bucket);
  }
  const discovered = dispositions.length;
  const stores = LEGACY_STORES.map((s) => ({ store: s, ...storeCounts.get(s) }));
  const totals = {
    discovered,
    mapped: mappedTotal,
    flagged: flaggedTotal,
    reconciles: mappedTotal + flaggedTotal === discovered
  };
  const human = buildHumanSummary(home, stores, totals, flagsByReason);
  return {
    schema: REPORT_SCHEMA,
    posture: 'read-only shadow read; nothing applied to legacy stores',
    legacy_home: home,
    stores,
    totals,
    flags_by_reason: flagsByReason,
    records: dispositions,
    human_summary: human
  };
}

function buildHumanSummary(home, stores, totals, flagsByReason) {
  const lines = [
    'cp migrate-report - legacy shadow read (READ-ONLY; nothing applied)',
    `legacy home: ${home}`,
    `discovered: ${totals.discovered}   mapped: ${totals.mapped}   flagged: ${totals.flagged}   reconciles: ${totals.reconciles ? 'yes' : 'NO'}`,
    'by store:'
  ];
  for (const s of stores) {
    lines.push(`  ${s.store}: discovered ${s.discovered} (mapped ${s.mapped}, flagged ${s.flagged})`);
  }
  lines.push(`flags: unmappable ${flagsByReason.unmappable}, ambiguous ${flagsByReason.ambiguous}, duplicate ${flagsByReason.duplicate}`);
  return lines.join('\n');
}

// Run the full shadow read and emit the report. `io` is the read-only legacy seam
// (default readOnlyFs); tests inject a tripwire facade to prove no legacy write is
// attempted. Returns the report object and a small receipt.
export function runMigrateReport({ home, outPath, env = process.env, io = readOnlyFs, fault } = {}) {
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new MigrateReportError('migrate-report requires --out <path>', { out: outPath ?? null });
  }
  const legacyHome = resolveLegacyHome({ explicit: home, env });
  const resolvedOut = assertOutOutsideHome(outPath, legacyHome);

  const records = readLegacyRecords(legacyHome, { io });
  const ctx = newMappingContext();
  const dispositions = records.map((r) => mapRecord(r, ctx));
  const report = buildReport(legacyHome, records, dispositions);

  // A pretty, stable serialization: 2-space JSON with a trailing newline. Deterministic
  // key order comes from insertion order in buildReport, so repeated runs are byte-equal.
  const content = `${JSON.stringify(report, null, 2)}\n`;
  atomicWriteOwnerOnly(resolvedOut, content, { fault });

  return {
    report,
    receipt: {
      out: resolvedOut,
      legacy_home: legacyHome,
      discovered: report.totals.discovered,
      mapped: report.totals.mapped,
      flagged: report.totals.flagged,
      reconciles: report.totals.reconciles,
      bytes: Buffer.byteLength(content)
    }
  };
}
