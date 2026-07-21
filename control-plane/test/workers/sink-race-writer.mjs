// Concurrency-probe worker for t_sink_concurrent_redelivery_one_result (qa-s4-q67
// finding 2). This process is the "pausing" caller in a two-caller race for the same
// event_id: it drives FileLedgerSink.apply but, via the test-only faultBeforeCommit
// hook, stops AFTER its temp file is written+fsync'd and BEFORE the atomic link commit.
// It signals the pause by creating CP_PAUSE_FILE, then blocks SYNCHRONOUSLY until the
// parent creates CP_RELEASE_FILE. The parent, meanwhile, applies the same event_id and
// wins the link race. When released, this caller's link hits EEXIST and it must return
// the WINNER's durable prior result, not its own. It prints its apply result as JSON.
import fs from 'node:fs';
import { FileLedgerSink } from '../../lib/sinks.mjs';

const sink = new FileLedgerSink({ dir: process.env.CP_SINK_DIR });
const eventId = process.env.CP_EVENT_ID;
const sinkKind = process.env.CP_SINK_KIND || 'wake';
const pauseFile = process.env.CP_PAUSE_FILE;
const releaseFile = process.env.CP_RELEASE_FILE;

// Synchronous sleep so the pause can block inside the (synchronous) commit hook.
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

const faultBeforeCommit = () => {
  fs.writeFileSync(pauseFile, 'paused');
  // Block until the parent has applied and released us (bounded so a stuck test exits).
  for (let i = 0; i < 400 && !fs.existsSync(releaseFile); i += 1) sleepSync(25);
};

const res = await sink.apply(sinkKind, eventId, { caller: 'A' }, { faultBeforeCommit });
process.stdout.write(JSON.stringify(res));
process.exit(0);
