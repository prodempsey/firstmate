import { PgHostedContractStore } from '../../lib/pg-hosted-contract-store.mjs';

// Test-only hosted-Postgres bootstrap for wf10 (spec matrix row 869; prespec Q2 ruling:
// GATE on CP_E2E_PG_URL, skip loudly when absent - standing up an ephemeral Postgres
// in-test is out of scope). This is a PORTABILITY gate through the test-only multi-connection
// hosted adapter, never a production hosted deployment. When CP_E2E_PG_URL is set, QA points
// it at a scratch database; the harness runs the storage-seam contract against it and drops
// what it created.

export function pgUrl(env = process.env) {
  const u = env.CP_E2E_PG_URL;
  return typeof u === 'string' && u.length > 0 ? u : null;
}

// Open a multi-connection hosted contract store against the gated URL (pool max 4, session
// advisory lock serializing exclusive sections). Returns the store; caller closes it.
export async function openHostedStore(env = process.env) {
  const connString = pgUrl(env);
  if (!connString) throw new Error('CP_E2E_PG_URL is not set (wf10 must be gated before calling this)');
  return PgHostedContractStore.create({ connString });
}
