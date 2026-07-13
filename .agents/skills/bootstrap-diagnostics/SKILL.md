---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints any diagnostic or capability line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, TRUNK, CREW_HARNESS_OVERRIDE, CREW_DISPATCH, FLEET_SYNC, SECONDMATE_SYNC, SECONDMATE_LIVENESS, LEASE_RECLAIM, TASKS_AXI, TEST_TMP_SWEEP, NUDGE_SECONDMATES, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one.
  A silent bootstrap section means all good and needs no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For `tasks-axi`, this also covers an installed build that fails the compatibility probe (`docs/configuration.md` "Backlog backend" owns the definition); `config/backlog-backend=manual` only suppresses the `TASKS_AXI: available` capability line, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because crew-dispatch `quota-balanced` may call it; `bin/fm-dispatch-select.sh` still degrades at runtime when quota data is unavailable.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `TRUNK: <project>: error|drift|note: <message> - fix: <fix>` - the canonical trunk invariant for a governed project (`docs/configuration.md` "Canonical trunk declaration").
  `drift` means the serving lineage is AHEAD of, or divergent from, the declared canonical trunk, the trunk checkout is parked off trunk, the crew provisioning base is stale, or the GitHub default disagrees with the declaration.
  This is the failure that let a project's `main` sit frozen for sixteen days unnoticed, so treat it as a stop-and-fix before landing more work: run the printed fix, or dispatch a crewmate to converge the lineages, and never leave it reported-but-ignored.
  `error` means the invariant is UNVERIFIABLE - the declaration is missing or malformed, a governed project has no entry, or the serving lineage cannot be read - which is never a pass; write or repair `config/canonical-trunk.json` (the verifier prints the schema) before dispatching work whose landing depends on it.
  `note` is a deploy lag (serving behind trunk), which is the tolerable direction: report it to the captain if a deploy is expected, and otherwise carry on.
  The verifier never mutates a ref; `bin/fm-merge-local.sh` refuses local landings while any `error` or `drift` stands, so a refused merge is this line telling you the same thing twice.
- `CREW_HARNESS_OVERRIDE: <name>` - record and use the override silently; surface a harness fact only if it actually blocks work or the captain asks.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; continue with the normal fallback chain, resolve and pass the chosen fallback harness explicitly while the file remains present, fix the malformed schema, unverified harness name, unknown selector, or invalid harness/effort pair when convenient, and do not select a bad profile.
- `CREW_DISPATCH: active config/crew-dispatch.json` - bootstrap validated the optional dispatch profile file and printed its active rules and `default:` when present.
  Keep this block top-of-mind during intake; it is the reminder that every crewmate or scout dispatch must consult the rules before spawning (`AGENTS.md` section 4).
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - the local-HEAD secondmate sync left a live secondmate home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing the primary target commit, or otherwise not fast-forwardable, or because inheritable-config propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions or inherited settings may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: already-live|respawned|skipped: <reason>|respawn failed: <reason>` - the session-start liveness sweep checked a live secondmate's recorded endpoint for a real agent process.
  Treat `already-live` and `respawned` as handled; investigate `skipped` or `respawn failed` because that secondmate is not guaranteed live.
- `LEASE_RECLAIM: pool <repo>: reclaimed <n>, parked <m>` plus its indented per-lease lines - the session-start sweep found treehouse pool slots still leased to tasks that no longer exist (`bin/fm-lease-reclaim.sh`).
  A `reclaimed <holder> <path>: <reason>` line is done and needs no action: that slot's owner was provably gone and its worktree provably held no work, so the slot is back in the pool.
  Report reclaimed slots to the captain only as a brief outcome ("freed N stale worktree slots") if they ask or if the pool had been blocking work; never name the internals.
  A `PARKED <holder> <path>: <reason>` line is the one that needs you.
  The lease's owner is gone but its worktree still holds UNCOMMITTED CHANGES or UNLANDED WORK, so the sweep refused to return it - returning a lease resets the worktree, and discarding that work is the captain's call alone (prime directive #3).
  Parked leases are re-reported every session start and never expire on their own, so they will keep accumulating and eating pool slots until the captain rules on each one.
  Bring them to the captain in outcome language: unfinished work is sitting in an abandoned workspace, summarize what is in it (inspect with `git -C <path> status` and `git -C <path> log --oneline @{u}..` - read-only), and ask whether to keep it (have a crewmate salvage the change) or let it go.
  Only on the captain's explicit word to discard, free the slot with `treehouse return --force <path>` run from the project dir; never do it on your own judgment, and never under `yolo` (discarding unlanded work is destructive and always escalates).
  If the pool is at or near exhaustion and every remaining lease is parked, say so plainly - new work cannot be dispatched into that project until slots are freed.
- `TEST_TMP_SWEEP: reclaimed <n> orphaned test temp root(s)` - the session-start sweep reclaimed temp roots left behind by firstmate's own test suites, listing each one's footprint underneath.
  Not a problem and not an action item: it is the designed recovery from a test killed by a SIGKILL (which no cleanup trap can ever catch), and it is reported only so the reclaim is never silent.
  A root whose owning test process is still alive is never reclaimed, so this line can never mean a running test was disturbed.
  It is worth a look only if it recurs every session with large footprints, which would mean suites are being killed routinely; `bin/fm-test-tmp-sweep.sh` owns the staleness proof.
- `TASKS_AXI: available` - a default-backend capability fact, not a problem; record it silently and use `AGENTS.md` section 10 for backlog mutations.
  It prints only when `config/backlog-backend` is absent or set to `tasks-axi` and the shared compatibility probe passes (`docs/configuration.md` "Backlog backend").
  If the backend is not opted out and `tasks-axi` is missing or incompatible, bootstrap reports the `MISSING: tasks-axi` line but firstmate still hand-edits routine backlog updates and never blocks work.
  If `config/backlog-backend=manual`, firstmate hand-edits routine backlog updates and bootstrap does not suggest installing `tasks-axi`.
- `NUDGE_SECONDMATES: fm-<id>...` - the secondmate sweep fast-forwarded one or more *running* secondmate homes to firstmate's current version and their instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) actually changed; send a one-line re-read nudge with `FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'` unless `FM_HOME` is already set to the active firstmate home.
  This mirrors `/updatefirstmate`'s `nudge-secondmates:` report: it is a gentle steer, never an interruption, and the fast-forward already landed safely.
  A secondmate that was skipped, already current, or whose advance changed no instructions is not listed and must not be disturbed.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
