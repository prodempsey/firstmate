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

Automatically perform reversible coordination when the evidence and scope are clear.
This includes authoring or correcting backlog records, grouping related candidates, routing known-shape work, dispatching a bounded scout when the implementation is unclear, recording or resolving bugs through the sanctioned interface, and preparing a concise decision batch.

Escalate merges when yolo is off, production or serving restarts, secrets and credentials, destructive or force actions, security-sensitive work, strategic product choices, and genuine ambiguity between materially different outcomes.
The prime directives and project delivery mode remain authoritative.

## When to run

Run a full triage pass at locked primary session start or recovery, on a heartbeat that reaches the agent, after backlog mutation, and after closeout or teardown.
Run a targeted pass after an ordinary actionable wake by reading the affected lane and then checking whether the resulting state changed another lane.
Use a full pass when several tasks finish together, a scout exposes cross-project work, or a targeted pass reveals a shared blocker or visibility mismatch.

Do not run or act from a session that failed to acquire the fleet lock.
Do not keep rerunning an unchanged full pass in the same turn.

## Reading the output

Use the digest for orientation and the JSON output when taking action.
The JSON schema is `fm-fleet-triage/v2` and the script help owns its exact flags and ledger wire format.

Treat the lanes as follows.

- `needs_firstmate` contains unhandled terminal signals supplied by the existing Needs FirstMate reconciler.
- `bugs` contains open bug records from the configured sanctioned bug interface.
- `scout_reports` contains report artifacts without a matching backlog record and therefore needing disposition.
- `backlog_hygiene` contains ready, newly unblocked, duplicate, or unstructured backlog candidates.
- `visibility_history` contains active umbrella work about Bridge visibility and Crew Task History continuity.

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

`FLEET_TRIAGE_MODE=enumerate_only` is the kill switch.
Under it the enumerator still inspects, classifies, and reports, while every ledger write and domain action is refused.

## Closeout

After action, rerun targeted triage for the affected lane.
Run a full pass when closeout unblocks queued work or changes shared visibility history.
Resume normal supervision once every remaining item has an owner, an active claim, a successor, a hold with a review condition, a captain batch, or a recorded rejection or resolution, and every unavailable lane has been accounted for.
