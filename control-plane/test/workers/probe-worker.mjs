// Test-only worker: performs ONE serialized core-table write (contractProbe bumps
// coordinator_state.commit_sequence) against the FM_HOME store, then exits. Racing
// N of these across separate OS processes proves the exclusive flock serializes
// concurrent writers with no lost read-modify-write updates. Uses only public S0
// store methods.
import { PgliteLocalStore } from '../../lib/pglite-local-store.mjs';

const store = new PgliteLocalStore({ fmHome: process.env.FM_HOME });
try {
  const probe = await store.contractProbe();
  process.stdout.write(`${JSON.stringify(probe)}\n`);
} finally {
  await store.close();
}
