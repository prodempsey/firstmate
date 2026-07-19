import { PgliteLocalStore } from './pglite-local-store.mjs';
import { ValidationError } from './errors.mjs';
import { runS1Verb, S1_VERBS } from './coordinator-s1.mjs';
import { runS2Verb, S2_VERBS } from './coordinator-s2.mjs';

// Coordinator entrypoint skeleton (spec section 6). S0 implements exactly one
// verb, `init`. Every other verb in the spec's command surface (create-task,
// begin-run, event, complete/fail, cleanup, consumer, snapshot, ...) belongs to a
// later slice and ships in the slice that owns it - none are wired here.
//
// The verb runs the full storage lifecycle from section 2 by going through the
// store (flock + open + transaction + close-before-unlock).

const S0_VERBS = new Set(['init']);

export async function runVerb(argv, { env = process.env } = {}) {
  const [verb, ...rest] = argv;
  if (!verb || verb === '--help' || verb === '-h') {
    return { ok: true, result: { help: helpText() }, human: helpText() };
  }
  if (!S0_VERBS.has(verb)) {
    // S1 verb registration: later slices own their verbs and ship in the slice
    // that owns them (this file's header). S1's dispatcher lives in its own module.
    if (S1_VERBS.has(verb)) return runS1Verb(verb, rest, { env });
    if (S2_VERBS.has(verb)) return runS2Verb(verb, rest, { env });
    throw new ValidationError(
      `unknown or not-yet-implemented verb: ${verb}`,
      { s0Verbs: [...S0_VERBS] }
    );
  }
  const args = parseArgs(rest);

  // init
  const store = PgliteLocalStore.create({ dataDir: args.flags['data-dir'], env });
  try {
    const result = await store.init({ homeLabel: args.flags['home-label'] });
    return { ok: true, result };
  } finally {
    await store.close();
  }
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
    '      Initialize the per-home PGlite store: apply the S0 core schema',
    '      (schema_meta, coordinator_state) and seed home_uuid. Idempotent.',
    '      Uses FM_HOME/state/control-plane/pgdata when --data-dir is omitted.',
    '',
    'Later-slice verbs (create-task, begin-run, event, complete, ...) are not',
    'implemented in S0; they ship in their owning slices.'
  ].join('\n');
}
