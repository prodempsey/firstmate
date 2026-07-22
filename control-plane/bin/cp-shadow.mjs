#!/usr/bin/env node
import { createShadowWriter } from '../lib/shadow-writer.mjs';
import { resolveDataPaths } from '../lib/paths.mjs';
import { parseArgs } from '../lib/coordinator.mjs';
import { ShadowWriteError } from '../lib/errors-cw2.mjs';
import { ControlPlaneError } from '../lib/errors.mjs';

// CW2 SHADOW-WRITER CLI. A firstmate lifecycle chokepoint invokes exactly one mirror
// action per process (fire-and-forget), typically backgrounded by bin/fm-cp-shadow.sh so
// even a wedged mirror cannot delay the legacy op. This binary is a thin surface over
// lib/shadow-writer.mjs: it resolves the store location, calls the one mapped method, prints
// the structured outcome as JSON, and EXITS 0 for any mirror outcome (success OR a logged
// divergence) - a shadow write must never signal failure back to a legacy operation. It
// exits non-zero ONLY for a malformed invocation (unknown action or missing task id), a
// developer-facing usage error the shell hook ignores anyway.
//
// Actions and their flags (all take --task <id>):
//   task-filed  --task --kind --title [--repo] [--order-ref | --internal-reason]
//   dispatched  --task [--detail <json>]
//   status      --task --status <progress|blocked|unblocked|waiting_firstmate|needs_human|rework> [--detail]
//   completed   --task [--evidence <json>] [--detail]
//   failed      --task [--reason <text>] [--detail]
//   teardown    --task [--detail]
//   archived    --task [--detail]
//   finalize    --task [--evidence <json>] [--detail]   (ordered complete->ack->cleanup->archive)
//
// Store location: --data-dir, else CP_SHADOW_DATA_DIR, else FM_HOME/state/control-plane/pgdata.
// Divergence log: --divergence-log, else CP_SHADOW_DIVERGENCE, else <pgdata parent>/shadow-divergence.jsonl.

const ACTIONS = new Set(['task-filed', 'dispatched', 'status', 'completed', 'failed', 'teardown', 'archived', 'finalize']);

function parseMaybeJson(v) {
  if (typeof v !== 'string' || v.length === 0) return undefined;
  try {
    return JSON.parse(v);
  } catch {
    return v; // a bare string detail/evidence is fine
  }
}

function helpText() {
  return [
    'cp-shadow <action> --task <id> [flags]   (CW2 fire-and-forget lifecycle mirror)',
    '',
    'Actions: task-filed | dispatched | status | completed | failed | teardown | archived',
    '',
    'Store: --data-dir, else CP_SHADOW_DATA_DIR, else FM_HOME/state/control-plane/pgdata.',
    'A mirror never fails a legacy op: any store/divergence error is logged and this exits 0.'
  ].join('\n');
}

async function main() {
  const argv = process.argv.slice(2);
  const [action, ...rest] = argv;
  if (!action || action === '--help' || action === '-h') {
    process.stdout.write(`${helpText()}\n`);
    process.exit(0);
  }
  if (!ACTIONS.has(action)) {
    throw new ShadowWriteError(`unknown shadow action: ${action}`, { actions: [...ACTIONS] });
  }
  const { flags } = parseArgs(rest);
  const taskId = typeof flags.task === 'string' ? flags.task : undefined;
  if (!taskId) {
    throw new ShadowWriteError(`'${action}' requires --task <id>`, { action });
  }

  const env = process.env;
  const explicitDataDir = typeof flags['data-dir'] === 'string'
    ? flags['data-dir']
    : (typeof env.CP_SHADOW_DATA_DIR === 'string' && env.CP_SHADOW_DATA_DIR.length > 0 ? env.CP_SHADOW_DATA_DIR : undefined);
  const { pgdata, parent } = resolveDataPaths({ dataDir: explicitDataDir, env });
  const divergenceLog = typeof flags['divergence-log'] === 'string'
    ? flags['divergence-log']
    : (typeof env.CP_SHADOW_DIVERGENCE === 'string' && env.CP_SHADOW_DIVERGENCE.length > 0
      ? env.CP_SHADOW_DIVERGENCE
      : `${parent}/shadow-divergence.jsonl`);

  const writer = createShadowWriter({ dataDir: pgdata, divergenceLog, env });
  let outcome;
  try {
    switch (action) {
      case 'task-filed':
        outcome = await writer.taskFiled({
          taskId,
          kind: typeof flags.kind === 'string' ? flags.kind : undefined,
          title: typeof flags.title === 'string' ? flags.title : undefined,
          repo: typeof flags.repo === 'string' ? flags.repo : undefined,
          orderRef: typeof flags['order-ref'] === 'string' ? flags['order-ref'] : undefined,
          internalReason: typeof flags['internal-reason'] === 'string' ? flags['internal-reason'] : undefined
        });
        break;
      case 'dispatched':
        outcome = await writer.dispatched({ taskId, detail: parseMaybeJson(flags.detail) });
        break;
      case 'status':
        outcome = await writer.statusTransition({
          taskId, status: typeof flags.status === 'string' ? flags.status : undefined, detail: parseMaybeJson(flags.detail)
        });
        break;
      case 'completed':
        outcome = await writer.completed({ taskId, evidence: parseMaybeJson(flags.evidence), detail: parseMaybeJson(flags.detail) });
        break;
      case 'failed':
        outcome = await writer.failed({ taskId, reason: typeof flags.reason === 'string' ? flags.reason : undefined, detail: parseMaybeJson(flags.detail) });
        break;
      case 'teardown':
        outcome = await writer.teardown({ taskId, detail: parseMaybeJson(flags.detail) });
        break;
      case 'archived':
        outcome = await writer.archived({ taskId, detail: parseMaybeJson(flags.detail) });
        break;
      case 'finalize':
        outcome = await writer.finalize({ taskId, evidence: parseMaybeJson(flags.evidence), detail: parseMaybeJson(flags.detail) });
        break;
      default:
        throw new ShadowWriteError(`unhandled action: ${action}`, { action });
    }
  } finally {
    await writer.close();
  }

  process.stdout.write(`${JSON.stringify(outcome)}\n`);
  // Fire-and-forget: exit 0 whether the mirror applied, replayed, or logged a divergence.
  process.exit(0);
}

main().catch((error) => {
  // Only a surface/usage error reaches here (a mirror outcome never throws). Print it and
  // exit non-zero for developer clarity; the shell hook backgrounds and ignores this.
  const payload =
    error instanceof ControlPlaneError
      ? { error: error.message, code: error.code, detail: error.detail ?? null }
      : { error: error?.message || String(error), code: 'unexpected' };
  process.stderr.write(`${JSON.stringify(payload)}\n`);
  process.exit(1);
});
