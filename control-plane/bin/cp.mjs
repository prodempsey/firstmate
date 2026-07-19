#!/usr/bin/env node
import { runVerb } from '../lib/coordinator.mjs';
import { ControlPlaneError } from '../lib/errors.mjs';

// Thin CLI wrapper over the coordinator. Prints JSON results to stdout; prints a
// typed error to stderr and exits non-zero on failure. This is the S0 entrypoint
// skeleton (spec section 6): only `init` is wired. Later-slice verbs ship in
// their owning slices and are rejected until then.

async function main() {
  const argv = process.argv.slice(2);
  const outcome = await runVerb(argv, { env: process.env });
  if (outcome.human) {
    process.stdout.write(`${outcome.human}\n`);
  } else {
    process.stdout.write(`${JSON.stringify(outcome.result)}\n`);
  }
  process.exit(outcome.ok ? 0 : 1);
}

main().catch((error) => {
  const payload =
    error instanceof ControlPlaneError
      ? { error: error.message, code: error.code, detail: error.detail ?? null }
      : { error: error?.message || String(error), code: 'unexpected' };
  process.stderr.write(`${JSON.stringify(payload)}\n`);
  process.exit(1);
});
