import path from 'node:path';

// Pure legacy-record -> canonical-schema mapping for `cp migrate-report` (spec
// section 13). NO fs, NO db, NO clock: every function is a deterministic pure
// transform of one legacy record into either a concrete MAPPING proposal (the
// task/run/event rows it would become, with per-field provenance) or an explicit
// FLAG (unmappable / ambiguous / duplicate, with a reason). Nothing is ever silently
// skipped: every reader record gets exactly one disposition here, and each disposition
// carries a lossless `source` (the raw record, its parsed value, and a content digest)
// so a flagged or mapped record is fully auditable from the report artifact alone.
//
// A MAPPING applies NOTHING. It records, per canonical row, the fields sourced from
// the legacy record (`fields`), where each came from (`provenance`), and the
// required-but-unsourced fields that a real migration would still have to resolve or
// synthesize (`unresolved`, each naming the store that would supply it).

// The three sanctioned flag reasons (spec S8: "unmappable/ambiguous/duplicate").
export const FLAG_REASONS = Object.freeze(['unmappable', 'ambiguous', 'duplicate']);

// A lossless, auditable snapshot of the source record folded into every disposition.
function sourceOf(record) {
  return { digest: record.digest, raw: record.raw, value: record.value };
}
function mapped(record, canonical) {
  return { store: record.store, source_ref: record.source_ref, disposition: 'mapped', mapping: { canonical }, source: sourceOf(record) };
}
function flagged(record, reason, detail) {
  return { store: record.store, source_ref: record.source_ref, disposition: 'flagged', flag: { reason, detail }, source: sourceOf(record) };
}

function row(table, key, fields, provenance, unresolved = []) {
  return { table, key, fields, provenance, unresolved };
}

const RUN_IDENTITY_UNRESOLVED = Object.freeze([
  { field: 'bind_nonce', needs: 'synthesized-at-migration (legacy run has no launch identity)' },
  { field: 'launch_marker', needs: 'synthesized-at-migration (legacy run has no marker)' },
  { field: 'launch_dir', needs: 'synthesized-at-migration (legacy run records worktree, not launch_dir)' },
  { field: 'registration_path', needs: 'synthesized-at-migration' },
  { field: 'launch_deadline_at', needs: 'synthesized-at-migration' }
]);

const VALID_KINDS = new Set(['ship', 'scout', 'secondmate']);

function stemFromRef(sourceRef, suffix) {
  const base = path.basename(sourceRef.replace(/#L\d+$/, ''));
  return base.endsWith(suffix) ? base.slice(0, -suffix.length) : base;
}

// --- state/*.meta -> tasks (+ runs) ---------------------------------------------
function mapMeta(record) {
  const taskId = stemFromRef(record.source_ref, '.meta');
  const kind = record.value.kind;
  if (!kind || !VALID_KINDS.has(kind)) {
    return flagged(record, 'unmappable', `meta has no valid kind (kind=${kind ?? 'absent'}); tasks.kind is a checked enum`);
  }
  const rows = [];
  const taskFields = { task_id: taskId, kind };
  const taskProv = { task_id: `${record.source_ref} (filename stem)`, kind: `${record.source_ref} kind=` };
  const repo = typeof record.value.project === 'string' && record.value.project.length > 0
    ? path.basename(record.value.project)
    : undefined;
  if (repo !== undefined) {
    taskFields.repo = repo;
    taskProv.repo = `${record.source_ref} project= (basename)`;
  }
  const taskUnresolved = [
    { field: 'title', needs: 'join backlog/task-lifecycle for the same task_id (meta has no title)' },
    { field: 'status', needs: 'join state-status/backlog for the same task_id' },
    { field: 'task_origin', needs: 'join captain-orders/backlog (order_ref) for the same task_id' }
  ];
  rows.push(row('tasks', taskId, taskFields, taskProv, taskUnresolved));

  if (kind !== 'secondmate' && typeof record.value.worktree === 'string' && record.value.worktree.length > 0) {
    const runFields = {
      task_id: taskId,
      run_generation: 1,
      backend: typeof record.value.backend === 'string' ? record.value.backend : 'tmux',
      worktree: record.value.worktree
    };
    const runProv = {
      task_id: `${record.source_ref} (filename stem)`,
      run_generation: 'synthesized: 1 (legacy has no generations)',
      backend: typeof record.value.backend === 'string' ? `${record.source_ref} backend=` : 'default tmux (legacy meta records harness, not backend)',
      worktree: `${record.source_ref} worktree=`
    };
    if (typeof record.value.harness === 'string') {
      runFields.harness = record.value.harness;
      runProv.harness = `${record.source_ref} harness=`;
    }
    rows.push(row('runs', `${taskId}/1`, runFields, runProv, [...RUN_IDENTITY_UNRESOLVED]));
  }
  return mapped(record, rows);
}

// --- state/*.status line -> task_events -----------------------------------------
const STATUS_EVENT = {
  working: { event_type: 'progress', scope: 'run' },
  blocked: { event_type: 'blocked', scope: 'run' },
  paused: { event_type: 'progress', scope: 'run' },
  'needs-decision': { event_type: 'needs_human', scope: 'run' },
  done: { event_type: 'completed', scope: 'run', outcome: 'success' },
  failed: { event_type: 'failed', scope: 'run', outcome: 'failure' },
  resolved: { event_type: 'unblocked', scope: 'run' }
};
function mapStatus(record) {
  const m = /^([A-Za-z][A-Za-z-]*):\s*(.*)$/.exec(record.value.line);
  if (!m) {
    return flagged(record, 'unmappable', "status line does not match '<state>: <note>'");
  }
  const keyword = m[1].toLowerCase();
  const note = m[2];
  const spec = STATUS_EVENT[keyword];
  if (!spec) {
    return flagged(record, 'ambiguous', `unknown status keyword '${keyword}'; no canonical event_type`);
  }
  const taskId = stemFromRef(record.source_ref, '.status');
  const fields = {
    task_id: taskId,
    event_scope: spec.scope,
    run_generation: 1,
    producer_id: 'crewmate',
    event_type: spec.event_type,
    payload_json: { note }
  };
  const prov = {
    task_id: `${record.source_ref} (filename stem)`,
    event_type: `${record.source_ref} status keyword '${keyword}'`,
    run_generation: 'synthesized: 1 (legacy status is not generation-scoped)',
    producer_id: 'status lines are crewmate-appended (AGENTS.md section 11)',
    'payload_json.note': `${record.source_ref} note`
  };
  if (spec.outcome) {
    fields.outcome = spec.outcome;
    prov.outcome = `derived from status keyword '${keyword}'`;
  }
  return mapped(record, [row('task_events', record.source_ref, fields, prov, [
    { field: 'producer_seq', needs: 'synthesized-at-migration (legacy status is unsequenced)' }
  ])]);
}

// --- state/*.turn-ended -> flag --------------------------------------------------
function mapTurnEnded(record) {
  return flagged(record, 'unmappable', 'turn-boundary marker has no canonical target; superseded by the event stream');
}

// --- curated bullet (backlog.md / done-archive.md) -> tasks ----------------------
function parseBullet(line) {
  const m = /^- (?:\[[ xX]\]|\*\*)\s*([A-Za-z0-9][A-Za-z0-9._-]*?)\*{0,2}\s+-\s+(.*)$/.exec(line);
  if (!m) return null;
  const taskId = m[1];
  const rest = m[2];
  const repoMatch = /\(repo:\s*([^)]+)\)/.exec(rest);
  const repo = repoMatch ? repoMatch[1].trim() : undefined;
  const title = rest.replace(/\s*\(repo:[^)]*\)/, '').replace(/\s*\((?:kind|priority|since|merged|reported):[^)]*\)/g, '').trim();
  return { taskId, title, repo };
}
function mapBullet(record, defaultStatus, joinNote) {
  const parsed = parseBullet(record.value.line);
  if (!parsed) {
    return flagged(record, 'unmappable', `${record.store} bullet has no parseable task id`);
  }
  const section = (record.value.section || '').toLowerCase();
  let status = defaultStatus;
  if (section.startsWith('in flight')) status = 'running';
  else if (section.startsWith('queued')) status = 'queued';
  else if (section.startsWith('done')) status = 'completed';
  else if (section.startsWith('archived')) status = 'archived';
  const fields = { task_id: parsed.taskId, title: parsed.title };
  const prov = {
    task_id: `${record.source_ref} (bullet id)`,
    title: `${record.source_ref} (one-line after id)`
  };
  const unresolved = [
    { field: 'kind', needs: `join state-meta/task-lifecycle for the same task_id (${joinNote})` },
    { field: 'task_origin', needs: 'join captain-orders (order_ref) for the same task_id' }
  ];
  if (parsed.repo !== undefined) { fields.repo = parsed.repo; prov.repo = `${record.source_ref} (repo: ...)`; }
  if (status !== undefined) { fields.status = status; prov.status = `${record.source_ref} section '${record.value.section ?? ''}'`; }
  else unresolved.push({ field: 'status', needs: `section '${record.value.section ?? ''}' has no canonical status mapping` });
  return mapped(record, [row('tasks', parsed.taskId, fields, prov, unresolved)]);
}
function mapBacklog(record) {
  return mapBullet(record, undefined, 'backlog row omits kind here');
}
function mapDoneArchive(record) {
  // done-archive.md holds pruned finished tasks; absent a recognized section, treat as archived.
  return mapBullet(record, 'archived', 'archive row omits kind');
}

// --- state/task-lifecycle.jsonl -> task_events ----------------------------------
const LIFECYCLE_EVENT = {
  recorded: { event_type: 'created', scope: 'task' },
  closure_evidence: { event_type: 'progress', scope: 'run' },
  closed: { event_type: 'archived', scope: 'task' }
};
function mapLifecycle(record, ctx) {
  if (record.value.__malformed) {
    return flagged(record, 'unmappable', `malformed JSON: ${record.value.error}`);
  }
  const eventId = record.value.eventId;
  if (typeof eventId === 'string' && eventId.length > 0) {
    if (ctx.lifecycleEventIds.has(eventId)) {
      return flagged(record, 'duplicate', `eventId ${eventId} already seen at ${ctx.lifecycleEventIds.get(eventId)}`);
    }
    ctx.lifecycleEventIds.set(eventId, record.source_ref);
  }
  const taskId = record.value.id;
  if (typeof taskId !== 'string' || taskId.length === 0) {
    return flagged(record, 'unmappable', 'lifecycle record has no task id');
  }
  const spec = LIFECYCLE_EVENT[record.value.event];
  if (!spec) {
    return flagged(record, 'ambiguous', `unknown lifecycle event '${record.value.event}'; no canonical event_type`);
  }
  const fields = {
    task_id: taskId,
    event_scope: spec.scope,
    event_type: spec.event_type,
    producer_id: record.value.actor === 'firstmate' ? 'firstmate' : 'coordinator'
  };
  const prov = {
    task_id: `${record.source_ref} id`,
    event_type: `${record.source_ref} event='${record.value.event}'`,
    producer_id: `${record.source_ref} actor='${record.value.actor ?? ''}'`
  };
  if (typeof eventId === 'string') { fields.event_id = eventId; prov.event_id = `${record.source_ref} eventId`; }
  if (spec.scope === 'run') fields.run_generation = 1;
  return mapped(record, [row('task_events', eventId || record.source_ref, fields, prov, [
    { field: 'producer_seq', needs: 'synthesized-at-migration (legacy lifecycle is unsequenced)' }
  ])]);
}

// --- state/task-runs.jsonl -> runs (+ terminal task_events) ----------------------
const RUN_OUTCOME_TERMINAL = { landed: { event_type: 'completed', outcome: 'success' }, failed: { event_type: 'failed', outcome: 'failure' } };
function mapTaskRun(record, ctx) {
  if (record.value.__malformed) {
    return flagged(record, 'unmappable', `malformed JSON: ${record.value.error}`);
  }
  const taskId = record.value.task;
  if (typeof taskId !== 'string' || taskId.length === 0) {
    return flagged(record, 'unmappable', 'task_run record has no task id');
  }
  const dupKey = `${taskId} ${record.value.spawned_at ?? ''}`;
  if (ctx.taskRunKeys.has(dupKey)) {
    return flagged(record, 'duplicate', `task run for ${taskId} spawned_at=${record.value.spawned_at ?? '?'} already seen at ${ctx.taskRunKeys.get(dupKey)}`);
  }
  ctx.taskRunKeys.set(dupKey, record.source_ref);
  const gen = (ctx.taskRunGen.get(taskId) || 0) + 1;
  ctx.taskRunGen.set(taskId, gen);

  const outcome = record.value.outcome;
  const term = RUN_OUTCOME_TERMINAL[outcome];
  const runFields = {
    task_id: taskId,
    run_generation: gen,
    status: term ? term.event_type : 'open',
    backend: 'tmux',
    worktree: record.value.worktree,
    harness: record.value.harness
  };
  const runProv = {
    task_id: `${record.source_ref} task`,
    run_generation: `synthesized: occurrence #${gen} of ${taskId} in ledger order`,
    status: term ? `derived from outcome='${outcome}'` : `no terminal outcome (outcome='${outcome ?? 'absent'}')`,
    backend: 'default tmux (legacy ledger records harness, not backend)',
    worktree: `${record.source_ref} worktree`,
    harness: `${record.source_ref} harness`
  };
  const rows = [row('runs', `${taskId}/${gen}`, runFields, runProv, [...RUN_IDENTITY_UNRESOLVED])];
  if (term) {
    rows.push(row('task_events', `${record.source_ref}#terminal`, {
      task_id: taskId,
      event_scope: 'run',
      run_generation: gen,
      producer_id: 'coordinator',
      event_type: term.event_type,
      outcome: term.outcome
    }, {
      task_id: `${record.source_ref} task`,
      event_type: `derived from outcome='${outcome}'`,
      outcome: `derived from outcome='${outcome}'`
    }, [{ field: 'producer_seq', needs: 'synthesized-at-migration' }]));
  }
  return mapped(record, rows);
}

// --- in-home legacy captain-orders.jsonl -> tasks.order_ref (old id/backlogId schema) ---
function mapLegacyOrder(record, ctx) {
  if (record.value.__malformed) {
    return flagged(record, 'unmappable', `malformed JSON: ${record.value.error}`);
  }
  const orderId = record.value.id;
  if (typeof orderId !== 'string' || orderId.length === 0) {
    return flagged(record, 'unmappable', 'order record has no id');
  }
  if (ctx.legacyOrderIds.has(orderId)) {
    return flagged(record, 'duplicate', `order id ${orderId} already seen at ${ctx.legacyOrderIds.get(orderId)}`);
  }
  ctx.legacyOrderIds.set(orderId, record.source_ref);
  const backlogId = record.value.backlogId;
  if (typeof backlogId !== 'string' || backlogId.length === 0) {
    if (record.value.status === 'dismissed') {
      return flagged(record, 'unmappable', 'dismissed order not linked to any task (no backlogId)');
    }
    return flagged(record, 'ambiguous', `order ${orderId} has no linked task id (status='${record.value.status ?? '?'}')`);
  }
  return mapped(record, [row('tasks', backlogId, {
    task_id: backlogId,
    task_origin: 'captain_order',
    order_ref: orderId
  }, {
    task_id: `${record.source_ref} backlogId`,
    task_origin: 'order presence implies captain_order origin',
    order_ref: `${record.source_ref} id`
  }, [])]);
}

// --- authoritative external order ledger -> tasks.order_ref (firstmate/captain-order/v1) ---
// The authoritative inbox is an append-only EVENT ledger: many events per order_id, new
// schema (order_id / linked_task_ids). Each line is one legacy record. Exact-line replay
// duplicates are flagged; an event that links task(s) proposes the order_ref onto the first
// linked task; an unlinked event is ambiguous (or unmappable when the order is dismissed).
function mapAuthoritativeOrder(record, ctx) {
  if (record.value.__malformed) {
    return flagged(record, 'unmappable', `malformed JSON: ${record.value.error}`);
  }
  if (ctx.authOrderLines.has(record.digest)) {
    return flagged(record, 'duplicate', `identical order event already seen at ${ctx.authOrderLines.get(record.digest)}`);
  }
  ctx.authOrderLines.set(record.digest, record.source_ref);
  const orderId = record.value.order_id ?? record.value.id;
  if (typeof orderId !== 'string' || orderId.length === 0) {
    return flagged(record, 'unmappable', 'authoritative order event has no order_id');
  }
  const linked = Array.isArray(record.value.linked_task_ids)
    ? record.value.linked_task_ids.filter((x) => typeof x === 'string' && x.length > 0)
    : (typeof record.value.backlogId === 'string' && record.value.backlogId.length > 0 ? [record.value.backlogId] : []);
  if (linked.length === 0) {
    if (record.value.status === 'dismissed') {
      return flagged(record, 'unmappable', `dismissed order ${orderId} event links no task`);
    }
    return flagged(record, 'ambiguous', `order ${orderId} event '${record.value.event ?? '?'}' links no task (linked_task_ids empty)`);
  }
  return mapped(record, [row('tasks', linked[0], {
    task_id: linked[0],
    task_origin: 'captain_order',
    order_ref: orderId
  }, {
    task_id: `${record.source_ref} linked_task_ids[0]`,
    task_origin: 'authoritative order link implies captain_order origin',
    order_ref: `${record.source_ref} order_id`
  }, linked.length > 1 ? [{ field: 'order_ref', needs: `order ${orderId} links ${linked.length} tasks: ${linked.join(', ')}; one task_events/order_ref proposal per link` }] : [])]);
}

// --- Bridge History projection -> flag (derived; never a NEW canonical row) -------
function mapBridgeHistory(record) {
  if (record.value && record.value.__malformed) {
    return flagged(record, 'unmappable', `malformed Bridge History record: ${record.value.error}`);
  }
  // Bridge History is a DERIVED re-projection over the authoritative sources (backlog,
  // done-archive, task-runs, bugs, orders). Migrating it as new rows would double-count;
  // the canonical rows come from the sources it projects, already enumerated above. So every
  // projection record is a duplicate by construction - enumerated, never omitted, never mapped.
  const id = (record.value && (record.value.id || record.value.taskId || record.value.key)) || '(unkeyed)';
  return flagged(record, 'duplicate', `derived Bridge History projection record for '${id}'; re-projects already-enumerated authoritative sources, contributes no new canonical row`);
}

const MAPPERS = {
  'state-meta': mapMeta,
  'state-status': mapStatus,
  'state-turn-ended': mapTurnEnded,
  backlog: mapBacklog,
  'done-archive': mapDoneArchive,
  'task-lifecycle': mapLifecycle,
  'task-runs': mapTaskRun,
  'captain-orders': mapLegacyOrder,
  'authoritative-orders': mapAuthoritativeOrder,
  'bridge-history': mapBridgeHistory
};

// Fresh per-report duplicate-detection state. Order-stable: because records arrive in
// the reader's deterministic order, "first occurrence" is well-defined and repeatable.
export function newMappingContext() {
  return {
    lifecycleEventIds: new Map(),
    taskRunKeys: new Map(),
    taskRunGen: new Map(),
    legacyOrderIds: new Map(),
    authOrderLines: new Map()
  };
}

// Map ONE legacy record to its disposition. Total: every record returns exactly one
// mapped-or-flagged result; an unknown store is itself an explicit flag, never a skip.
export function mapRecord(record, ctx) {
  const fn = MAPPERS[record.store];
  if (!fn) return flagged(record, 'unmappable', `no mapper for legacy store '${record.store}'`);
  return fn(record, ctx);
}
