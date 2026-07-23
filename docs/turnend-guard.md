# Primary turn-end supervision guard

This is the authoritative contract for the "no turn ends blind" primary guard referenced from AGENTS.md section 8.
The shared predicate lives in `bin/fm-turnend-guard.sh`.
Harness-specific tracked hook files only adapt each verified harness's real turn-end mechanism to that shared predicate.
Two related but separate PreToolUse seatbelts deny a bad command shape before it runs rather than detecting a blind turn end afterward: the watcher-arm seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`) and the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`).
Each seatbelt's own document defines its scope; they do not share the turn-end guard's marker-aware primary detection.

## Gap Closed

`bin/fm-guard.sh` is pull-based: it warns whenever some other supervision script happens to run, and prints nothing otherwise.
The primary can otherwise end a turn after handling wakes without resuming supervision, then sit blind until another fleet command happens to run.
On 2026-07-04, that exact gap left a parked no-mistakes gate unwatched for about nine hours.

`bin/fm-turnend-guard.sh` closes the gap by checking the primary's own turn-end path.
When tasks are in flight and there is no live identity-matched watcher with a fresh beacon, a harness hook must either block the turn end or force a bounded follow-up turn that tells the primary to resume the session-start supervision protocol for its harness.

## Gap Closed: finished work left unattended

The guard blocks on a second, independent condition: **the `needs_firstmate` lane is non-empty**.

This guard was, for a long time, the only mechanism in the system that could actually compel the primary, and its predicate read supervision liveness only.
Every fleet-triage mechanism printed to stderr and exited 0 - the duty banner, `bin/fm-guard.sh`'s preflight, the `fleet-triage` skill, AGENTS.md section 8.
So arming the watcher was a complete and sufficient turn exit however much finished work was piled up, and the primary, correctly reading which constraint was real, took it: on 2026-07-13 a session ended cleanly holding 61 actionable and 61 ownerless triage items, with five finished crew branches unlanded and the oldest unhandled signal 13.3 hours old.
A hard rule against ending a turn with supervision off, and a printf against ending a turn with the fleet's work undone, is not a discipline failure to exhort away; it is the predictable equilibrium of the incentives as built.

The block is scoped to the `needs_firstmate` lane and deliberately **not** to the full actionable set.
That lane is bounded by the number of live tasks, cannot be flooded by an audit backfill, and is level-triggered off `state/<id>.meta` plus `state/<id>.status`, so it is discharged by landing or tearing down the work rather than by any paper exit.
Gating on all actionable items would make the guard a flood-wedge liability the next session simply disables.

The acceptance metric is captain-set and binary: **zero permitted turn ends while unattended Needs FirstMate work exists.**
The decision log below is what makes that metric measurable.

## Gap Closed: captain orders unaccounted past grace

The guard blocks on a third, independent condition (ORD-260 slice S2): **the deterministic order-audit file reports unaccounted orders past grace.**

Captain orders had the same asymmetry the finished-work gate closed: an order dispatched and then orphaned - the crew died, or it finished without ever closing the order - was surfaced by banners and compelled by nothing, so a session could end cleanly leaving captain requests silently dropped (`data/davy-jones-scout-s1/report.md` section 0).
The gate reads `state/.order-audit-last.json`, the deterministic product `fm-order.sh audit` writes (slice S1, which evaluates the ACCOUNTED predicate over every non-terminal order and accounts every order younger than its grace via the `fresh` branch).
So the file's `unaccounted` count is exactly `unaccounted_orders_past_grace`, and `unaccounted > 0` blocks the turn end exactly as the `needs_firstmate` lane does.
This is a **cheap file read on the turn-end path, never a re-enumeration** of the inbox; the sweep cost stays a single small `jq` over a bounded file.

The gate demands **accounting, not completion**, which is what makes it flood-proof: an order is discharged by linking live work, queuing it with a recorded reason and blocker, a machine-checkable hold, a board-confirmed park or decision, or a terminal outcome with evidence - all cheap, all legitimate - so even a hundred orders can be honestly accounted in bounded time, and a backfill flood gets the `fm-order.sh park --captain-ack` batch verb (one captain ack accounts the batch).
Re-running the audit is **not** discharge: the predicate is over the orders, so an order leaves the list only when a real accounting act is followed by a fresh `fm-order.sh audit`.

### The audit-authority contract (normative)

This is the invariant the whole predicate derives from, so a future change reasons from it rather than rediscovering a corruption shape one adversary at a time (design ruling `data/dj-orders-s2/design-ruling.md`).
The root cause the ruling names: the gate used to infer an order's discharge from that id's **absence** in the current read - but an id can be absent because it was genuinely accounted, **or** because the file is stale, missing, truncated, partial, corrupt, or a different generation.
Reading the second as the first was the spine under three separate QA rounds.
The fix is one positive invariant with a fail-closed default:

> A discharge-or-progress conclusion about order `X` may be drawn ONLY from a positively-validated, fresh, structurally-complete audit snapshot that provably enumerates `X`'s accounting status. In every other state the prior blocked fact about `X` survives unchanged.

`AUTHORITATIVE(audit)` is decided by a **single atomic validate-and-emit `jq` read** (`bin/fm-turnend-guard.sh`, the order-audit block) - never a separate validate pass plus id extraction, because two reads can observe two generations, and that read race is itself a covert partial-coverage source.
The writer's guarantees are **not** assumed; a truncated, hand-edited, or read-raced file can violate any of them, so the reader proves them.
Authority requires **all** of: `schema == "fm-order-audit/v1"`; an ISO-8601 `generated_at`; `unaccounted` is a number; `unaccounted == (unaccounted_orders | length)`; `unaccounted_orders` is an array; **every** element is an object carrying a **unique, non-empty, string** `order_id`; and the validated-id count equals `unaccounted`.
The same pass **emits the validated ids**, so `orders`/`order_ids` come only from the generation that was validated.
Completeness is part of authority, not an afterthought: a file that count-matches but does not cover every id it declares (the q107 shape) is **corrupt**, and a corrupt file speaks for **no** id - there is no partial trust.

The read then lands in exactly one state, each with a fail-closed default:

- **absent** file - the predicate does not fire: no block, no anomaly, no discharge.
- **stale** (`age > max_age`, default the audit's own `grace_seconds`, overridable by `FM_TURNEND_ORDER_AUDIT_MAX_AGE`) - **non-authoritative, benign**: records `order-audit-stale` for observability only, files **no** anomaly, and is **not** counted in the `read_broken` boolean, so it never diverts control flow (the q104 fix).
- **corrupt** (any structural/completeness failure above) - **non-authoritative, broken**: `order_error=order-audit-<reason>`, one fingerprint-coalesced anomaly, a loud banner.
- **fresh and complete** - the only **authoritative** read (`order_authoritative = 1`); its emitted id set is the complete unaccounted set.

**The create/discharge symmetry** resolves the apparent tension between "fail open" and "fail closed": they are one principle applied to opposite operations, because the audit may only ever speak *positively*.
On **block creation** (first stop) a non-authoritative audit **fails OPEN** - it may never invent a block, so an unverifiable file cannot wedge the primary.
On **block discharge** (retry) a non-authoritative audit **fails CLOSED** - it may never clear a known obligation, because unverifiable truth must never discharge.
Absent, stale, and corrupt therefore land in "cannot create AND cannot clear" by construction, which is what closes the class rather than a per-shape checklist.

### Audit authority across the two stop attempts (fail-closed retry)

The previously blocked order ids in `state/.turnend-guard-block-ids` are **durable knowledge** that a non-authoritative current read must never erase.
The failure this closes: a first stop blocks on a fresh audit listing order `X`, then merely letting that audit go stale (or vanish, or corrupt, or lose `X`'s id to truncation) before the retry made `X` disappear from the current read, and the retry silently permitted it as a clean empty lane or valid shrinkage - a discharge with no accounting act, no wake, and no anomaly.

The retry state machine, keyed on the current audit's authority and the prior blocked set:

- **The order component of the still-outstanding set** is the current authoritative order ids when the audit is fresh, otherwise the **retained** prior `order:` ids from the blocked-id file. A non-authoritative read never shrinks or discharges a prior order.
- **Only a fresh authoritative audit that no longer lists an order** establishes accounting progress for it. Staleness, absence, and corruption (including a count-matched but partial file) are not accounting acts, and re-running the audit is not itself one.
- **Crew ids are always live-checkable** against the `needs_firstmate` lane, so a real crew-lane shrink is recognized independently even while the order axis is temporarily unknown - a departed crew id is dropped from the outstanding set and the wake, while an unknown order stays retained. This keeps an unknown order read from ever impersonating an order discharge, in either direction.
- **When a prior order is retained under a non-authoritative read**, the retry is an `allowed_loop_protection_without_progress` stand-down that carries the retained order ids in the durable check wake and files the one coalesced stand-down anomaly; a corrupt read additionally files its own independent audit anomaly. Neither masks the other.
- **When the outstanding set is genuinely empty** (every prior blocked item authoritatively gone), the retry is a clean permit (or a watcher-down stand-down if supervision is still off, or a guard-error permit if a genuine read failed with nothing else outstanding).

`tests/fm-turnend-guard.test.sh` encodes the ruling's exhaustive `(audit x stop x prior)` table (the `test_hook_retry_*`, `test_hook_first_stop_completeness_failures_*`, and the stale/absent/corrupt/mixed cases).
The **R7 canary** (`test_hook_retry_partial_id_audit_retains_all_prior_orders`) is the single load-bearing case: a fresh, count-matched audit that covers only one of two declared orders must RETAIN both and stand down - if it ever yields `allowed_after_valid_progress`, the authority contract is not implemented.

## Shared Predicate

The guard first scopes itself to the real primary home, and it identifies that home **positively**, from what a firstmate home is.
It requires `AGENTS.md`, `bin/`, and the effective state directory to exist.
A secondmate home runs its own primary firstmate session, so a genuine `.fm-secondmate-home` marker force-includes it as a guarded primary whether treehouse leased it as a linked worktree or it is a git-cloned plain checkout.
The marker must be a regular non-symlink file whose first line, after all whitespace is removed, contains a non-empty identifier made only of letters, digits, dots, underscores, and dashes.
An unmarked checkout, or one with an invalid marker, falls through to the linked-worktree exemption.
That exemption keeps crewmate and scout worktrees inert because firstmate provisions them as linked git worktrees, where `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`; the test is applied only when the root is itself a git checkout root, so it discriminates a task worktree without excluding a home that merely sits inside some unrelated repo.
It is inert, and writes nothing, in a session that another **live** session has locked out of the home (`state/.lock`, written by `bin/fm-lock.sh`): such a session is read-only and has no supervision of its own to resume.

**Git-ness is a discriminator, never a precondition.**
A deployed primary home is not necessarily a git checkout: the live runtime home is a rebaselined, non-git tree with `bin/` as a plain directory and no `.git` anywhere.
Scoping once opened with `git rev-parse --git-dir || exit 0`, so in the one home the gate was actually installed in it exited before evaluating anything, blocked nothing, and never even created its decision log - while the suites, which all build git fixtures, stayed green (`bug-20260714023716-7c5e1bfb`).
Both shapes must therefore be exercised, and `tests/fm-turnend-guard.test.sh` now runs the gate in a non-git home as well as a git one.
The linked-worktree exemption is also FAIL-CLOSED and git-binary-independent: a linked worktree's `.git` is a regular file (`gitdir: ...`), a real checkout's `.git` is a directory, and a non-git runtime home has no `.git`, so an unmarked home whose `.git` is a plain file is excluded WITHOUT invoking git.
This closes the fail-OPEN gap the git-based check alone carried - a transient `git rev-parse` failure under concurrent fan-in left `GIT_TOP` empty, skipped the exclusion, and let a crew worktree run the primary sweep and fail open, a source of ORD-231's guard-error spam (`data/turnend-failopen-x6/report.md` section 6.5); a genuinely marked secondmate home is still force-included ahead of this check.
The same fail-armed rule governs the lock: only a provably foreign live holder stands the guard down, while an absent, stale, or unreadable lock leaves it armed, so an unreadable lock can never become a second silent way for the gate not to exist.

For an in-scope primary home it evaluates three independent conditions, and blocks when any holds.
It exits silently when none does, so the healthy path stays completely quiet.

**Supervision continuity is off.**
It counts in-flight work from `state/*.meta`.
If work is in flight, it asks `fm_supervision_health <state-dir> <watch-path> [grace-seconds] [home] [harness]` from `bin/fm-supervision-lib.sh`.
For persistent-watcher harnesses, healthy supervision still requires `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`.
That is the same identity-matched live lock and fresh beacon check used by `bin/fm-watch-arm.sh`, so a stale beacon blocks even if a watcher pid is still live and a fresh leftover beacon blocks if the watcher lock is missing, dead, or identity-mismatched.
For Codex, healthy supervision is either a currently running bounded checkpoint watcher with that same valid lock and fresh heartbeat, or a valid durable next-checkpoint schedule in `state/.codex-watch-checkpoint.next.json` that agrees with the managed scheduler adapter.
The Codex schedule is never valid on file content alone: its owner must match a LIVE verified primary - the per-home session lock's live holder pid bound to its full process identity - plus this home's canonical path, UID, and durable codex harness record, and every numeric field is validated individually.
The schedule's sha256 `integrity` field is a corruption checksum only, never an authenticity control: the state directory is same-account-writable by design, so within one Unix account it detects accidents, not forgery, and the live-primary binding is what carries ownership.
Beyond the record, the scheduler adapter reads back the LOADED timer/service contract from systemd itself: the exact clean-launcher `ExecStart`, the environment lease/generation/cadence lines, the linked service (`Triggers`), enabled plus active state, the timer's real next trigger against the record due time, and duplicate units claiming the same home.
The schedule is unhealthy when it is missing, malformed, overdue, owned by another primary or by no live primary, tied to another home, UID, or stale session, not backed by the loaded active enabled managed user timer, duplicated by another active schedule or unit, paired with a live watcher ownership record, or preceded by a failed checkpoint without recovery.
The adapter's test seams (`FM_CODEX_SYSTEMD_FAKE_DIR`, `FM_CODEX_SYSTEMD_SYSTEMCTL`, `FM_CODEX_SYSTEMD_UNIT_DIR`) fail closed outside `FM_SUPERVISION_TEST_MODE=1` with canonically test-owned paths - symlink and `..` aliases are judged as what they address - so no ambient environment variable can substitute a file for the real `systemctl --user` query in production.
`FM_SUPERVISION_TEST_MODE=1` itself is fail-closed at the shared supervision-library boundary: outside a canonically test-owned home and state it errors the whole identity resolution instead of minting a synthetic identity, the managed service's clean-launcher `ExecStart` rebuilds the checkpoint environment from a reviewed allowlist, and the in-script scrub of inherited non-unit `FM_*` variables remains as defense in depth, so neither ambient test mode nor inherited user-manager environment can stand in for a live verified primary (docs/codex-systemd-scheduler.md "Clean launch boundary").
The normalized health states are `healthy-persistent`, `healthy-checkpoint-running`, `healthy-checkpoint-scheduled`, `unhealthy-no-supervision`, `unhealthy-checkpoint-overdue`, `unhealthy-owner-mismatch`, `unhealthy-duplicate-owner`, and `unhealthy-last-checkpoint-failed`.
`bin/fm-watch-checkpoint.sh` acquires the running-checkpoint lease at `state/.codex-watch-checkpoint.running.json` atomically (noclobber create) BEFORE consuming the prior schedule and its armed timer, so a losing or failing prepare preserves the winner and the prior-valid supervision; it then advances the managed timer plus `state/.codex-watch-checkpoint.next.json` only after a normal `quiet` or `wake` result.
Failed checkpoints write `state/.codex-watch-checkpoint.last.json` with `previous_result=failed` and deliberately leave no healthy schedule.
The managed scheduler adapter and its WSL/Linux proof are documented in [`docs/codex-systemd-scheduler.md`](codex-systemd-scheduler.md).

**Finished work is unattended.**
It reads the `needs_firstmate` lane LIVE, at the moment of the turn-end evaluation, through `fm_nf_unattended_ids <state-dir> <data-dir>` from `bin/fm-nf-attention-lib.sh`, computed from `state/<id>.meta`, `state/<id>.status`, and the triage ledger.
It deliberately does NOT read `state/.triage-duty-last.json`, the duty pass's volatile cache: a cache reflects the last pass, not the present, so it would both miss work that finished since and hold the turn hostage for work already discharged.
A non-empty lane blocks, whether or not any task is in flight and whether or not the watcher is healthy.
The sweep's cost is bounded by the number of live tasks, so the turn-end path stays proportional to the fleet, never to any audit backlog.
When it blocks, the message lists the unattended item ids (bounded) and states plainly that re-arming the watcher does not satisfy the condition.

**Captain orders are unaccounted past grace.**
It reads `state/.order-audit-last.json` - the deterministic product of `fm-order.sh audit` - as a cheap bounded `jq`, never a re-enumeration, and blocks when that file reports `unaccounted > 0`.
The full contract, including the four fail-open outcomes (absent, stale, corrupt, fresh) and why the gate demands accounting rather than completion, is in "Gap Closed: captain orders unaccounted past grace" above.
When it blocks, the message lists the unaccounted order ids (bounded) and states that re-running the audit alone does not discharge them; both work axes are stood down together by away mode and the duty kill switch, exactly as the `needs_firstmate` lane is.

**What discharges the gate, and what deliberately does not.**
The gate is discharged only by real lifecycle changes: landing the work and tearing the task down (its meta/status leave `state/` - this covers merged ships, scout reports durably captured then torn down, and safe returns); the crew's status moving off a terminal verb (a steer to `paused:`, a `resolved:` follow-up after an answered decision, a relaunch); a genuine terminal disposition - `resolved` or `rejected` recorded with valid lineage against the item's current evidence; or a captain decision verifiably transferred to the captain's still-visible Needs You column - a `captain_batch` outcome whose hand-off is confirmed by the fingerprint-bound receipt `bin/fm-nf-ack.sh --to-captain` writes only after the Bridge reads the card back.
That last one satisfies both halves of the captain-decision contract: the primary stops re-blocking on work only the captain can decide, and the decision cannot disappear through a mere acknowledgment - a bare `captain_batch` ledger row without the confirmed receipt keeps blocking, and a fresh terminal signal mints a new fingerprint the old receipt does not cover, re-opening the gate.
Nothing else discharges: not a reviewed `fm-nf-ack` receipt, not re-arming the watcher, not a triage `surface` or `claim`, not a `hold` (even a valid dated one - a hold parks the BOARD CARD, and the reconciler reports it as held, but it never parks this gate), not `successor_created`, not a narrative "I handled it", and never any cached triage summary.
The gate is therefore deliberately stricter than `bin/fm-nf-reconcile.sh`'s "unhandled" count, which reports held and dispositioned items separately for the board.
This closes every paper exit the 2026-07-13 incident used: eight holds recorded in 137 seconds, a 181-to-1 successor fan-out, and a `captain_batch` row that made a captain decision vanish (`bug-20260713154240-10d127e0`).

**Fail-open is mandatory, but a read failure is never a silent permit.**
Any failure to read the live state - a missing or broken `bin/fm-nf-attention-lib.sh`, a missing `jq`, an unparseable hook payload, a hung sweep (the sweep runs in a subshell under `timeout(1)` where available, `FM_TURNEND_SWEEP_TIMEOUT`, default 30s) - blocks nothing, so the primary can never be wedged by the gate's own tooling.
The sweep failure that produced ORD-231's guard-error spam was TRANSIENT under concurrent Stop-hook fan-in, not a code defect (the lib is byte-identical across homes and sources cleanly in isolation - `data/turnend-failopen-x6/report.md` section 2), so the sweep is retried a bounded number of times (`FM_TURNEND_SWEEP_ATTEMPTS`, default 2, with `FM_TURNEND_SWEEP_RETRY_DELAY`, default 0.2s) before a guard_error is declared; a timeout (124) is never retried, and a persistently-broken environment still reports guard_error after the last attempt.
But the permit is classified `allowed_guard_error`, not an ordinary empty lane: the guard prints a loud bordered banner naming the failed component, records a bounded component classification in the decision log's `nf_error` field, and raises one durable bug through the sanctioned bug CLI (`FM_FLEET_TRIAGE_BUG_CLI` overrides the CLI; `off` disables the signal).
That bug signal is COALESCED fleet-wide and time-windowed, keyed on the failure fingerprint (the component slug), in a shared store (`FM_GUARD_ERROR_COALESCE_DIR`, default `${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/guard-error`): the first occurrence in a window (`FM_GUARD_ERROR_COALESCE_WINDOW`, default 86400s) files ONE bug carrying caller identity, and every later occurrence with the same fingerprint - from ANY home or worktree for the user - only increments the shared record instead of filing a new bug.
This replaces the old per-`$STATE` `state/.turnend-guard-error-reported-*` markers, which could not stop a different home or worktree from re-filing the identical text and were cleared on the next healthy evaluation, so an INTERMITTENT failure re-filed a fresh captain bug on every recurrence - the mechanism behind ~58 identical open bugs in three days (`data/turnend-failopen-x6/report.md` sections 5 and 6.4).
After the window elapses a genuinely-new recurrence surfaces a fresh bug, so a real regression is never muted forever.
Diagnostics carry component names and caller identity (resolved `FM_ROOT`, state dir, cwd, hook source, host, pid) only - never transcript content or secrets - so a guard_error is traceable to the process that produced it, closing the attribution gap that made the duplicate bugs impossible to trace (`data/turnend-failopen-x6/report.md` sections 4 and 6.1).
The reverse direction is not open: the ledger fold skips malformed rows, so ledger corruption reverts its items to unattended (they keep blocking) rather than silently discharging them.

**Stand-downs are recorded as stand-downs.**
Away mode (`state/.afk`) stands the gate down because the away daemon owns supervision and escalation there; the lane is still swept and logged, so the stand-down can never silently lose work, and the first evaluation after the flag clears blocks on the same untouched items again.
The duty kill switch (`FM_TRIAGE_DUTY=off`) stands the gate down as the operator escape hatch if the gate itself ever misbehaves - and because an escape hatch in use must never look like a normal healthy path, it prints a loud `KILL SWITCH ENGAGED` banner on every primary turn end while engaged, naming any work it is suppressing.
The switch is an environment variable only: nothing in this repo sets it, no config file carries it, and no documented workflow instructs it, so it cannot be engaged by ordinary firstmate operation - it must be deliberately exported into the session or hook environment by the operator, and it is restored by simply unsetting it.
Both stand-downs are logged as their own decisions, never as compliant permits.

## Decision Log

Every primary turn-end evaluation - permitted or blocked - appends one JSON line to `state/.turnend-guard.log`: timestamp, watcher status, normalized supervision health and reason, supervision harness, in-flight count, `needs_firstmate` count, a bounded item-id digest, the `nf_gate` state, the read-error component (`nf_error`), the unaccounted-order count (`orders`) with its bounded digest (`order_items`), the order read-error (`order_error`) and the audit file's age (`order_audit_age`, null when the file is absent), the decision, the reason, whether loop protection was active, and caller identity (`fm_root`, `state_dir`, `cwd`, `hook_source`, `host`, `pid`) so any decision - a guard_error especially - is traceable to its originating process (ORD-231).
The log carries ids, counts, and decisions only - never transcript content.
It is best-effort (a log that cannot be written never changes the decision or wedges the turn) and size-capped (`FM_TURNEND_LOG_MAX`, default 2000 lines, trimmed to half when exceeded).
`FM_TURNEND_LOG` overrides the path.

Each record also carries the OBSERVATIONS behind the watcher verdict, not just the verdict: `beacon_age`, `lock_pid`, `lock_pid_alive`, `identity_match`, `home_match`, `path_match`, and `watcher_fail` (the first check that failed, one of `no-lock-pid`, `lock-pid-dead`, `home-mismatch`, `path-mismatch`, `identity-unrecorded`, `identity-unreadable`, `identity-mismatch`, `beacon-stale`, or `none`).
`bin/fm-wake-lib.sh` sets the same facts as `FM_WATCHER_DIAG_*` after every `fm_watcher_healthy` call, so any caller can record them, and the blocking banner prints the same `observed:` line.

Those fields exist because `watcher: down` alone cannot explain a decision that a fresh beacon appears to contradict.
"No live watcher (last beat: 1s ago)" is not a contradiction: the beacon outlives the watcher that touched it, so a fresh beacon with an ABSENT lock is both possible and normal right after a watcher exits on a wake.
On 2026-07-14 a broken check script (`state/*.check.sh` printing while exiting non-zero) woke the watcher on every sweep; the watcher exits on a wake and releases `state/.watch.lock` with it, so supervision genuinely collapsed every cycle and every `blocked_watcher_down` was correct.
It took three wrong diagnoses to find, because the record of the day logged the watcher only as `healthy`/`down` and left every explanatory field null.
`watcher_fail=no-lock-pid` with a fresh `beacon_age` says it in one line.
See `bin/fm-watch.sh`'s `run_check` for the check-failure path that fix produced.

The decision taxonomy (outcome names per ORD-060), and what counts toward the acceptance metric ("zero permitted turn ends while unattended Needs FirstMate work exists"):

- `allowed_needs_firstmate_empty` - the lane was genuinely empty and the watcher healthy. Compliant.
- `allowed_after_valid_progress` - a loop-guarded stop after real progress: the id set recorded at the block (`state/.turnend-guard-block-ids`) actually shrank because work was discharged. Compliant.
- `blocked_needs_firstmate` - refused (exit 2) with unattended work named; the reason records when the watcher was down or orders were unaccounted too.
- `blocked_unaccounted_orders` - refused (exit 2) for unaccounted captain orders when no unattended crew work also blocked (needs_firstmate takes the decision label when both fire); the reason still names every axis.
- `blocked_watcher_down` - refused (exit 2) for the watcher alone.
- `allowed_loop_protection_without_progress` - permitted ONLY because hook recursion protection forbids a second block in one turn; the unattended crew and unaccounted-order set did not shrink. NOT a compliant permit. Every no-progress stand-down also raises ONE coalesced anomaly (fingerprint `turnend-standdown-no-progress`, occurrence-counted through the same fleet-wide store as the guard-error signal), so a repeated stand-down is a single durable signal, never a bug per turn - the structural fix for the bug-per-occurrence class (`guard-error-spam-j6`).
- `allowed_afk_owner` / `allowed_duty_disabled` - permitted because away mode or the kill switch stands the gate down. NOT compliant permits.
- `allowed_guard_error` - permitted because the guard could not inspect state. NOT a compliant permit.

**The second stop attempt, exactly.**
The Claude Stop-hook contract forbids blocking when `stop_hook_active=true`: a hook that blocks its own forced continuation recurses, and an agent that cannot make progress would be wedged in an un-endable session.
So the second stop IS allowed - and the honest record plus a bounded fallback is what prevents "do nothing and exit" from being free: the permit is logged as `allowed_loop_protection_without_progress` (never compliant), one coalesced `turnend-standdown-no-progress` anomaly is filed, and the guard queues one durable `check` wake (`turnend-guard` key, deduped to one pending record) naming the unresolved crew signals and unaccounted orders through the same `state/.wake-queue` every turn drains FIRST, so the unresolved items are forced to the front of the next primary turn.
The unchanged unattended item does remain after the turn ends - that is the documented, bounded limitation of a non-recursive hook - but it remains VISIBLY: counted in the log, queued as the next turn's first work, and re-blocked at that turn's first stop attempt.
Progress across the two attempts is judged from the durable prior blocked-id set, not from the current read alone: a crew id is discharged when it leaves the live lane, but a prior order id is discharged **only** by a fresh authoritative audit that no longer lists it, so a stale, absent, or corrupt current audit can never manufacture progress or silently drop a retained order (see "Audit authority across the two stop attempts" above).

## Anti-Evasion Metrics

`bin/fm-turnend-metrics.sh [--json]` is the read-only reporter over the decision log and the live lane.
Cumulative panel: every decision outcome counted by name (including `blocked_unaccounted_orders`), plus `permits_with_unattended_work` - permitted turn ends recorded while the `needs_firstmate` lane OR the unaccounted-order count was more than zero, the direct complement of the acceptance metric.
Live panel: `unattended` (items holding the gate now), `paper_parked` (items whose terminal signal remains while a non-discharging disposition sits on them - the evasion signature: holds, successors, unconfirmed captain batches, bare claims), and `discharged_pending_teardown` (genuinely dispositioned items whose signal awaits normal closeout).
A drift of `paper_parked` upward while blocks go down is the gate being evaded, not obeyed - watch for another eight-holds-in-137-seconds burst.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repo-root `state/`.
`FM_GUARD_GRACE` controls the beacon freshness window and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard fails open and exits 0 because it cannot safely read loop-guard fields.

## Harness Integrations

All verified primary harnesses have a tracked integration:

- `claude`: `.claude/settings.json` registers a `Stop` hook command anchored through `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh`.
- `codex`: `.codex/hooks.json` registers a `Stop` hook that reads the hook payload once, anchors the executable to the hook command process working directory, verifies that root is firstmate-shaped and hook-bearing, and pipes the original payload to that checkout's `bin/fm-turnend-guard.sh`.
- `opencode`: `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`, lets the watcher-arm coordinator handle normal idle supervision first, runs the shared guard only when that coordinator does not act, and uses `client.session.promptAsync` to force one follow-up prompt when the guard returns 2.
- `pi`: `.pi/extensions/fm-primary-turnend-guard.ts` listens for `agent_settled`, marks the extension version loaded for session-start checks, runs the shared guard once per logical agent run, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one follow-up prompt when the guard returns 2.
- `grok`: `.grok/hooks/fm-primary-turnend-guard.json` registers a `Stop` hook that invokes `bin/fm-turnend-guard-grok.sh`.
  The adapter runs the shared guard and, when it returns 2, invokes `grok --resume <sessionId> -p <guard-reason>` with `GROK_TURNEND_GUARD_ACTIVE=1`.
  It does not pass `--permission-mode`, so the passive Stop hook cannot grant stronger tool permissions than Grok's resumed-session default.

Claude and Codex support a direct blocking Stop hook.
For those harnesses, exit status 2 plus stderr from `bin/fm-turnend-guard.sh` blocks the stop and feeds the reason back into the model.
Both payloads include `stop_hook_active`; when it is true, the shared guard exits 0 so the harness can end after one forced continuation.

OpenCode, Pi, and Grok expose passive lifecycle callbacks for this purpose.
Their adapters fail open at the hook boundary to avoid corrupting a user session, but they force one follow-up turn when the shared predicate blocks.
Each adapter carries its own in-process or environment loop guard so the forced follow-up does not recursively schedule another follow-up.
Pi keeps that latch active across every internal tool turn and clears it only when the generated guard follow-up reaches `agent_settled`, or immediately when follow-up delivery fails.
If a passive adapter cannot call its SDK method, cannot find `grok`, or cannot recover the Grok session id, it fails open and relies on the pull-based `fm-guard.sh` warning at the next fleet command.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it points back to the active harness protocol instead of hardcoding one background-arm command.

## Empirical Validation

All harnesses were validated on 2026-07-08 in scratch repos or throwaway homes, not against the captain's live primary fleet state.

Claude Code 2.1.204 preserved the existing behavior.
Hook file used: `.claude/settings.json`.
Command run: `claude -p "Say hi in exactly one word." --dangerously-skip-permissions --output-format json` with a scratch Stop hook that printed `SMOKETEST: you must say the word BANANA before stopping` and exited 2.
Observed output: the first stop payload had `stop_hook_active=false`, the stop was blocked, the model continued with `BANANA`, and the second stop payload had `stop_hook_active=true` and was allowed.
Earlier validation on 2026-07-04 also verified that `CLAUDE_PROJECT_DIR` is set to the settings-loaded project root, while the hook command itself runs from the session cwd.

Codex `codex-cli 0.142.1` was validated with a scratch `.codex/hooks.json` Stop hook.
Hook file used: `.codex/hooks.json`.
Command run: `codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Say hi in exactly one word.'`.
Observed output: the first model output was `Hi`, the Stop hook exited 2, Codex logged `hook: Stop Blocked`, the model continued with `CODEXHOOK`, and the second hook call had `stop_hook_active=true`.
The Stop payload included `cwd`.
Command run for root-signal probe: `codex exec --ephemeral --json --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Use the shell tool to run mkdir -p outside && cd outside && pwd, then use the shell tool again to run pwd. Your final answer must include the two observed outputs.'`.
Observed output: the first command printed `<scratch>/outside`, the second command printed `<scratch>`, the Stop hook process `pwd -P` printed `<scratch>`, payload `cwd` printed `<scratch>`, and `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, and `CODEX_CWD` were empty.
The tracked command therefore treats hook process PWD as the hook-loaded firstmate root and does not let payload `cwd` choose an executable.
It still passes the original payload to `bin/fm-turnend-guard.sh`, so the shared loop guard reads `stop_hook_active`.

OpenCode 1.17.6 was validated with project plugins under scratch `.opencode/plugins/`.
Hook file used: `.opencode/plugins/fm-smoke.js` for throw testing and `.opencode/plugins/fm-primary-turnend-guard.js` for follow-up testing.
Command run for passive behavior: `opencode run --print-logs --log-level DEBUG --dangerously-skip-permissions 'Say hi in exactly one word.'`.
Observed output: the plugin received `session.idle`, threw an error, and `opencode run` still exited 0 with `Hi`, proving `session.idle` cannot block directly.
Command run for follow-up behavior: `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt 'Say hi in exactly one word.' --print-logs --log-level INFO`.
Observed output: the plugin called `client.session.promptAsync`, the TUI ran a second turn, and the second model output contained `OPENCODEHOOK`.
In noninteractive `opencode run`, `promptAsync` returned successfully but the process exited before displaying the follow-up, so this adapter is trusted for primary TUI sessions and documented as passive/fail-open in headless mode.

Pi 0.80.5 was re-validated on 2026-07-09 in a disposable primary-shaped clone with isolated `PI_CODING_AGENT_DIR`, isolated `FM_HOME`, and tmux socket `fm-pi-q6-lab`.
Hook files used: the tracked `.pi/extensions/fm-primary-turnend-guard.ts` and `.pi/extensions/fm-primary-pi-watch.ts`.
Commands run inside separate interactive turns: `printf PI_E2E_BASH_ONE` through Pi's bash tool, `README.md:1-5` through Pi's read tool, and `printf PI_E2E_BASH_TWO` through Pi's bash tool.
Command used to make the shared predicate unhealthy: `: > "$FM_HOME/state/pi-e2e.meta"`.
The next no-tool prompt produced exactly one `TURN WOULD END BLIND` follow-up, and that follow-up called `fm_watch_arm_pi` once with output `watcher: started Pi extension arm child 1`.
The three earlier tool turns produced no guard follow-up because no work was in flight.
Command used to fire the watcher: `printf 'done: pi e2e watcher fire\n' > "$FM_HOME/state/pi-e2e.status"`.
Observed output after the wake: Pi ran `bin/fm-wake-drain.sh`, read the terminal status, called `fm_watch_arm_pi`, and rendered `watcher: started Pi extension arm child 2`.
The complete pane contained one guard message and zero foreground `bin/fm-watch-arm.sh` bash calls.
`/quit` printed `PI_EXIT=0`, and the second arm process plus its watcher child were both gone afterward.

Grok 0.2.91 was validated with a scratch `GROK_HOME` and symlinked auth/config.
Hook file used for tracked project-hook loading: `<scratch-project>/.grok/hooks/fm-smoke.json`, matching the tracked `.grok/hooks/fm-primary-turnend-guard.json` location.
Command run for project-hook loading: `GROK_HOME="$scratch/grok-home" grok --trust -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the project Stop hook fired under `--trust` and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`.
Hook file used for passive behavior and forced-resume behavior: `$GROK_HOME/hooks/fm-primary-turnend-guard.json` plus `bin/fm-turnend-guard-grok.sh`.
Command run for passive behavior: `GROK_HOME="$scratch/grok-home" grok -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the global Stop hook fired and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`, but exiting 2 did not make the model continue.
Command run for forced resume behavior: the Stop hook ran `GROK_TURNEND_GUARD_ACTIVE=1 GROK_HOME="$scratch/grok-home" grok --resume "$session_id" -p 'SMOKETEST: say exactly GROKRESUMEHOOK...' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the outer turn printed `Hi`, the nested resumed turn printed `GROKRESUMEHOOK`, and the nested Stop hook saw `GROK_TURNEND_GUARD_ACTIVE=1` and did not recurse.
That validation command used `--permission-mode bypassPermissions` only to keep the scratch smoke unattended; the tracked adapter intentionally omits `--permission-mode`.
Project-local Grok hooks did not fire in scratch single mode without a trust grant.
The primary integration therefore requires the primary firstmate checkout to be trusted for Grok hooks, which can be done with `/hooks-trust` or launch-time `--trust`.
If Grok declines to load project hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.

**2026-07-09 update:** grok 0.2.93 broke the `.grok/hooks/fm-primary-turnend-guard.json` Stop hook with `hook not executed: required env var(s) not set: ${root}`, because grok's own `${VAR}` expansion over the raw `command` string does not tolerate a bare local variable assigned earlier in the same `bash -lc` script.
The hook command was fixed to reference `${GROK_WORKSPACE_ROOT:-}` directly everywhere instead of assigning it to `$root` first, and re-validated against grok 0.2.93 to fire and complete cleanly.
See `docs/arm-pretool-check.md`'s "Harness wiring" section for the same Grok expansion requirement; that document's Grok hook shares the same fix.

### 2026-07-12: secondmate-home enablement and the autonomous background-notify wake

The guard originally early-exited in every secondmate home on the `.fm-secondmate-home` marker.
That was a scoping choice inherited from the guard's primary-only origin, not a defense against any secondmate-specific hazard.
A genuinely marked secondmate home is now force-included as a guarded primary regardless of whether it is a treehouse-leased linked worktree or a git-cloned plain checkout.
Only unmarked child worktrees fall through to the linked-worktree exemption, and marker validation prevents an empty, malformed, or symlink marker from spoofing inclusion.

"No turn ends blind" for a secondmate is delivered by the same two mechanisms the main primary relies on.
Mechanism B, the turn-end backstop, is this guard; its secondmate-home behavior is covered by hermetic tests in `tests/fm-turnend-guard.test.sh` (`test_hook_blocks_in_secondmate_own_home`, `test_hook_blocks_in_treehouse_leased_secondmate_home`, `test_hook_silent_in_idle_secondmate_home`, `test_hook_secondmate_loop_guard_allows_retry`, `test_hook_secondmate_reinvoke_recovery_loop`, `test_hook_silent_in_secondmate_child_worktree`, and `test_hook_exempts_linked_worktree_with_stray_marker`).
Mechanism A, the autonomous wake, is a harness property: when a background watcher task exits, the harness re-invokes the model, which drains the wake, advances children, and re-arms a fresh watcher.
Mechanism A cannot be a hermetic CI assertion because it requires a live model session, so it is recorded here as a dated first-hand measurement while `test_hook_secondmate_reinvoke_recovery_loop` covers the guard's deterministic half of the same recovery loop.

Autonomous-re-invoke measurement, run first-hand on Claude Code 2.1.207 (Darwin 25.5.0) on 2026-07-12.
Procedure: launch a detached `run_in_background` Bash task that models a one-shot watcher - it records a launch epoch, runs `sleep 25`, then records a completion epoch just before exit, writing only to the session scratchpad - then end the turn with no further tool calls and no pending question, a genuinely idle session with no human input.
Observed marker timestamps:

```
launch_epoch    = 1783890980   (14:16:20)   turn ends, session goes idle
complete_epoch  = 1783891005   (14:16:45)   background task exits, 25s idle
reinvoke_epoch  = 1783891016   (14:16:56)   MODEL RE-INVOKED
--------------------------------------------------------------
wake latency (task complete -> model re-invoked): 11s, with ZERO human input
```

The re-invocation arrived as a `<task-notification>` whose accompanying system notice stated verbatim "No human input has been received since the last genuine user message in this conversation".
So the model was re-invoked solely by the background task's completion while idle, which is Mechanism A - the same background-notify wake the Claude supervision protocol relies on for the main primary.
This matches the harness tool contract that a `run_in_background` task "keeps running across turns and re-invokes you when it exits", and reproduces the 11s latency the task audit measured independently on the same harness version.
No Herdr command was issued and no fleet state was touched; the experiment wrote only to the session scratchpad, which was discarded.

## Tests

`tests/fm-turnend-guard.test.sh` covers the shared predicate, primary scoping in both a git-checkout home and a non-git rebaselined home (including a secondmate's own home being guarded like the main primary while its child worktrees stay exempt), the linked-worktree exemption under a non-empty lane, session-lock ownership (armed when absent, stale, or ours; inert and non-mutating under a live foreign holder), `FM_HOME` and `FM_STATE_OVERRIDE` precedence, Pi logical-run latch behavior for no-tool and multi-tool runs, fail-open behavior without `jq`, tracked hook registration for all five harnesses, and the Grok adapter's forced-resume loop guard and permission-mode regression.
It also covers the third predicate (ORD-260 S2): blocking on unaccounted captain orders read from the audit file, the four fail-open outcomes (absent is silent, stale fails open without a bug, corrupt fails open with one coalesced anomaly, fresh enforces), the combined crew-plus-order block and progress accounting under loop protection, the away-mode stand-down, and the coalesced no-progress stand-down anomaly.
The `test_hook_retry_*` and `test_hook_first_stop_completeness_failures_*` cases encode the ruling's exhaustive `(audit x stop x prior)` table cell by cell: a fresh order block followed by a stale, absent, or corrupt audit on the loop-guarded retry retains the order as a stand-down (never a silent discharge), a fresh zero-unaccounted audit after a real accounting act discharges cleanly, the mixed-axis case proves per-axis recognition (a departed crew id is recognized while an unknown order stays retained), and every completeness failure (partial, empty, non-string, duplicate, or non-object `order_id`) is corrupt at both stops.
The **R7 canary** (`test_hook_retry_partial_id_audit_retains_all_prior_orders`) is the single case that proves or disproves the authority contract: a fresh, count-matched audit covering only one of two declared orders must retain both, never `allowed_after_valid_progress`.
All are hermetic, with a sandboxed coalesce store and bug CLI so the live captain ledger is never touched.
The default behavior suite does not invoke live language-model harnesses.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` opts into the isolated interactive Pi regression recorded above.
