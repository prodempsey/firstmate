import path from 'node:path';

// Pure legacy-record -> canonical-schema mapping for `cp migrate-report` (spec
// section 13). NO fs, NO db, NO clock: every function is a deterministic pure
// transform of one legacy record into either a concrete MAPPING proposal (the
// task/run/event rows it would become, with per-field provenance) or an explicit
// FLAG (unmappable / ambiguous / duplicate, with a reason). Nothing is ever silently
// skipped, so `mapped + flagged === discovered` holds by construction: every reader
// record gets exactly one disposition here.
//
// A MAPPING applies NOTHING. It records, per canonical row, the fields sourced from
// the legacy record (`fields`), where each came from (`provenance`), and the
// required-but-unsourced fields that a real migration would still have to resolve or
// synthesize (`unresolved`, each naming the store that would supply it). That is a
// concrete proposal with field provenance, not an edit.

// The three sanctioned flag reasons (spec S8: "unmappable/ambiguous/duplicate").
export const FLAG_REASONS = Object.freeze(['unmappable', 'ambiguous', 'duplicate']);

function mapped(record, canonical) {
  return { store: record.store, source_ref: record.source_ref, disposition: 'mapped', mapping: { canonical } };
}
function flagged(record, reason, detail) {
  return { store: record.store, source_ref: record.source_ref, disposition: 'flagged', flag: { reason, detail } };
}

// A canonical-row proposal: which table, a stable natural key, the sourced fields,
// their provenance, and the unresolved required fields.
function row(table, key, fields, provenance, unresolved = []) {
  return { table, key, fields, provenance, unresolved };
}

// Legacy runs carry no CAS identity (bind_nonce, launch_marker, endpoint/pane/pid,
// deadlines). A migration would synthesize them; the proposal says so honestly rather
// than inventing values, so a reviewer sees exactly what is real vs. what is minted.
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

  // A secondmate is a persistent supervisor, not a run: no runs row (spec/AGENTS s6).
  // Any other kind with a worktree implies exactly one legacy run -> generation 1.
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
  // A turn-boundary touch marker has no canonical counterpart: turn-end is carried by
  // the consumer/event stream in the control plane, not a legacy marker file.
  return flagged(record, 'unmappable', 'turn-boundary marker has no canonical target; superseded by the event stream');
}

// --- data/backlog.md bullet -> tasks --------------------------------------------
function mapBacklog(record) {
  const m = /^- (?:\[[ xX]\]|\*\*)\s*([A-Za-z0-9][A-Za-z0-9._-]*?)\*{0,2}\s+-\s+(.*)$/.exec(record.value.line);
  if (!m) {
    return flagged(record, 'unmappable', 'backlog bullet has no parseable task id');
  }
  const taskId = m[1];
  let rest = m[2];
  const repoMatch = /\(repo:\s*([^)]+)\)/.exec(rest);
  const repo = repoMatch ? repoMatch[1].trim() : undefined;
  const title = rest.replace(/\s*\(repo:[^)]*\)/, '').replace(/\s*\((?:kind|priority|since|merged|reported):[^)]*\)/g, '').trim();
  const section = (record.value.section || '').toLowerCase();
  let status;
  if (section.startsWith('in flight')) status = 'running';
  else if (section.startsWith('queued')) status = 'queued';
  else if (section.startsWith('done')) status = 'completed';
  const fields = { task_id: taskId, title };
  const prov = {
    task_id: `${record.source_ref} (bullet id)`,
    title: `${record.source_ref} (one-line after id)`
  };
  const unresolved = [
    { field: 'kind', needs: 'join state-meta/task-lifecycle for the same task_id (backlog row omits kind here)' },
    { field: 'task_origin', needs: 'join captain-orders (order_ref) for the same task_id' }
  ];
  if (repo !== undefined) { fields.repo = repo; prov.repo = `${record.source_ref} (repo: ...)`; }
  if (status !== undefined) { fields.status = status; prov.status = `${record.source_ref} backlog section '${record.value.section}'`; }
  else unresolved.push({ field: 'status', needs: `backlog section '${record.value.section}' has no canonical status mapping` });
  return mapped(record, [row('tasks', taskId, fields, prov, unresolved)]);
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
  const dupKey = `${taskId} ${record.value.spawned_at ?? ''}`;
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

// --- state/captain-orders.jsonl -> tasks.order_ref field mapping -----------------
function mapOrder(record, ctx) {
  if (record.value.__malformed) {
    return flagged(record, 'unmappable', `malformed JSON: ${record.value.error}`);
  }
  const orderId = record.value.id;
  if (typeof orderId !== 'string' || orderId.length === 0) {
    return flagged(record, 'unmappable', 'order record has no id');
  }
  if (ctx.orderIds.has(orderId)) {
    return flagged(record, 'duplicate', `order id ${orderId} already seen at ${ctx.orderIds.get(orderId)}`);
  }
  ctx.orderIds.set(orderId, record.source_ref);
  const backlogId = record.value.backlogId;
  if (typeof backlogId !== 'string' || backlogId.length === 0) {
    if (record.value.status === 'dismissed') {
      return flagged(record, 'unmappable', 'dismissed order not linked to any task (no backlogId)');
    }
    return flagged(record, 'ambiguous', `order ${orderId} has no linked task id (status='${record.value.status ?? '?'}')`);
  }
  // The canonical schema has no orders table: an order becomes a captain_order origin on
  // its task (tasks.order_ref). This is a FIELD-level mapping onto an existing task row.
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

const MAPPERS = {
  'state-meta': mapMeta,
  'state-status': mapStatus,
  'state-turn-ended': mapTurnEnded,
  backlog: mapBacklog,
  'task-lifecycle': mapLifecycle,
  'task-runs': mapTaskRun,
  'captain-orders': mapOrder
};

// Fresh per-report duplicate-detection state. Order-stable: because records arrive in
// the reader's deterministic order, "first occurrence" is well-defined and repeatable.
export function newMappingContext() {
  return {
    lifecycleEventIds: new Map(),
    taskRunKeys: new Map(),
    taskRunGen: new Map(),
    orderIds: new Map()
  };
}

// Map ONE legacy record to its disposition. Total: every record returns exactly one
// mapped-or-flagged result; an unknown store is itself an explicit flag, never a skip.
export function mapRecord(record, ctx) {
  const fn = MAPPERS[record.store];
  if (!fn) return flagged(record, 'unmappable', `no mapper for legacy store '${record.store}'`);
  return fn(record, ctx);
}
