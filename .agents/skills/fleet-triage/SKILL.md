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
The JSON schema is `fm-fleet-triage/v1` and the script help owns its exact flags and ledger wire format.

Treat the lanes as follows.

- `needs_firstmate` contains unhandled terminal signals supplied by the existing Needs FirstMate reconciler.
- `bugs` contains open bug records from the configured sanctioned bug interface.
- `scout_reports` contains report artifacts without a matching backlog record and therefore needing disposition.
- `backlog_hygiene` contains ready, newly unblocked, duplicate, or unstructured backlog candidates.
- `visibility_history` contains active umbrella work about Bridge visibility and Crew Task History continuity.

An unavailable lane is missing evidence, not evidence that the lane is empty.
Fix or explicitly note the missing input before claiming the fleet is clear.

The item fingerprint covers the candidate's material fields.
An acknowledgement means the candidate was dispositioned, not merely noticed.
After completing the action, routing concrete successor work, or deliberately placing the candidate on hold with a durable reason, append the exact lane, id, and fingerprint tuple to the handled ledger described by the script.
Never acknowledge an item before its disposition is durable.
A changed candidate receives a new fingerprint and surfaces again.
For a `needs_firstmate` item, also complete the existing Needs FirstMate acknowledgement procedure because the triage ledger does not replace that lane's own handling state.

## Action loop

For each unhandled candidate, verify its current source and overlap with in-flight or queued work.
Classify it as automatic reversible coordination, a captain gate, a bounded scout, or a hold with a concrete recheck condition.
Prefer one batch for related bugs or reports over several overlapping tasks.
Promote a report finding into an existing umbrella item when that lineage already owns the gap.
Create a new backlog item only when no current item owns the follow-up.
Route a known-shape fix when project, scope, acceptance criteria, and non-overlap are clear.
Route uncertainty to a bounded scout instead of guessing an implementation.
Present captain gates as a compact decision batch with the options, evidence, tradeoff, and recommended choice.
Record the disposition and acknowledge only the candidates the disposition actually covers.

## Closeout

After action, rerun targeted triage for the affected lane.
Run a full pass when closeout unblocks queued work or changes shared visibility history.
Resume normal supervision when no unhandled candidate remains and every unavailable lane has been accounted for.
