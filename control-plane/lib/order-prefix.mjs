import fs from 'node:fs';
import { sha256hex } from './domain-store.mjs';
import { SnapshotSourceError } from './errors-s6.mjs';

// The stable order prefix protocol (spec 9.1, lines 736-753).
//
// The external canonical captain inbox remains the SOLE order authority; S6 is a
// READ-ONLY consumer of it and NEVER writes or truncates it. Before hashing, `cp
// snapshot` must pin a stable, complete-line prefix so a snapshot never folds a
// half-written final record and never hashes a range the writer was mid-rotating.
//
// This module is pure file+hash logic with NO database access and NO PGlite import
// (owner-guard clean). It reaches the captain inbox only through injectable seams
// (statFile/openRead/lockHook) whose defaults are node:fs, so every test drives an
// ISOLATED fixture inbox and the real captain inbox is never read or locked.
//
// Q1 ruling (lock-optional path is PRIMARY): the real order writer (bin/fm-order.sh)
// does not expose a shared/read lock today, so the protocol's correctness does NOT
// depend on one. The `lockHook` seam is the pluggable place a future writer's shared
// lock plugs in (spec step 1/8: acquire shared, release after the prefix+hash are
// captured); when it is null the protocol still rejects partial finals and retries
// on shrink/rotation, which spec 752 explicitly sanctions. A follow-up
// (order-inbox-shared-lock) tracks growing the writer a real lock; S6 does not touch
// fm-order.sh.

const DEFAULT_MAX_RETRIES = 8;

// One stat reduced to the identity+size tuple the protocol compares (spec step 2/7).
// dev+ino detect rotation / identity change; size detects shrink and bounds the read.
function statTuple(statFile, sourcePath) {
  let st;
  try {
    st = statFile(sourcePath);
  } catch (err) {
    if (err && err.code === 'ENOENT') return null; // absent inbox -> empty prefix
    throw new SnapshotSourceError('captain inbox is unreadable', {
      path: sourcePath, cause: err && err.message ? err.message : String(err)
    });
  }
  return { dev: st.dev, ino: st.ino, size: Number(st.size) };
}

// Read EXACTLY `size` bytes from the head of the file (spec step 3). A concurrent
// append that grows the file past `size` is deliberately NOT read: an append after
// the captured boundary lands in a LATER snapshot only (spec 753). Reads through the
// injectable openRead seam so a test can supply a fixture fd without touching fs.
function readExactly(openRead, sourcePath, size) {
  if (size === 0) return Buffer.alloc(0);
  const fd = openRead(sourcePath);
  try {
    const buf = Buffer.alloc(size);
    let off = 0;
    while (off < size) {
      const n = fs.readSync(fd, buf, off, size - off, off);
      if (n === 0) break; // file shrank under us mid-read; re-stat below catches it
      off += n;
    }
    return buf.subarray(0, off);
  } finally {
    fs.closeSync(fd);
  }
}

// Truncate a raw byte buffer to the last COMPLETE newline-terminated record (spec
// step 4). A trailing partial final record (no closing newline) is rejected by
// dropping it, and its bytes are excluded from both the recorded byte count and the
// hash. A buffer with no newline at all yields an empty (zero-byte) prefix.
function truncateToLastNewline(buf) {
  const nl = buf.lastIndexOf(0x0a); // '\n'
  if (nl === -1) return Buffer.alloc(0);
  return buf.subarray(0, nl + 1);
}

// Parse ONLY complete JSONL records in the stable prefix (spec step 5). Each
// newline-terminated line is one record. A complete-but-malformed line is not
// dropped silently: it is folded as { raw, parse_error: true } so a corrupt inbox
// surfaces in projections instead of vanishing, while the hash still covers the
// exact recorded bytes regardless of parseability.
function parseRecords(prefixBuf) {
  const text = prefixBuf.toString('utf8');
  const records = [];
  for (const line of text.split('\n')) {
    if (line.length === 0) continue;
    try {
      records.push(JSON.parse(line));
    } catch {
      records.push({ raw: line, parse_error: true });
    }
  }
  return records;
}

// Acquire a stable complete-line prefix of the canonical order inbox and return
// { path, bytes, hash, records, present }. `bytes` and `hash` cover EXACTLY the
// recorded prefix range (spec step 6): they are what land in snapshots.order_source_bytes
// and snapshots.order_source_hash, and the parsed records fold into the payload.
//
// The full protocol per attempt (spec 741-750):
//   1. (optional) acquire the writer's shared/read lock via lockHook.
//   2. stat: capture dev, ino, size.  (ENOENT -> valid empty prefix, no error.)
//   3. read exactly `size` bytes.
//   4. truncate to the last complete newline; record that smaller byte count.
//   5. parse only complete records.
//   6. hash exactly the recorded bytes.
//   7. re-stat: if the file shrank, rotated, or changed identity, RETRY.
//   8. release the lock.
// A stable read (no shrink/rotation across the read) returns; persistent instability
// across the bounded retry budget raises SnapshotSourceError (fail loud, never hash a
// torn range). `afterReadHook` is a test-only seam invoked between the read and the
// re-stat so a test can rotate/shrink the REAL fixture file at exactly that cutpoint.
export async function acquireStableOrderPrefix(sourcePath, {
  maxRetries = DEFAULT_MAX_RETRIES,
  lockHook = null,
  statFile = (p) => fs.statSync(p),
  openRead = (p) => fs.openSync(p, 'r'),
  afterReadHook = null
} = {}) {
  if (typeof sourcePath !== 'string' || sourcePath.length === 0) {
    throw new SnapshotSourceError('order source path is required', { path: sourcePath ?? null });
  }

  let lastReason = null;
  for (let attempt = 0; attempt < maxRetries; attempt += 1) {
    let release = null;
    if (typeof lockHook === 'function') {
      release = await lockHook(); // a future writer's shared lock; null-safe when absent
    }
    try {
      const before = statTuple(statFile, sourcePath);
      if (before === null) {
        // Absent inbox: a valid, stable EMPTY prefix (a fleet with no captain orders).
        return { path: sourcePath, bytes: 0, hash: sha256hex(Buffer.alloc(0)), records: [], present: false };
      }

      const raw = readExactly(openRead, sourcePath, before.size);

      if (typeof afterReadHook === 'function') await afterReadHook(attempt);

      const after = statTuple(statFile, sourcePath);
      if (after === null) {
        lastReason = 'rotated_to_absent';
        continue; // the file vanished mid-read (rotation); retry
      }
      if (after.dev !== before.dev || after.ino !== before.ino) {
        lastReason = 'identity_changed';
        continue; // rotation / identity change (spec step 7); retry
      }
      if (after.size < before.size) {
        lastReason = 'shrank';
        continue; // truncation / shrink (spec step 7); retry
      }
      // Stable: the range we read is intact (a pure append that GREW the file is
      // fine - we read only the original `size`, so the growth is a later snapshot's).
      const prefix = truncateToLastNewline(raw);
      const records = parseRecords(prefix);
      return {
        path: sourcePath,
        bytes: prefix.length,
        hash: sha256hex(prefix),
        records,
        present: true
      };
    } finally {
      if (typeof release === 'function') await release();
    }
  }

  throw new SnapshotSourceError(
    `captain inbox prefix did not stabilize after ${maxRetries} attempts`,
    { path: sourcePath, last_reason: lastReason, max_retries: maxRetries }
  );
}
