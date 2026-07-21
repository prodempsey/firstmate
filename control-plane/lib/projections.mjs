import fs from 'node:fs';
import path from 'node:path';
import { canonicalJson, sha256hex } from './domain-store.mjs';
import { getSnapshot } from './domain-store-s6.mjs';
import { SnapshotVerificationError } from './errors-s6.mjs';

// S6 projections (spec 9.3, lines 771-787) plus the atomic snapshot export and its
// reader-side verifier (spec 9.2, lines 768-769).
//
// EVERY projection reads a snapshot ONLY (spec 733-734): it takes the snapshot row
// getSnapshot returns and derives its cards/panes from snapshot.payload, and it NEVER
// touches a live domain table, tmux, /proc, status files, History, or JSONL. That is
// the whole point of the snapshot seam - a projection can only ever surface state that
// was captured, checksummed, and revision-stamped at build time, so a domain row that
// was never snapshotted cannot appear in Bridge or Helm.
//
// This module has NO database mutation and NO PGlite import (owner-guard clean); its
// only store touch is the locked read in getSnapshot.

// Bridge projection (spec 773-778): one card per canonical task row, status straight
// from tasks.status, NO History synthesis and NO alternate order ledger. Every card
// cites the projection revision + checksum so a stale card is self-identifying (spec
// 778/786).
export function projectBridge(snapshot) {
  const cards = snapshot.payload.tasks.map((t) => ({
    task_id: t.task_id,
    kind: t.kind,
    title: t.title,
    status: t.status,
    task_origin: t.task_origin,
    order_ref: t.order_ref ?? null,
    repo: t.repo ?? null,
    revision: t.revision,
    current_generation: t.current_generation,
    // Provenance stamped on EVERY card (spec 778).
    projection_revision: snapshot.projection_revision,
    checksum: snapshot.checksum
  }));
  return {
    kind: 'bridge',
    projection_revision: snapshot.projection_revision,
    domain_revision: snapshot.domain_revision,
    checksum: snapshot.checksum,
    generated_at: snapshot.created_at,
    order: {
      source_path: snapshot.payload.orders.source_path,
      bytes: snapshot.payload.orders.bytes,
      hash: snapshot.payload.orders.hash,
      count: snapshot.payload.orders.count
    },
    cards
  };
}

// Helm projection (spec 780-784) plus the ORPHAN INSPECTOR section (spec 784, from the
// Helm projection's excluded panes).
//
// Classification is purely on the captured binding_state (and, for shell-only panes,
// the active orphan_pane anomalies):
//   * LIVE  iff binding_state === 'bound_verified' at snapshot build. A task in
//     blocked/waiting/needs_human whose process is bound_verified is RETAINED-LIVE, not
//     orphan (spec 783) - task status never demotes a verified pane out of `live`.
//   * ORPHAN INSPECTOR holds ONLY shell-only or identity-mismatched panes (spec 784):
//     a run still holding a recorded endpoint whose binding went 'lost' (identity gone/
//     mismatched), and active orphan_pane anomalies (the reconciler's shell-only /
//     markerless pane observations). A bound_verified pane NEVER appears here.
//   * RETAINED surfaces endpoint-bearing panes that are neither verified nor proven-lost
//     (bound_unverified / spawning-with-endpoint / cleanup_pending): transitional, not
//     yet live and not yet orphan. It exists so no captured pane is silently dropped.
export function projectHelm(snapshot) {
  const taskStatus = new Map(snapshot.payload.tasks.map((t) => [t.task_id, t.status]));

  const live = [];
  const retained = [];
  const orphanInspector = [];

  for (const run of snapshot.payload.runs) {
    const pane = {
      task_id: run.task_id,
      generation: run.run_generation,
      task_status: taskStatus.get(run.task_id) ?? null,
      run_status: run.status,
      binding_state: run.binding_state,
      endpoint_id: run.endpoint_id ?? null,
      pane_id: run.pane_id ?? null,
      harness: run.harness ?? null
    };
    if (run.binding_state === 'bound_verified') {
      live.push(pane);
    } else if (run.binding_state === 'lost' && run.endpoint_id !== null) {
      orphanInspector.push({ source: 'run', reason: 'identity_mismatch', ...pane });
    } else if (run.endpoint_id !== null && run.binding_state !== 'closed') {
      retained.push(pane);
    }
    // endpoint-less or 'closed' panes have no live endpoint to project; omitted.
  }

  for (const a of snapshot.payload.anomalies.active) {
    if (a.anomaly_class === 'orphan_pane') {
      orphanInspector.push({
        source: 'anomaly',
        reason: a.terminal_fingerprint === null ? 'shell_only_or_markerless' : 'marker_bearing_orphan',
        fingerprint: a.fingerprint,
        task_id: a.task_id ?? null,
        endpoint_id: a.endpoint_id ?? null,
        pane_id: a.pane_id ?? null,
        occurrence_count: a.occurrence_count
      });
    }
  }

  return {
    kind: 'helm',
    projection_revision: snapshot.projection_revision,
    domain_revision: snapshot.domain_revision,
    checksum: snapshot.checksum,
    generated_at: snapshot.created_at,
    // Staleness is surfaced by timestamp + revision + checksum (spec 786). The delivery
    // lag numbers ride along so Helm can show it without a second read.
    staleness: {
      generated_at: snapshot.created_at,
      projection_revision: snapshot.projection_revision,
      checksum: snapshot.checksum,
      unacked_count: snapshot.payload.delivery.unacked_count,
      oldest_unacked: snapshot.payload.delivery.oldest_unacked
    },
    live,
    retained,
    orphan_inspector: orphanInspector
  };
}

// Build the self-describing export envelope from a snapshot row. It carries every field
// a reader needs to verify integrity independently (spec 769): the checksum, the
// projection revision, and the order source path, plus the full payload the checksum
// covers. The checksum is recomputable from `payload` alone, so a reader never has to
// trust the envelope's own checksum field.
export function buildExportEnvelope(snapshot) {
  return {
    format: 'cp-snapshot',
    format_version: 1,
    projection_revision: snapshot.projection_revision,
    domain_revision: snapshot.domain_revision,
    checksum: snapshot.checksum,
    order_source_path: snapshot.order_source_path,
    order_source_bytes: snapshot.order_source_bytes,
    order_source_hash: snapshot.order_source_hash,
    created_at: snapshot.created_at,
    payload: snapshot.payload
  };
}

// Atomically write `content` to `outPath` with owner-only permissions (spec 768; Q5
// ruling: 0600 file / 0700 parent-when-created, umask-INDEPENDENT). The sequence is
// temp-in-same-dir -> fsync file -> atomic rename -> fsync parent dir, so a crash mid-
// write can only ever leave a stray temp file, NEVER a torn file at the final path. The
// chmod is explicit (not the open mode) precisely so a permissive umask cannot widen the
// bits. `fault` is a test-only seam fired after the temp is durable and before the
// rename, exactly the crash cutpoint t_export_crash_mid_write_leaves_no_partial_file
// drives.
function atomicWriteOwnerOnly(outPath, content, { fault } = {}) {
  const dir = path.dirname(outPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    fs.chmodSync(dir, 0o700); // umask-independent
  }
  const tmp = `${outPath}.tmp.${process.pid}`;
  const fd = fs.openSync(tmp, 'w', 0o600);
  try {
    fs.writeFileSync(fd, content);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.chmodSync(tmp, 0o600); // umask-independent, before the file becomes visible

  if (typeof fault === 'function') fault(); // crash cutpoint: temp durable, no final yet

  fs.renameSync(tmp, outPath); // atomic on the same filesystem
  fs.chmodSync(outPath, 0o600); // belt-and-suspenders (rename preserves perms)

  // fsync the parent directory so the rename itself is durable.
  const dfd = fs.openSync(dir, 'r');
  try {
    fs.fsyncSync(dfd);
  } catch {
    // some platforms reject directory fsync; the rename is still atomic
  } finally {
    fs.closeSync(dfd);
  }
}

// exportSnapshot: read a snapshot (locked, snapshots-only) and atomically write its
// verifiable envelope to disk with owner-only permissions. A pure read + file write; it
// bumps no counter and mutates no domain table.
export async function exportSnapshot(store, { revision = null, outPath, now } = {}, { fault } = {}) {
  if (typeof outPath !== 'string' || outPath.length === 0) {
    throw new SnapshotVerificationError('export-snapshot requires --out <path>', { out: outPath ?? null });
  }
  const snapshot = await getSnapshot(store, { revision });
  const envelope = buildExportEnvelope(snapshot);
  const content = JSON.stringify(envelope);
  atomicWriteOwnerOnly(outPath, content, { fault });
  return {
    out: outPath,
    projection_revision: snapshot.projection_revision,
    domain_revision: snapshot.domain_revision,
    checksum: snapshot.checksum,
    bytes: Buffer.byteLength(content),
    written_at: now ?? null
  };
}

// verifyExportedSnapshot: the reader-side rejection contract (spec 769). A consumer of an
// exported snapshot file must REFUSE it on any of three integrity failures, and this is
// the single helper that encodes them so every reader rejects identically:
//   * checksum mismatch: the payload does not hash to the envelope's recorded checksum
//     (a tampered or truncated file);
//   * revision regression: the envelope's projection revision is BELOW the reader's last
//     accepted revision (an older or replayed snapshot presented as current);
//   * source path mismatch: the envelope's order source path is not the inbox the reader
//     expects (a foreign home's snapshot).
// Returns { ok: true, projection_revision, checksum } when the file is acceptable.
export function verifyExportedSnapshot(envelope, { expectedSourcePath = null, minRevision = null } = {}) {
  if (envelope === null || typeof envelope !== 'object' || envelope.payload === undefined) {
    throw new SnapshotVerificationError('exported snapshot is malformed (missing payload)', {});
  }
  const recomputed = sha256hex(canonicalJson(envelope.payload));
  if (recomputed !== envelope.checksum) {
    throw new SnapshotVerificationError('exported snapshot checksum mismatch', {
      recorded: envelope.checksum ?? null, recomputed
    });
  }
  if (minRevision !== null && Number(envelope.projection_revision) < Number(minRevision)) {
    throw new SnapshotVerificationError('exported snapshot projection revision regressed', {
      envelope_revision: Number(envelope.projection_revision), min_revision: Number(minRevision)
    });
  }
  if (expectedSourcePath !== null && envelope.order_source_path !== expectedSourcePath) {
    throw new SnapshotVerificationError('exported snapshot order source path mismatch', {
      envelope_path: envelope.order_source_path ?? null, expected_path: expectedSourcePath
    });
  }
  return { ok: true, projection_revision: Number(envelope.projection_revision), checksum: envelope.checksum };
}
