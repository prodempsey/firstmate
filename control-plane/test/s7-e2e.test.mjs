import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Harness } from '../e2e/runner.mjs';
import { hasTmux, launchAgentPane, launchDecoyPane } from '../e2e/fixtures/agent.mjs';
import { isAlive, killExactPid, waitFor } from '../e2e/fixtures/proc.mjs';
import { doubleRunning } from '../e2e/fixtures/lifecycle.mjs';
import { pgUrl } from '../e2e/fixtures/pg.mjs';
import { createTask, beginRun } from '../lib/domain-store.mjs';
import { completeRun } from '../lib/domain-store-s2.mjs';
import * as wf1 from '../e2e/workflows/wf1.mjs';
import * as wf2 from '../e2e/workflows/wf2.mjs';
import * as wf3 from '../e2e/workflows/wf3.mjs';
import * as wf4 from '../e2e/workflows/wf4.mjs';
import * as wf5 from '../e2e/workflows/wf5.mjs';
import * as wf6 from '../e2e/workflows/wf6.mjs';
import * as wf7 from '../e2e/workflows/wf7.mjs';
import * as wf8 from '../e2e/workflows/wf8.mjs';
import * as wf9 from '../e2e/workflows/wf9.mjs';
import * as wf10 from '../e2e/workflows/wf10.mjs';

// S7 disposable E2E harness entry (spec section 11). One `node --test` subtest per workflow
// (t_wf1_success ... t_wf10_hosted_contract), plus the two harness-discipline tests
// (t_global_finals_enforced, t_teardown_kills_only_recorded). Each workflow runs in a fully
// isolated fixture world with a dedicated tmux socket, and every workflow is followed by the
// global final assertions (spec 848-859). Gates:
//   - CP_E2E_ONLY=wfN         run only that workflow (fix-round iteration), skip the rest loudly
//   - CP_E2E_SKIP_TMUX=1      skip the tmux-requiring workflows (1-4, 7) loudly
//   - CP_E2E_PG_URL=<url>     enable wf10 (hosted Postgres portability gate); skipped loudly otherwise
// The mutation-sensitive discipline tests prove the runner's OWN finals and exact-PID
// teardown are real: a broken final input FAILS, and an unrecorded decoy pane is REPORTED
// (never killed) by the exact-PID discipline.

const WORKFLOWS = [
  ['t_wf1_success', wf1], ['t_wf2_failure', wf2], ['t_wf3_blocked_rework', wf3],
  ['t_wf4_unexpected_death', wf4], ['t_wf5_duplicate_conflict', wf5], ['t_wf6_consumer_crash', wf6],
  ['t_wf7_spawn_saga_cutpoints', wf7], ['t_wf8_concurrent_consumers_gap_ack', wf8],
  ['t_wf9_durability_lock_reopen', wf9], ['t_wf10_hosted_contract', wf10]
];

const ONLY = process.env.CP_E2E_ONLY || null; // e.g. "wf7"
const TMUX = hasTmux() && process.env.CP_E2E_SKIP_TMUX !== '1';

function skipReason(name, mod) {
  if (ONLY && !name.includes(ONLY)) return `CP_E2E_ONLY=${ONLY} filter`;
  if (mod.meta?.pgGated && !pgUrl()) return 'hosted Postgres portability gate: set CP_E2E_PG_URL to run (skipped, not covered)';
  if (mod.meta?.tmuxRequired && !TMUX) return 'requires tmux (set a tmux-capable env; CP_E2E_SKIP_TMUX unset) - skipped, not covered';
  return false;
}

for (const [name, mod] of WORKFLOWS) {
  test(name, { skip: skipReason(name, mod) }, async () => {
    if (mod.meta?.pgGated) {
      // The hosted portability gate manages its own multi-connection store and cleanup; the
      // PGlite fixture finals do not apply to it.
      await mod.run();
      return;
    }
    const h = new Harness({ label: name, tmuxRequired: mod.meta?.tmuxRequired });
    await h.setup();
    try {
      const result = await mod.run(h);
      await h.assertGlobalFinals(result || {});
    } finally {
      await h.teardown();
    }
  });
}

// The finals are themselves mutation-checked: break ONE final input - leave a terminal
// delivery UNACKED - and the runner's finals MUST fail. If they passed here, they would not
// be enforcing anything.
test('t_global_finals_enforced', { skip: ONLY && !ONLY.includes('finals') ? `CP_E2E_ONLY=${ONLY} filter` : false }, async () => {
  const h = new Harness({ label: 'finals-mutation' });
  await h.setup();
  try {
    const started = await doubleRunning(h.store, 't-unacked', { seed: 99 });
    // Complete but deliberately DO NOT drain the consumer: the outbox row stays unacked.
    await completeRun(h.store, { taskId: 't-unacked', generation: 1, expectedRevision: started.revision, outcome: 'success', producer: 'crewmate', seq: 1, evidence: {}, commandId: 'c-done' });
    await assert.rejects(
      () => h.assertGlobalFinals({}),
      (e) => /unacked outbox rows/.test(e.message),
      'the finals FAIL when a terminal delivery is left unacked (the finals are enforced, not decorative)'
    );
  } finally {
    await h.teardown();
  }
});

// Teardown kills ONLY exact recorded PIDs. An unrecorded decoy marker-bearing pane on the
// dedicated socket is SPARED by the exact-PID kill and is REPORTED by the zero-orphan final
// assertion - never pattern-killed. This proves the runner's own teardown discipline.
test('t_teardown_kills_only_recorded', { skip: !TMUX ? 'requires tmux' : (ONLY && !ONLY.includes('teardown') ? `CP_E2E_ONLY=${ONLY} filter` : false) }, async () => {
  const h = new Harness({ label: 'teardown-discipline', tmuxRequired: true });
  await h.setup();
  try {
    // A recorded agent pane and an UNRECORDED decoy pane, both marker-bearing, on the socket.
    const created = await createTask(h.store, { taskId: 't-rec', kind: 'ship', title: 'recorded', origin: 'internal', internalReason: 'r', commandId: 'c-create' });
    const beg = await beginRun(h.store, { taskId: 't-rec', expectedRevision: created.revision, commandId: 'c-begin' });
    const agent = launchAgentPane({ socket: h.socket, fmHome: h.fmHome, taskId: 't-rec', launchMarker: beg.launch_marker, bindNonce: beg.bind_nonce });
    h.recordAgent({ pid: agent.agentPid, marker: beg.launch_marker, endpointId: agent.endpointId, paneId: agent.paneId });
    const decoy = launchDecoyPane({ socket: h.socket });

    // The exact-PID kill of the RECORDED agent must spare the unrecorded decoy entirely.
    killExactPid(agent.agentPid);
    h.markAgentDead(agent.agentPid);
    assert.equal(waitFor(() => !isAlive(agent.agentPid)), true, 'the recorded agent is killed by its exact PID');
    assert.equal(isAlive(decoy.pid), true, 'the UNRECORDED decoy survives the exact-PID kill (only recorded PIDs are killed)');

    // The zero-orphan final REPORTS the decoy as an unrecorded marker-bearing pane - and
    // never kills it.
    await assert.rejects(
      () => h.assertGlobalFinals({}),
      (e) => /unrecorded marker-bearing pane/.test(e.message),
      'the finals REPORT the unrecorded decoy as a zero-orphan failure'
    );
    assert.equal(isAlive(decoy.pid), true, 'the finals reported the decoy without killing it');

    // The decoy was never a recorded PID, so teardown's per-PID kill list never targeted it;
    // only the dedicated-socket teardown (below, in finally) reaps it.
    assert.equal(h.agents.some((a) => a.pid === decoy.pid) || h.children.some((c) => c.pid === decoy.pid) || h.keepalives.some((k) => k.pid === decoy.pid), false, 'the decoy is in no recorded kill list');
  } finally {
    await h.teardown();
  }
});
