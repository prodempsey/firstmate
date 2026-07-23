import fs from 'node:fs';
import path from 'node:path';
import { appendRegistryEvent, auditRegistry, buildActiveIndex, foldRegistry, recoverRegistry, snapshotRegistry } from './registry.mjs';
import { checkDoctor } from './doctor.mjs';
import { registryDir, registryPaths } from './paths.mjs';
import { buildRetrievalIndex, captureCanonical, cleanRetrievalIndex, inspectRetrievalIndex } from './retrieval-index.mjs';
import { retrieveMemory } from './retrieve.mjs';

function parseArgs(args) {
  const out = { _: [] };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (!arg.startsWith('--')) out._.push(arg);
    else {
      const key = arg.slice(2);
      const next = args[i + 1];
      if (!next || next.startsWith('--')) out[key] = true;
      else {
        if (out[key] === undefined) out[key] = next;
        else if (Array.isArray(out[key])) out[key].push(next);
        else out[key] = [out[key], next];
        i += 1;
      }
    }
  }
  return out;
}

function list(value) {
  if (value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

// Full field set for a NEW record: proposal defaults are appropriate here.
function proposeFieldsFromFlags(flags) {
  const fields = {
    summary: flags.summary,
    body: typeof flags.body === 'string' ? flags.body : '',
    memoryType: flags['memory-type'] || 'factual',
    scope: flags.scope || 'fleet',
    projects: list(flags.project).length ? list(flags.project) : ['*'],
    taskKinds: list(flags.kind).length ? list(flags.kind) : ['*'],
    keywords: list(flags.keyword),
    aliases: list(flags.alias),
    entities: list(flags.entity),
    commands: list(flags.command),
    failureModes: list(flags['failure-mode']),
    relatedTerms: list(flags['related-term']),
    confidence: flags.confidence || 'unverified',
    riskClass: flags['risk-class'] || 'standard'
  };
  if ('guard-linked' in flags) fields.guard_linked = flags['guard-linked'] === true || flags['guard-linked'] === 'true';
  return fields;
}

// Sparse field set for an UPDATE: ONLY fields the caller explicitly supplied are
// included. Omitted fields are absent, so the fold preserves them. Proposal
// defaults are never applied to an update.
function updateFieldsFromFlags(flags) {
  const fields = {};
  const setStr = (flag, field) => {
    if (flag in flags && typeof flags[flag] === 'string') fields[field] = flags[flag];
  };
  const setList = (flag, field) => {
    if (flag in flags) fields[field] = list(flags[flag]);
  };
  setStr('summary', 'summary');
  setStr('body', 'body');
  setStr('memory-type', 'memoryType');
  setStr('scope', 'scope');
  setList('project', 'projects');
  setList('kind', 'taskKinds');
  setList('keyword', 'keywords');
  setList('alias', 'aliases');
  setList('entity', 'entities');
  setList('command', 'commands');
  setList('failure-mode', 'failureModes');
  setList('related-term', 'relatedTerms');
  setStr('confidence', 'confidence');
  setStr('risk-class', 'riskClass');
  setStr('valid-to', 'validTo');
  if ('guard-linked' in flags) fields.guard_linked = flags['guard-linked'] === true || flags['guard-linked'] === 'true';
  return fields;
}

function evidence(flags) {
  return list(flags.evidence).map((entry) => {
    const [type, ...rest] = entry.split(':');
    return { type, ref: rest.join(':') || entry };
  });
}

function actor(flags) {
  return { kind: flags['actor-kind'] || 'firstmate', id: flags.actor || 'mem-cli' };
}

// The validation block for activate/revalidate. `--validation <ref>` is the sole
// source of the scalar authorization reference: it is NEVER seeded from
// `--evidence`. Evidence is a list of supporting references; authorization is a
// distinct, single reference. Conflating them let an evidence-only activation
// silently satisfy the independent captain-authorization requirement. A repeated
// or empty `--validation` is rejected here, before any event is built or appended.
function validation(flags) {
  const out = { method: flags.method || 'captain', by: flags.actor || 'mem-cli' };
  if (flags.validation !== undefined) {
    if (Array.isArray(flags.validation)) throw new Error('--validation accepts exactly one reference');
    if (typeof flags.validation !== 'string' || flags.validation.length === 0) throw new Error('--validation requires a non-empty reference');
    out.ref = flags.validation;
  }
  return out;
}

// Resolve the retrieval query text from EXACTLY ONE of --query, --query-file, or
// --stdin. Zero sources or more than one source is a hard error, so the documented
// "exactly one input" contract is enforced rather than silently prioritized (F5).
function retrievalQuery(flags) {
  const present = [];
  if (typeof flags.query === 'string') present.push('query');
  if (typeof flags['query-file'] === 'string') present.push('query-file');
  if (flags.stdin) present.push('stdin');
  if (present.length === 0) throw new Error('retrieve requires exactly one of --query, --query-file, or --stdin');
  if (present.length > 1) throw new Error(`retrieve accepts exactly one query source, got: ${present.map((p) => `--${p}`).join(', ')}`);
  if (present[0] === 'query') return flags.query;
  if (present[0] === 'query-file') return fs.readFileSync(flags['query-file'], 'utf8');
  return fs.readFileSync(0, 'utf8');
}

// Validate the required retrieval filters and optional numeric/temporal flags,
// rejecting bad input instead of silently defaulting (F5).
function retrievalOptions(flags) {
  if (typeof flags.project !== 'string' || flags.project.length === 0) throw new Error('retrieve requires --project <name>');
  if (typeof flags.kind !== 'string' || flags.kind.length === 0) throw new Error('retrieve requires --kind <name>');
  let top;
  if (flags.top !== undefined) {
    top = Number(flags.top);
    if (!Number.isInteger(top) || top <= 0) throw new Error('--top requires a positive integer');
  }
  let asOf;
  if (flags['as-of'] !== undefined) {
    if (typeof flags['as-of'] !== 'string' || Number.isNaN(Date.parse(flags['as-of']))) throw new Error('--as-of requires an ISO-8601 timestamp');
    asOf = flags['as-of'];
  }
  return { project: flags.project, kind: flags.kind, top, asOf };
}

function print(value, json = false) {
  if (json) console.log(JSON.stringify(value, null, 2));
  else if (typeof value === 'string') console.log(value);
  else console.log(JSON.stringify(value, null, 2));
}

export async function main(args, options = {}) {
  const flags = parseArgs(args);
  const verb = flags._[0];
  const dir = registryDir(process.env);
  try {
    if (verb === 'propose') {
      if (!flags.summary) throw new Error('propose requires --summary');
      const result = await appendRegistryEvent(dir, { event: 'proposed', actor: actor(flags), fields: proposeFieldsFromFlags(flags), evidence: evidence(flags), reason: flags.reason });
      print({ memId: result.event.memId, eventId: result.event.eventId, skipped: result.skipped }, flags.json);
    } else if (verb === 'activate') {
      const memId = flags._[1];
      if (!memId) throw new Error('activate requires MEM id');
      const result = await appendRegistryEvent(dir, { event: 'activated', memId, actor: actor(flags), fields: { confidence: flags.confidence || 'observed' }, evidence: evidence(flags), validation: validation(flags), reason: flags.reason });
      print({ memId, eventId: result.event.eventId }, flags.json);
    } else if (verb === 'revalidate') {
      const memId = flags._[1];
      if (!memId) throw new Error('revalidate requires MEM id');
      const result = await appendRegistryEvent(dir, { event: 'revalidated', memId, actor: actor(flags), evidence: evidence(flags), validation: validation(flags), reason: flags.reason });
      print({ memId, eventId: result.event.eventId }, flags.json);
    } else if (verb === 'update') {
      const memId = flags._[1];
      if (!memId) throw new Error('update requires MEM id');
      const fields = updateFieldsFromFlags(flags);
      const result = await appendRegistryEvent(dir, { event: 'updated', memId, actor: actor(flags), fields, evidence: evidence(flags), reason: flags.reason });
      print({ memId, eventId: result.event.eventId }, flags.json);
    } else if (['supersede', 'retire', 'quarantine'].includes(verb)) {
      const memId = flags._[1];
      if (!memId) throw new Error(`${verb} requires MEM id`);
      const event = verb === 'supersede' ? 'superseded' : `${verb}d`;
      const result = await appendRegistryEvent(dir, { event, memId, actor: actor(flags), successor: flags.successor, evidence: evidence(flags), reason: flags.reason });
      print({ memId, eventId: result.event.eventId }, flags.json);
    } else if (verb === 'show') {
      // `mem show` is intentionally READ-ONLY in PR-1: it emits no `opened`
      // activity event. Compatibility contract: the activity event schema accepts
      // any event name (`event: z.string().min(1)`), so adding an `opened` event in
      // a later PR requires no activity schema migration.
      const memId = flags._[1];
      const fold = foldRegistry(dir);
      const record = fold.records.get(memId);
      if (!record) throw new Error(`record not found: ${memId}`);
      if (flags.chain) {
        const chain = [record, ...[...(record.supersedes || []), record.supersededBy].filter(Boolean).map((id) => fold.records.get(id)).filter(Boolean)];
        print({ record, chain, registry: fold.watermark, health: fold.health }, flags.json);
      } else print(flags.json ? { record, registry: fold.watermark, health: fold.health } : `${record.id} [${record.status}] ${record.summary}\n${record.body}`, flags.json);
    } else if (verb === 'audit') {
      const audit = auditRegistry(dir);
      if (flags.json) print(audit, true);
      else {
        console.log(`Registry: ${audit.registry.health} ${audit.registry.watermark.seq}:${audit.registry.watermark.eventId || 'none'}`);
        console.log(`Records: ${audit.records.total} total, ${audit.records.active} active`);
        console.log(`Active index: ${audit.activeIndex.status}`);
        if (audit.activeIndex.issues?.length) console.log(`Index issues: ${audit.activeIndex.issues.join('; ')}`);
        console.log(`Snapshots: ${audit.snapshots.health}`);
        if (audit.snapshots.issues?.length) console.log(`Snapshot issues: ${audit.snapshots.issues.join('; ')}`);
        if (audit.registry.corrupt) console.log(`CRITICAL: ${audit.registry.corrupt.reason}`);
      }
      process.exitCode = audit.ok ? 0 : 1;
    } else if (verb === 'project' || (verb === 'index' && flags._[1] === 'rebuild')) {
      const index = buildActiveIndex(dir);
      print({ index: registryPaths(dir).index, registry: index.registry, records: index.recordCount }, flags.json);
    } else if (verb === 'snapshot') {
      print(snapshotRegistry(dir), flags.json);
    } else if (verb === 'recover') {
      print(await recoverRegistry(dir), flags.json);
    } else if (verb === 'retrieval') {
      // Derived retrieval index lifecycle. Additive PR-2 surface; wired into no
      // workflow, brief, spawn, or UI. build/doctor/clean only.
      const sub = flags._[1];
      if (sub === 'build') {
        if (!flags.full) throw new Error('retrieval build requires --full (incremental build is not in PR-2)');
        const result = await buildRetrievalIndex(dir);
        print(result, flags.json);
        process.exitCode = result.ok ? 0 : 1;
      } else if (sub === 'doctor') {
        const canonical = await captureCanonical(dir);
        const derived = await inspectRetrievalIndex(dir, canonical);
        const readiness = !canonical.ok ? 'failed' : (derived.status === 'current' ? 'pglite-fts' : 'lexical-fallback');
        const report = {
          canonical: { ok: canonical.ok, reason: canonical.reason, watermark: canonical.watermark },
          derived: { status: derived.status, reason: derived.reason, generationId: derived.generationId },
          retrievalReadiness: readiness
        };
        if (flags.json) print(report, true);
        else {
          console.log(`Canonical: ${canonical.ok ? 'verified' : `failed (${canonical.reason})`}`);
          console.log(`Derived index: ${derived.status}${derived.reason ? ` (${derived.reason})` : ''}`);
          console.log(`Retrieval readiness: ${readiness}`);
        }
        process.exitCode = canonical.ok ? 0 : 1;
      } else if (sub === 'clean') {
        print(await cleanRetrievalIndex(dir), flags.json);
      } else {
        throw new Error('usage: mem retrieval build --full | retrieval doctor | retrieval clean');
      }
    } else if (verb === 'retrieve') {
      // Resolve and validate the query source and filters BEFORE any work, so a bad
      // argument contract fails closed with a JSON error and never runs a retrieval.
      const query = retrievalQuery(flags);
      const opts = retrievalOptions(flags);
      const result = await retrieveMemory({
        registryDir: dir,
        query,
        project: opts.project,
        kind: opts.kind,
        scopes: list(flags.scope),
        top: opts.top,
        asOf: opts.asOf
      });
      if (flags.json) print(result, true);
      else {
        console.log(`Mode: ${result.retrievalMode}${result.fallbackReason ? ` (${result.fallbackReason})` : ''}`);
        console.log(`Selected: ${result.selected.length}`);
        for (const rec of result.selected) console.log(`  ${rec.id} [score ${rec.score}] ${rec.summary}`);
      }
      process.exitCode = result.ok ? 0 : 1;
    } else if (verb === 'doctor') {
      const doctor = checkDoctor(options.root || path.resolve('.', 'memory'), process.env);
      if (flags.json) print(doctor, true);
      else {
        console.log(`Memory CLI: ${doctor.cli.available ? 'available' : 'missing'} (${doctor.cli.path})`);
        console.log(`Canonical checkout: ${doctor.canonicalCheckout.path}`);
        console.log(`Node: ${doctor.node.version} (${doctor.node.compatible ? 'compatible' : 'incompatible'})`);
        console.log(`Package lock: ${doctor.packageLock.current ? 'current' : 'not current'}`);
        console.log(`Required dependencies: ${doctor.requiredDependencies.ok ? 'available' : `missing ${[...doctor.requiredDependencies.missing, ...(doctor.requiredDependencies.mismatched || [])].join(', ')}`}`);
        console.log(`PGlite: ${doctor.pglite.available ? 'available' : doctor.pglite.status}`);
        console.log(`Vector extension: ${doctor.vectorExtension.available ? 'available' : doctor.vectorExtension.status}`);
        console.log(`Embedding provider: ${doctor.embeddingProvider.configured ? 'configured' : 'not configured (optional)'}`);
        console.log(`Registry: ${doctor.registry.status} (${doctor.registry.path})`);
        console.log(`Snapshots: ${doctor.snapshots.health || 'unknown'}`);
        console.log(`Active-memory index: ${doctor.activeIndex.status}`);
        console.log(`Retrieval index: ${doctor.retrieval.status} (readiness: ${doctor.retrieval.retrievalReadiness})`);
      }
      process.exitCode = doctor.ok ? 0 : 1;
    } else if (verb === 'help' || !verb) {
      console.log('Usage: mem propose|activate|revalidate|show|update|supersede|retire|quarantine|audit|project|index rebuild|snapshot|recover|doctor|retrieval build --full|retrieval doctor|retrieval clean|retrieve');
    } else {
      throw new Error(`unknown command: ${verb}`);
    }
  } catch (error) {
    if (flags.json) console.log(JSON.stringify({ ok: false, error: error.message, code: error.code || null }, null, 2));
    else console.error(`mem: ${error.message}`);
    process.exitCode = 1;
  }
}
