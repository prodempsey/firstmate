# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, confirm-twice ghost reconciliation, and wake drain into the single ordered session-start digest |
| `fm-console.sh`          | Launch the cockpit console with provider failover and fresh-request-gated handoff seeding |
| `fm-provider-failover.sh` | Manage the shared provider and harness circuit-breaker state                        |
| `fm-install-no-mistakes.sh` | Pinned, checksum-verified no-mistakes install used by bootstrap's consent flow                 |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-reconcile-ghosts.sh` | Locked session-start sweep: confirm a recorded endpoint is dead twice before delegating cleanup to `fm-teardown.sh` and surface its refusals |
| `fm-fleet-triage.sh`     | Print the read-only fleet-triage candidate digest from existing fleet evidence                     |
| `fm-fleet-triage-lib.sh` | Shared fleet-triage candidate detection, ledger keys, and digest rendering                         |
| `fm-fleet-triage-record.sh` | Record a triage candidate's outcome and lineage in the durable triage ledger                    |
| `fm-fleet-triage-act.sh` | Dry-run-first mechanical auto-action: unblock backlog items whose blocker the enumerator proved done |
| `fm-triage-duty.sh`      | Prompt (and prove consultation of) the triage duty at every fleet-state change                    |
| `fm-order-lib.sh`        | Shared captain-order inbox parsing, validation, and record helpers                                 |
| `fm-nf-reconcile.sh`     | Reconcile needs-firstmate terminal signals and keep unhandled firstmate cards noisy                |
| `fm-nf-ack.sh`           | Acknowledge a needs-firstmate card so it stops resurfacing                                         |
| `fm-nf-lib.sh`           | Shared needs-firstmate card parsing and lane-state helpers                                        |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print the read-only structured fleet snapshot JSON (schema `fm-fleet-snapshot.v1`)   |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the fleet snapshot to the compact TOON bearings view; local-only unless `--include-prs` |
| `fm-update.sh`           | Fast-forward-only self-update of firstmate and secondmate homes from origin          |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-brief-lint.sh`       | Lint a generated brief for stale or invented model names                                          |
| `fm-kd-snapshot.sh`      | Capture a KrakenDesign artifact snapshot for a `--kd-review` task                                 |
| `fm-brief.sh`            | Scaffold ship, scout, secondmate-charter, and Herdr-lab briefs                       |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `fm-order.sh`            | Record, read, and disposition captain orders; the only sanctioned writer of the captain order inbox (docs/captain-orders.md) |
| `fm-order-duty.sh`       | Warn when a captain chat capture is undrained, an order still needs action, or the inbox is corrupt |
| `fm-order-capture-hook.sh` | Spool a captain chat message to disk at prompt submission, before firstmate takes a turn |
| `fm-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and stale watcher liveness   |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-crew-kill-pretool-check.sh` | PreToolUse guard that refuses a crewmate's broad pattern kills (docs/crew-kill-guard.md)   |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a secondmate home and maintain `data/secondmates.md`       |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-profile.sh`          | Resolve a task class to a capability profile (harness/model/effort) from crew-profiles.json       |
| `fm-spawn-profile.sh`    | Thin `--class`/`--profile` spawn wrapper that resolves a profile and calls `fm-spawn.sh`          |
| `fm-dispatch-select.sh`  | Resolve a matched crew-dispatch rule to one concrete profile, owning `quota-balanced` selection |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inheritable local config to live secondmate homes mid-session          |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`           |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-review-diff.sh`      | Review a crewmate branch or recorded PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Shared from-firstmate request marker and detector                                    |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with honest status reporting                |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe always-on watcher: absorb benign wakes, queue and exit on actionable ones |
| `fm-afk-start.sh`        | Enter away mode and run the sub-supervisor daemon as a tracked foreground process    |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-worktree-lib.sh`     | Shared treehouse-pool-slot predicate used by spawn and teardown safety gates                      |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local secondmate syncs       |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inheritable-config propagation                        |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes, then assert watcher liveness                  |
| `fm-wake-lib.sh`         | Shared durable wake queue, portable locks, and watcher identity/health helpers       |
| `fm-classify-lib.sh`     | Shared captain-relevant and declared-external-wait wake classification vocabulary    |
| `fm-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, composer capture, and verified submit |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-pr-check.sh`         | Record `pr=` and `pr_head=` for a PR-ready task, then arm the watcher's merge poll   |
| `fm-pr-merge.sh`         | Record PR metadata, then merge a task's PR from its full GitHub URL                  |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task                               |
| `fm-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require scout reports, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness and resolve crew or secondmate harness, model, and effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared X-mode config, relay, and reply-threading helpers                             |
| `fm-x-poll.sh`           | One bounded X relay poll: stash pending mentions, print `x-mention <request_id>`     |
| `fm-x-reply.sh`          | Post or dry-run preview a composed X-mode reply or follow-up                         |
| `fm-x-dismiss.sh`        | Dismiss a skipped X-mode mention at the relay without replying                       |
| `fm-x-link.sh`           | Link a spawned task to its originating X-mode mention in task meta                   |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for an X-mode-linked task                |
