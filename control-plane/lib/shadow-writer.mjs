import nodeFs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { PgliteLocalStore } from './pglite-local-store.mjs';
import { createTask, appendEvent, taskHead } from './domain-store.mjs';
import { completeRun, failRun } from './domain-store-s2.mjs';
import { cleanupIntent, cleanupFinish } from './domain-store-s3.mjs';
import { archiveTask } from './domain-store-archive.mjs';
import { readOnlyQuery } from './cw1-readonly.mjs';
import { recordAnnotation } from './cw2-annotations.mjs';

// CW2 SHADOW WRITER (spec section 13 posture; ORD-256 CW2). A small fire-and-forget
// mirror that firstmate's lifecycle chokepoints invoke to write control-plane events in
// PARALLEL with the legacy operation, while the legacy stores remain the operational
// authority (cutover CW4 flips authority, not this stage).
//
// THREE HARD CONTRACTS, each load-bearing and each regression-tested:
//
//  1. NEVER BLOCK OR FAIL A LEGACY OPERATION. Every method is total: it catches every
//     error - including a store that will not open - logs it to the divergence file, and
//     returns a structured outcome. It NEVER throws to its caller. The lifecycle chokepoint
//     also backgrounds the invocation (bin/fm-cp-shadow.sh), so even a slow or wedged
//     shadow write cannot delay the legacy op. Two independent layers, because a mirror
//     that can break the thing it mirrors is worse than no mirror.
//
//  2. NO FABRICATED RUNS. There is no real `cp-launch` spawning yet, so this stage never
//     calls begin-run and never creates a run row. A newly filed task mirrors as `queued`
//     via create-task and nothing more; a dispatch mirrors as a queued ANNOTATION, not a
//     begin-run (the S8/CW1 anti-ghost rule: an imported/mirrored run with no live endpoint
//     is a ghost). Run-scoped actions (a status transition, completion, teardown, archive)
//     drive their landed verb ONLY when a real run generation ALREADY exists for the task;
//     absent that, they record an audit annotation (lib/cw2-annotations.mjs). The writer
//     therefore never manufactures the run its own later verbs would need - it only ever
//     acts on runs some real launch path created.
//
//  3. IDEMPOTENT BY DETERMINISTIC COMMAND-ID. Every landed-verb mirror uses a command-id
//     derived only from the logical action (verb, task, generation, and a stable hash of
//     the payload), so a double-mirror hits the store's command_results idempotency
//     pre-check and REPLAYS rather than double-applying. Every annotation uses the same
//     derived id as its ON CONFLICT primary key. Mirroring the same lifecycle event twice
//     is always safe.
//
// The mirror maps each chokepoint to its landed verb (create-task, event, complete/fail,
// cleanup-intent/finish, archive), degrading to an annotation whenever the live-path
// precondition (a real run generation) is absent. That degrade is the honest pre-cp-launch
// representation, not a workaround: it records the signal without lying about runs.

const CMD_PREFIX = 'cp-shadow';

// Event producers the store accepts; the shadow writer speaks as firstmate, the actor that
// observes and records these lifecycle transitions.
const DEFAULT_ACTOR = 'firstmate';

// Generic run-scoped status events a caller may append through `event` (the store's
// CALLER_APPENDABLE set). `progress` changes no status; the rest are legal only from
// specific states and the store enforces that - an illegal one is caught and logged as a
// genuine divergence, never forced.
const STATUS_EVENTS = new Set(['progress', 'blocked', 'unblocked', 'waiting_firstmate', 'needs_human', 'rework']);

function nowIso() {
  return new Date().toISOString();
}

// Stable short hash of a payload object for command-id derivation. Canonicalized by sorted
// keys so key order never changes the id (a double-mirror with the same logical content is
// the same command).
function payloadHash(obj) {
  const canonical = canonicalize(obj ?? {});
  return crypto.createHash('sha256').update(canonical).digest('hex').slice(0, 16);
}

function canonicalize(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value ?? null);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalize(value[k])}`).join(',')}}`;
}

// The shadow writer holds a store HANDLE (opened lazily, once), not an open PGlite - each
// landed verb opens+closes PGlite under the per-home flock itself. `storeFactory` is
// injectable so a test can supply a store that fails to prove contract 1.
export function createShadowWriter({
  dataDir,
  divergenceLog,
  env = process.env,
  now = nowIso,
  actor = DEFAULT_ACTOR,
  storeFactory,
  expectedHomeUuid,
  // Fail-closed store identity (finding 5). ON for real usage; OFF when a test injects its
  // own storeFactory (the test owns the store's existence/identity).
  verifyStoreIdentity = storeFactory === undefined
} = {}) {
  if (typeof dataDir !== 'string' || dataDir.length === 0) {
    throw new Error('createShadowWriter requires a dataDir (this is the ONE thrown surface; mirror methods never throw)');
  }
  const clock = typeof now === 'function' ? now : () => now;
  const resolvedExpectedHomeUuid = typeof expectedHomeUuid === 'string' && expectedHomeUuid.length > 0
    ? expectedHomeUuid
    : (typeof env.CP_SHADOW_HOME_UUID === 'string' && env.CP_SHADOW_HOME_UUID.length > 0 ? env.CP_SHADOW_HOME_UUID : undefined);
  const makeStore = typeof storeFactory === 'function'
    ? storeFactory
    : () => PgliteLocalStore.create({ dataDir, env });

  let store = null;
  let opened = false;
  let identityChecked = false;

  function getStore() {
    if (!opened) {
      store = makeStore();
      opened = true;
    }
    if (!store) throw new Error('shadow store handle is null');
    return store;
  }

  // Fail-closed on store identity (finding 5). A shadow write must target an ALREADY
  // initialized control-plane store, never implicitly create a second one at a mistyped or
  // unmounted path. The filesystem-existence check runs BEFORE any open (opening a
  // nonexistent PGlite path would create the store), and the home_uuid read confirms it is a
  // real, initialized control-plane store - optionally pinned to an expected identity.
  async function ensureStoreReady(s) {
    if (identityChecked || !verifyStoreIdentity) { identityChecked = true; return; }
    if (!nodeFs.existsSync(dataDir)) {
      throw new Error(`shadow store path does not exist: ${dataDir} (refusing to create a store in shadow mode - fail closed)`);
    }
    let homeUuid = null;
    try {
      const rows = await readOnlyQuery(s, "SELECT value FROM schema_meta WHERE key = 'home_uuid'");
      homeUuid = rows.length > 0 ? rows[0].value : null;
    } catch {
      homeUuid = null;
    }
    if (!homeUuid) {
      throw new Error(`shadow store at ${dataDir} is not an initialized control-plane store (no home_uuid) - fail closed`);
    }
    if (resolvedExpectedHomeUuid && homeUuid !== resolvedExpectedHomeUuid) {
      throw new Error(`shadow store home_uuid mismatch at ${dataDir}: expected ${resolvedExpectedHomeUuid}, found ${homeUuid} - fail closed`);
    }
    identityChecked = true;
  }

  // Resolve a prior committed command result by deterministic command-id (finding 2). This
  // is read BEFORE any mutable revision/sequence/state is derived, so a double-mirror of the
  // same logical verb REPLAYS the original result instead of re-deriving a now-different
  // sequence (which the command envelope would reject as an idempotency conflict) or
  // selecting a different branch (annotation) after the first mutation closed the run.
  async function readCommandResult(s, commandId) {
    try {
      const present = await readOnlyQuery(s, "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'command_results'");
      if (present.length === 0) return null;
      const rows = await readOnlyQuery(s, 'SELECT result_json FROM command_results WHERE command_id = $1', [commandId]);
      if (rows.length === 0) return null;
      const raw = rows[0].result_json;
      return typeof raw === 'string' ? JSON.parse(raw) : raw;
    } catch {
      return null;
    }
  }

  // Best-effort divergence log append. This is the LAST-RESORT channel and is itself total:
  // if the log cannot be written, the failure is swallowed (a mirror must never fail its
  // caller, and cannot fall back to throwing from its own error path).
  function logDivergence(entry) {
    if (typeof divergenceLog !== 'string' || divergenceLog.length === 0) return;
    try {
      const dir = path.dirname(divergenceLog);
      if (!nodeFs.existsSync(dir)) {
        nodeFs.mkdirSync(dir, { recursive: true });
        try { nodeFs.chmodSync(dir, 0o700); } catch { /* best effort */ }
      }
      const line = `${JSON.stringify({ ts: clock(), ...entry })}\n`;
      nodeFs.appendFileSync(divergenceLog, line, { mode: 0o600 });
    } catch {
      // A mirror never throws, not even from its own logging. Swallow.
    }
  }

  // The never-throw envelope every mirror method runs inside. `fn(store)` does the work and
  // returns a partial outcome; any throw is caught, logged as a divergence, and folded into
  // a structured failed outcome. The caller (a lifecycle chokepoint) sees a value, never an
  // exception.
  async function mirror(action, taskId, fn) {
    try {
      const s = getStore();
      await ensureStoreReady(s);
      const out = await fn(s);
      return { ok: true, action, task_id: taskId, ...out };
    } catch (err) {
      const reason = err && err.message ? err.message : String(err);
      logDivergence({ kind: 'shadow_write_error', action, task_id: taskId, reason });
      return { ok: false, action, task_id: taskId, mode: 'error', error: reason };
    }
  }

  // Read the task head, or null if the task is absent from the store (the common
  // pre-mirror-of-file-not-yet-created case). Never throws out of the decision path.
  async function readHead(s, taskId) {
    try {
      return await taskHead(s, { taskId });
    } catch {
      return null;
    }
  }

  // Read the run row at a generation (the live-path precondition). Uses the SELECT-only
  // read-only seam so the decision read can never mutate.
  async function readRun(s, taskId, generation) {
    if (!Number.isInteger(generation) || generation < 1) return null;
    const rows = await readOnlyQuery(
      s,
      'SELECT status, closed_at, cleanup_state FROM runs WHERE task_id = $1 AND run_generation = $2',
      [taskId, generation]
    );
    return rows.length > 0 ? rows[0] : null;
  }

  // Next producer sequence for an event on (task, generation): last_seq + 1, or 1 when the
  // producer has no prior event on that generation.
  async function nextSeq(s, taskId, generation, producer) {
    const rows = await readOnlyQuery(
      s,
      'SELECT last_seq FROM producer_highwater WHERE task_id = $1 AND run_generation = $2 AND producer_id = $3',
      [taskId, generation, producer]
    );
    return (rows.length > 0 ? Number(rows[0].last_seq) : 0) + 1;
  }

  async function annotate(s, taskId, action, detail, cmdKey) {
    const commandId = `${CMD_PREFIX}:annot:${action}:${taskId}:${cmdKey}`;
    const res = await recordAnnotation(s, {
      commandId, taskId, action, detail: detail ?? null, source: CMD_PREFIX, now: clock()
    });
    return { mode: 'annotation', annotation_written: res.written, command_id: commandId };
  }

  return {
    // task filed -> create-task (queued). The one unconditional live-path write: a filed
    // task is legally `queued` with no run. Idempotent by command-id; if the task already
    // exists (e.g. from the CW1 migration) create-task's own guard rejects and that is
    // logged as a benign divergence, never propagated.
    async taskFiled({ taskId, kind, title, repo, origin, orderRef, internalReason } = {}) {
      return mirror('task-filed', taskId, async (s) => {
        const resolvedOrigin = origin || (orderRef ? 'captain_order' : 'internal');
        const params = {
          taskId,
          kind,
          title: title || taskId,
          repo,
          origin: resolvedOrigin,
          commandId: `${CMD_PREFIX}:create-task:${taskId}`
        };
        if (resolvedOrigin === 'captain_order') {
          params.orderRef = orderRef;
        } else {
          params.internalReason = internalReason || 'shadow-mirrored from legacy fleet lifecycle (CW2 shadow run)';
        }
        const result = await createTask(s, params);
        return { mode: 'verb', verb: 'create-task', result };
      });
    },

    // dispatched (queued -> spawning boundary). Constraint 2: this is NOT a begin-run. There
    // is no real cp-launch spawning, so mirroring a run here would fabricate a ghost. It
    // records a queued dispatch ANNOTATION instead.
    async dispatched({ taskId, detail } = {}) {
      return mirror('dispatched', taskId, async (s) =>
        annotate(s, taskId, 'dispatched', detail ?? null, payloadHash(detail ?? {})));
    },

    // status transition -> event, when a real run generation is OPEN; else annotation. The
    // writer never opens the run itself (no fabricated runs), so this fires as a real event
    // only once some launch path has produced an open generation. Finding 2: the command
    // result is resolved BEFORE the mutable sequence is derived, so a double-mirror replays.
    async statusTransition({ taskId, status, detail } = {}) {
      return mirror(`status:${status}`, taskId, async (s) => {
        if (!STATUS_EVENTS.has(status)) {
          // Not a caller-appendable status: record it as an annotation rather than attempt
          // an illegal event.
          return annotate(s, taskId, `status:${status}`, detail ?? null, payloadHash({ status, detail }));
        }
        const head = await readHead(s, taskId);
        const gen = head ? head.current_generation : 0;
        if (head && gen >= 1) {
          const payload = detail && typeof detail === 'object' ? detail : (detail ? { note: detail } : {});
          const commandId = `${CMD_PREFIX}:event:${taskId}:${gen}:${status}:${payloadHash(payload)}`;
          const prior = await readCommandResult(s, commandId);
          if (prior) return { mode: 'verb', verb: 'event', result: prior, replayed: true };
          const run = await readRun(s, taskId, gen);
          if (run && run.closed_at === null) {
            const seq = await nextSeq(s, taskId, gen, actor);
            const result = await appendEvent(s, {
              taskId, generation: gen, eventType: status, producer: actor, seq,
              expectedRevision: head.revision, payload, commandId
            });
            return { mode: 'verb', verb: 'event', result };
          }
        }
        return annotate(s, taskId, `status:${status}`, detail ?? null, payloadHash({ status, detail }));
      });
    },

    // completion -> complete, when a real open run generation exists; else annotation. The
    // deterministic complete command-id is resolved first, so a retry replays even after the
    // first complete closed the run (which would otherwise flip to the annotation branch).
    async completed({ taskId, evidence, detail } = {}) {
      return mirror('completed', taskId, async (s) => {
        const head = await readHead(s, taskId);
        const gen = head ? head.current_generation : 0;
        if (head && gen >= 1) {
          const commandId = `${CMD_PREFIX}:complete:${taskId}:${gen}`;
          const prior = await readCommandResult(s, commandId);
          if (prior) return { mode: 'verb', verb: 'complete', result: prior, replayed: true };
          const run = await readRun(s, taskId, gen);
          if (run && run.closed_at === null) {
            const seq = await nextSeq(s, taskId, gen, actor);
            const result = await completeRun(s, {
              taskId, generation: gen, expectedRevision: head.revision, outcome: 'success',
              producer: actor, seq, evidence: evidence ?? { shadow: true }, commandId
            });
            return { mode: 'verb', verb: 'complete', result };
          }
        }
        return annotate(s, taskId, 'completed', detail ?? evidence ?? null, payloadHash({ evidence, detail }));
      });
    },

    // failure -> fail, when a real open run generation exists; else annotation.
    async failed({ taskId, reason, detail } = {}) {
      return mirror('failed', taskId, async (s) => {
        const head = await readHead(s, taskId);
        const gen = head ? head.current_generation : 0;
        if (head && gen >= 1) {
          const commandId = `${CMD_PREFIX}:fail:${taskId}:${gen}`;
          const prior = await readCommandResult(s, commandId);
          if (prior) return { mode: 'verb', verb: 'fail', result: prior, replayed: true };
          const run = await readRun(s, taskId, gen);
          if (run && run.closed_at === null) {
            const seq = await nextSeq(s, taskId, gen, actor);
            const result = await failRun(s, {
              taskId, generation: gen, expectedRevision: head.revision,
              reason: reason || 'shadow-mirrored failure', producer: actor, seq, commandId
            });
            return { mode: 'verb', verb: 'fail', result };
          }
        }
        return annotate(s, taskId, 'failed', detail ?? reason ?? null, payloadHash({ reason, detail }));
      });
    },

    // teardown -> cleanup-intent + cleanup-finish, WHERE APPLICABLE: only when a terminal
    // run generation with cleanup still pending exists. The shadow effect is "confirmed
    // absent" - a mirrored teardown asserts the (never-really-launched) pane is gone, which
    // for shadow-mirrored work it is. Absent an applicable run, an annotation. The cleanup-
    // finish command-id is resolved first, so a retry replays after cleanup completed.
    async teardown({ taskId, detail } = {}) {
      return mirror('teardown', taskId, async (s) => {
        const head = await readHead(s, taskId);
        const gen = head ? head.current_generation : 0;
        if (head && gen >= 1) {
          const finishId = `${CMD_PREFIX}:cleanup-finish:${taskId}:${gen}`;
          const prior = await readCommandResult(s, finishId);
          if (prior) return { mode: 'verb', verb: 'cleanup', result: { finish: prior }, replayed: true };
          const run = await readRun(s, taskId, gen);
          const terminalRun = run && (run.status === 'completed' || run.status === 'failed');
          if (terminalRun && run.cleanup_state !== 'cleaned') {
            const intent = await cleanupIntent(s, {
              taskId, generation: gen, expectedRevision: head.revision,
              commandId: `${CMD_PREFIX}:cleanup-intent:${taskId}:${gen}`
            });
            const headAfter = await readHead(s, taskId);
            const finish = await cleanupFinish(s, {
              taskId, generation: gen, expectedRevision: headAfter ? headAfter.revision : head.revision,
              effectResult: { confirmed_absent: true, shadow: true }, commandId: finishId
            });
            return { mode: 'verb', verb: 'cleanup', result: { intent, finish } };
          }
        }
        return annotate(s, taskId, 'teardown', detail ?? null, payloadHash({ detail }));
      });
    },

    // archive -> archive, WHERE APPLICABLE: only when the task is terminal with its terminal
    // outbox acked and cleanup cleaned (the store enforces all three). Absent that legal
    // precondition, an annotation - the writer never synthesizes the ack/cleanup chain to
    // force an archive (the same reason CW1 residualized archived history: it must not fake
    // the live delivery/cleanup path).
    async archived({ taskId, detail } = {}) {
      return mirror('archived', taskId, async (s) => {
        const head = await readHead(s, taskId);
        if (head) {
          // Resolve the archive command FIRST: after a successful archive the status is
          // 'archived', which would otherwise fall through to the annotation branch on a
          // retry instead of replaying the archive (finding 2).
          const commandId = `${CMD_PREFIX}:archive:${taskId}`;
          const prior = await readCommandResult(s, commandId);
          if (prior) return { mode: 'verb', verb: 'archive', result: prior, replayed: true };
          if (head.status === 'completed' || head.status === 'failed') {
            const result = await archiveTask(s, { taskId, expectedRevision: head.revision, commandId });
            return { mode: 'verb', verb: 'archive', result };
          }
        }
        return annotate(s, taskId, 'archived', detail ?? null, payloadHash({ detail }));
      });
    },

    async close() {
      if (opened && store && typeof store.close === 'function') {
        await store.close();
      }
      opened = false;
      store = null;
    }
  };
}
