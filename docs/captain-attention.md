# Captain attention

Why `AGENTS.md` section 9 requires every captain decision to be marked on the board before it is asked for in chat, and how that marking works.

## The incident (2026-07-12 / 2026-07-13)

Over two days firstmate escalated five captain decisions - a cockpit restart, a canonical-lineage Option A/B choice, baseline-versus-backfill, a dirty-orphan salvage, and a GH007 email-privacy block - entirely in chat prose.

Evidence at the time:

- The board's `needs_human` column was empty.
- `bin/fm-nf-ack.sh --to-captain`, the sole writer of that column, had been invoked zero times since it was added.
- The captain reported: "I'm finding it increasingly difficult to track what needs me, and it gets buried in the FirstMate's text and I may be missing things that need my attention."

The column was not broken.
Nothing had ever been routed to it.

## Why this was an instruction defect, not a discipline lapse

`AGENTS.md` section 9's "Reaches the captain immediately" list enumerated what to *say* to the captain: work ready for review, findings, blockers, destructive actions, needed credentials.
Not one item told firstmate to make the decision *visible* anywhere but chat.
Firstmate followed its written instructions correctly and the captain still lost track of what needed him.
An instruction surface that can be followed correctly and still produce the failure is the defect.

The fix is stated as doctrine in section 9 rather than as a mechanism, because the failure was not a missing command - the command existed - but a missing rule about when the command is owed.

## Mechanism

Two durable homes carry captain attention, chosen by whether the decision has a task card on the board.

- A decision arising from a task: `bin/fm-nf-ack.sh --to-captain <open-item-id> <task-id>`.
  The task must be showing a terminal signal (`done:`, `blocked:`, `failed:`, or `needs-decision:`), which is the state a crew-originated decision reaches firstmate in.
  The script posts the `to_captain` attention event for the card and reads it back before reporting success, so a failed write leaves the item open rather than silently swallowed.
  `lib/fleet.js` in the Fleet Bridge places a card with that event into the `needs_human` column.
  The exact flags and guards are owned by the script's header and `--help`.
- A decision with no task card - firstmate's own judgment call, an infrastructure choice, a policy question: a captain-gated backlog item (`tasks-axi hold <id> --kind captain`, `AGENTS.md` section 10) or a captain order in the inbox (`AGENTS.md` section 15, `docs/captain-orders.md`).

Marking is not a substitute for the chat message; it is the prerequisite for it.
Chat explains the decision, its options, the evidence, and the recommendation.
The board is what the captain scans to find out that a decision exists at all.
