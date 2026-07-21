import fs from 'node:fs';
import path from 'node:path';

// The isolated captain-order inbox for one E2E run (spec section 11: "isolated order inbox
// with a real ORD reference"). NEVER the real captain inbox - it lives entirely inside the
// fixture root the runner created, and the runner asserts that at start. The snapshot's
// order-source hash is taken over this file's stable complete-line prefix, so the
// "order source hash matches the isolated inbox stable prefix" final assertion closes over
// exactly this writer's output.

// A real ORD-shaped record. The reference is the same ORD-<n> shape a genuine order
// carries, so a task created with origin 'captain_order' can cite it (order_ref) and the
// projection/snapshot order trail is realistic rather than synthetic noise.
export function ordRecord(n, text = `E2E order ${n}`) {
  return { id: `ORD-${n}`, kind: 'ship', text, received_at: '2026-07-21T00:00:00Z' };
}

// Create the inbox file with an initial (possibly empty) set of complete JSONL records.
// Every record is newline-terminated so the whole file is a stable complete-line prefix.
export function writeInbox(inboxPath, records = []) {
  const body = records.map((r) => JSON.stringify(r)).join('\n') + (records.length ? '\n' : '');
  fs.mkdirSync(path.dirname(inboxPath), { recursive: true });
  fs.writeFileSync(inboxPath, body);
  return inboxPath;
}

// Append one complete, newline-terminated record. Used to prove the snapshot's order hash
// tracks the inbox as it grows.
export function appendOrder(inboxPath, record) {
  fs.appendFileSync(inboxPath, JSON.stringify(record) + '\n');
  return inboxPath;
}
