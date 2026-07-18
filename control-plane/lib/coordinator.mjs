import { PgliteLocalStore } from './pglite-local-store.mjs';
import { ValidationError } from './errors.mjs';

// Coordinator entrypoint skeleton (spec section 6). S0 implements exactly three
// verbs: `init`, `create-task`, and `task-head`. Every other verb in the spec's
// command surface belongs to a later slice and is intentionally absent here.
//
// Each verb runs the full storage lifecycle from section 2 by going through the
// store's runExclusive (flock + open + transaction + close-before-unlock).

const S0_VERBS = new Set(['init', 'create-task', 'task-head']);

export async function runVerb(argv, { env = process.env } = {}) {
  const [verb, ...rest] = argv;
  if (!verb || verb === '--help' || verb === '-h') {
    return { ok: true, result: { help: helpText() }, human: helpText() };
  }
  if (!S0_VERBS.has(verb)) {
    throw new ValidationError(
      `unknown or not-yet-implemented verb: ${verb}`,
      { s0Verbs: [...S0_VERBS] }
    );
  }
  const args = parseArgs(rest);

  if (verb === 'init') {
    const store = makeStore(args, env);
    try {
      const result = await store.init({ homeLabel: args.flags['home-label'] });
      return { ok: true, result };
    } finally {
      await store.close();
    }
  }

  if (verb === 'create-task') {
    const taskId = args.positionals[0];
    const store = makeStore(args, env);
    try {
      const result = await store.createTask({
        taskId,
        kind: args.flags.kind,
        title: args.flags.title,
        repo: args.flags.repo,
        origin: args.flags.origin,
        orderRef: args.flags['order-ref'],
        internalReason: args.flags['internal-reason'],
        commandId: args.flags['command-id']
      });
      return { ok: true, result };
    } finally {
      await store.close();
    }
  }

  // task-head
  const taskId = args.positionals[0];
  if (!taskId) throw new ValidationError('task-head requires a <task_id> positional');
  const store = makeStore(args, env);
  try {
    const result = await store.taskHead(taskId);
    if (result === null) {
      return { ok: false, result: { error: 'no such task', taskId } };
    }
    return { ok: true, result };
  } finally {
    await store.close();
  }
}

function makeStore(args, env) {
  return PgliteLocalStore.create({ dataDir: args.flags['data-dir'], env });
}

// Minimal, dependency-free arg parser: `--flag value` pairs and bare positionals.
// `--flag` with no following value (or followed by another --flag) is a boolean.
export function parseArgs(tokens) {
  const flags = {};
  const positionals = [];
  for (let i = 0; i < tokens.length; i += 1) {
    const tok = tokens[i];
    if (tok.startsWith('--')) {
      const name = tok.slice(2);
      const next = tokens[i + 1];
      if (next === undefined || next.startsWith('--')) {
        flags[name] = true;
      } else {
        flags[name] = next;
        i += 1;
      }
    } else {
      positionals.push(tok);
    }
  }
  return { flags, positionals };
}

function helpText() {
  return [
    'cp - control-plane coordinator (S0 foundation)',
    '',
    'Verbs:',
    '  cp init [--data-dir <path>] [--home-label <label>]',
    '      Initialize the per-home PGlite store (idempotent). Uses',
    '      FM_HOME/state/control-plane/pgdata when --data-dir is omitted.',
    '',
    '  cp create-task <task_id> --kind <ship|scout|secondmate> --title <title>',
    '      [--repo <repo>] --origin <captain_order|internal>',
    '      (--order-ref <ref> | --internal-reason <reason>) [--command-id <id>]',
    '      Insert a queued task and its created event; prints the new revision.',
    '',
    '  cp task-head <task_id>',
    '      Locked read of status, current generation, revision, domain revision.',
    '',
    'Later-slice verbs (begin-run, event, complete, ...) are not implemented in S0.'
  ].join('\n');
}
