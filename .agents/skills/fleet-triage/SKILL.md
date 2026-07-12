---
name: fleet-triage
description: >-
  Agent-only operating duty for proactively reconciling existing fleet evidence into reversible coordination work and captain-gated decisions.
user-invocable: false
metadata:
  internal: true
---

# Fleet triage

Load this skill when the primary FirstMate starts or recovers, handles an actionable wake, closes or tears down work, re-evaluates the backlog, or receives a fleet-triage digest with unhandled candidates.
This duty belongs only to the primary FirstMate.
A secondmate may act on concrete work routed by the primary, but it must not initiate this duty or invent its own audits.

## Purpose and boundary

Fleet triage turns evidence the fleet already has into the next useful coordination action.
It is not permission for broad speculative code audits.
Unknown unknowns here means patterns in existing bugs, reports, task state, backlog records, and visibility history that justify a bounded scout.

The enumerator is read-only and its output is advisory.
The primary remains responsible for checking current source truth before acting because backlog notes and terminal status events can be stale.
The existing `visibility_history` lane consumes `bin/visibility.mjs audit --json` diagnostics when the Fleet Bridge CLI is available.
Those findings remain read-only reconciliation evidence; they do not create a new lane or authorize autonomous disposition.

Automatically perform reversible coordination when the evidence and scope are clear.
This includes authoring or correcting backlog records, grouping related candidates, routing known-shape work, dispatching a bounded scout when the implementation is unclear, recording or resolving bugs through the sanctioned interface, and preparing a concise decision batch.

Escalate merges when yolo is off, production or serving restarts, secrets and credentials, destructive or force actions, security-sensitive work, strategic product choices, and genuine ambiguity between materially different outcomes.
The prime directives and project delivery mode remain authoritative.

## When to run

Run a full triage pass at locked primary session start or recovery, on a heartbeat that reaches the agent, after ship or scout work completes, after closeout or teardown, after a backlog mutation, after recording or resolving a bug, after a blocker completes and frees its dependents, and in the AFK-exit catch-up.
Run a targeted pass after an ordinary actionable wake by reading the affected lane and then checking whether the resulting state changed another lane.
Use a full pass when several tasks finish together, a scout exposes cross-project work, or a targeted pass reveals a shared blocker or visibility mismatch.

`bin/fm-triage-duty.sh <trigger>` is not a static reminder: it RUNS the read-only enumerator itself (`bin/fm-fleet-triage.sh --json`, once per pass) and prints a bordered `FLEET TRIAGE DUTY` banner ONLY when that pass actually finds actionable state, carrying the pass's machine-readable result (`TRIAGE_DUTY_RESULT:` - trigger, scope, actionable, ownerless, unhealthy, captain_gated, fingerprint) inline.
A clear fleet stays silent, exactly like every other diagnostic in this codebase; being shown a banner is itself proof the pass ran and found something, not just a prompt that something might be there.
Eleven triggers exist: `wake-drain` (targeted), `heartbeat`, `ship-complete`, `scout-complete`, `teardown`, `session-start`, `recovery`, `backlog-mutation`, `bug-mutation`, `blocker-freed`, and `afk-exit` (all full passes).

Six of those fire themselves from a script chokepoint firstmate owns: `bin/fm-wake-drain.sh` (`wake-drain`/`heartbeat`), `bin/fm-teardown.sh` (`teardown`/`scout-complete`), `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` (`ship-complete`), and `bin/fm-session-start.sh` itself (`session-start`).
The other five have no script chokepoint firstmate owns - `tasks-axi` and the bug CLI are external tools, recovery reconciliation and away-mode exit are conversational transitions - so run them explicitly, by name, rather than trusting memory: `bin/fm-triage-duty.sh recovery` once recovery reconciles a dead or respawned endpoint, `bin/fm-triage-duty.sh backlog-mutation` after a hand-edited or `tasks-axi` backlog change, `bin/fm-triage-duty.sh bug-mutation` after recording or resolving a bug through the bug CLI, `bin/fm-triage-duty.sh blocker-freed` after a blocker completes and its dependents come free, and `bin/fm-triage-duty.sh afk-exit` in the AFK-exit catch-up.
Naming the exact command here, rather than "load fleet-triage and run a pass," is deliberate: a concrete command is grep-able and testable, so it does not silently rot into "I meant to check" the way a purely conversational reminder can.

The pass stays read-only regardless of what it finds: it never records an outcome, edits the backlog, or touches a bug or task, and it never blocks the operation that triggered it - only `state/.triage-duty-last.json`, its own volatile result cache, changes as a side effect.
If the enumerator itself fails (a missing `jq`, a broken snapshot), the pass prints a distinct `ENUMERATION FAILED` banner and caches that failure rather than silently reverting to "nothing actionable" - `bin/fm-guard.sh`'s supervision preflight then keeps surfacing the outage at later checkpoints even if this banner scrolls past.

Do not run or act from a session that failed to acquire the fleet lock.
Do not keep rerunning an unchanged full pass in the same turn: several triggers can fire in one turn (a merge, then a teardown, then a drained wake), and they collapse into one full pass over the resulting state, not three.

## Reading the output

Use the digest for orientation and the JSON output when taking action.
The JSON schema is `fm-fleet-triage/v2` and the script help owns its exact flags and ledger wire format.

Treat the lanes as follows.

- `captain_orders` contains the captain orders the durable order inbox says still need firstmate: untriaged, ownerless, missing lineage, stale, a hold whose review date arrived, a cleared blocker, a vanished linked successor, or a decision the captain owes.
  It leads the digest, because an unanswered captain request outranks the housekeeping in every other lane.
  This lane references the inbox and never writes it: disposition an order through `bin/fm-order.sh`, the only sanctioned writer, and record the triage outcome in the triage ledger as usual (AGENTS.md section 15, docs/captain-orders.md).
- `needs_firstmate` contains unhandled terminal signals supplied by the existing Needs FirstMate reconciler.
- `bugs` contains open bug records from the configured sanctioned bug interface.
- `scout_reports` contains report artifacts without a matching backlog record and therefore needing disposition.
- `backlog_hygiene` contains ready, newly unblocked, duplicate, or unstructured backlog candidates.
- `visibility_history` contains active tasks missing from the backlog, plus backlog rows that declare themselves visibility work with an explicit marker inside the row's metadata group, alongside `repo:` and `kind:` — `- [ ] some-id - Title (repo: fleet-bridge, triage: visibility-umbrella)`.
  A row joins this lane only by carrying `triage: visibility` or `triage: visibility-umbrella`; a keyword in a title never does, and no backlog id is special-cased.
  Keep the marker inside an existing metadata group so it stays out of the row's title.
  Mark a row `visibility-umbrella` only when it is genuine product semantics, because that marker is what routes it to the captain.
- `ledger_health` contains one item, and only when the processing ledger holds rows the fold had to skip.
  A malformed row is skipped rather than fatal, which keeps the fleet readable, but a skipped `surface` row costs its item the `first_seen_at` stamp, so that item can never age into `stale_unprocessed` and no health check can see it sitting unprocessed.
  However many rows are corrupt, the lane raises exactly one item, so a damaged ledger never grows a chain of triage-about-triage work.

An unavailable lane is missing evidence, not evidence that the lane is empty.
Fix or explicitly note the missing input before claiming the fleet is clear.

An unhandled item is reported as `actionable`, and it stays actionable until it carries a terminal outcome with lineage.

## Outcomes, not acknowledgements

An item is not handled because it was printed, seen, summarized, or acknowledged.
It is handled only when it reaches one of five outcomes, each of which must name its lineage:

- `successor_created` with the id of the task, scout, or backlog item that now owns the work.
- `resolved` with the evidence that resolved it: a commit, a merged PR, a report, a bug resolution.
- `rejected` with the reason it will not be acted on.
- `held` with both a reason and a review date or explicit unblock condition.
- `captain_batch` with the id of the decision batch it was packaged into.

There is deliberately no acknowledge verb.
Record every outcome with `bin/fm-fleet-triage-record.sh`, which is the only sanctioned writer of the processing ledger and refuses a terminal outcome that has no lineage attached.
Claim an item with `claim` before working it so a second session does not pick it up, and `release` it if you put it down without an outcome.
Never record an outcome before its disposition is durable in the domain system that owns it: the bug CLI for bugs, `tasks-axi` for backlog, the normal ship and scout lifecycle for tasks.
The triage ledger records that the work was converted, never the work itself.

The enumerator re-surfaces an item whose recorded disposition stopped holding, reporting why in its `health` field: the evidence moved, a linked successor does not exist, a hold's review date arrived, a claim went stale, or a terminal outcome lost its lineage.
Treat a re-surfaced item as live work again, not as a duplicate.
Age and repeated appearances raise an item's priority and demand a recorded reason for the delay; they are never themselves a reason to escalate to the captain.
Escalate on the decision's content, per the action classes above.

For a `needs_firstmate` item, also complete the existing Needs FirstMate acknowledgement procedure, because the triage ledger does not replace that lane's own handling state.

## Recording a disposition, and the one mechanical auto-action

Recording is mechanics; matching is judgment.
Once you have made the call - matched a bug to its resolving evidence, judged a report superseded or promoted, decided a backlog follow-up - act through the owning domain interface directly (`bug resolve`, `bug record`, `tasks-axi add`), then record the outcome with `bin/fm-fleet-triage-record.sh` as above.
No wrapper script invents matching logic between the two steps.
The single sanctioned exception is `bin/fm-fleet-triage-act.sh unblock`, the one triage correction that is mechanically known rather than judged: it unblocks `backlog_hygiene` items whose blocker the enumerator has proven done, via `tasks-axi unblock`, and records each disposition through the sanctioned writer.
It prints a dry run by default and executes only with `--apply`; its header owns the exact guards and re-surface behavior.
It deliberately never dispatches the newly-ready item - the moved evidence returns it to this duty's normal judgment loop.

## Action loop

For each actionable item, verify its current source and overlap with in-flight or queued work.
Classify it as automatic reversible coordination, a captain gate, a bounded scout, or a hold with a concrete recheck condition.
Prefer one batch for related bugs or reports over several overlapping tasks.
Promote a report finding into an existing umbrella item when that lineage already owns the gap.
Create a new backlog item only when no current item owns the follow-up.
Route a known-shape fix when project, scope, acceptance criteria, and non-overlap are clear.
Route uncertainty to a bounded scout instead of guessing an implementation.
Present captain gates as a compact decision batch with the options, evidence, tradeoff, and recommended choice.
Record the outcome for each item the disposition actually covers, and leave the rest actionable.

Two separate switches exist; do not confuse them.
`FLEET_TRIAGE_MODE=enumerate_only` is a REPORT-ONLY mode, not a way to silence anything: the enumerator and `bin/fm-triage-duty.sh` still run in full and still report - a duty pass can still print a banner and still cache its own result - but every ledger write and domain action is refused, enforced by `bin/fm-fleet-triage-record.sh` refusing to write.
`FM_TRIAGE_DUTY=off` is the actual kill switch for the duty prompt itself: under it, `bin/fm-triage-duty.sh` produces no output and runs nothing at all - no enumeration, no state-file write, no banner. It does not affect `bin/fm-fleet-triage.sh` or `bin/fm-fleet-triage-record.sh` run directly.

## Closeout

After action, rerun targeted triage for the affected lane.
Run a full pass when closeout unblocks queued work or changes shared visibility history.
Resume normal supervision once every remaining item has an owner, an active claim, a successor, a hold with a review condition, a captain batch, or a recorded rejection or resolution, and every unavailable lane has been accounted for.
