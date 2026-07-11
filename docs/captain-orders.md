# Captain Order Inbox

The durable record of every captain request.
A captain request may never exist only in chat history, a transcript, a narrative reply, or firstmate's working memory: it is recorded here before firstmate does substantive work on it.
The captain must be able to fire several requests in a row without waiting for any of them to be analyzed, and trust that every one was captured.

Intake is unbounded; execution is not.
Recording ten orders does not mean starting ten crews - it means nothing was lost while firstmate decided which one to start.

`AGENTS.md` section 15 owns the operating rules.
`bin/fm-order.sh` and `bin/fm-order-lib.sh` own the mechanics (verbs, flags, path resolution, locking).
This document is the reference: schema, storage, wire formats, and the hook install.

## Storage

The inbox is an append-only JSONL event ledger, folded at read into one current record per order.
It does not live in the repo.

`data/` is gitignored state inside a git checkout, so its lifetime is tied to that checkout: `git clean -xfd`, a re-clone, a worktree teardown, or a relocation takes it along.
Captain orders are durable operational state and must survive all of those, so the inbox defaults outside any checkout:

```
${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/<home-tag>/captain-orders.jsonl
```

`<home-tag>` comes from `bin/fm-backend-hometag-lib.sh` - the repo's existing per-installation discriminator (a readable prefix plus a short hash of the home path).
A primary, each of its secondmates, and a second primary on the same machine therefore each get their own inbox and can never write into each other's.

Resolution order, highest first:

1. `FM_ORDERS_PATH` - an explicit absolute path.
2. `config/orders-path` - a local, gitignored pointer file in the home holding one path (a leading `~/` is expanded).
3. The default above.

Only the pointer is configurable.
The data never lives in the repo.

Siblings of the inbox, in the same directory:

| Path | What it holds |
| --- | --- |
| `captain-orders.jsonl` | the authoritative append-only order ledger |
| `captain-orders.jsonl.lock` | the writer lock (an atomic `mkdir` holding the writer's pid) |
| `pending/` | captain chat messages captured but not yet drained |
| `captain-chat-dismissed.jsonl` | captures firstmate judged were not requests, each with a recorded reason |

## Failure is visible, never silent

A read of a **missing** inbox fails loudly (`bin/fm-order.sh list` exits 3) instead of folding to zero orders.
A silently empty inbox and a genuinely empty one look identical to a reader, and only one of them means no captain is waiting.
Creating one is deliberate: `bin/fm-order.sh init`.

A **malformed row** is skipped by the fold rather than crashing it, but it is counted, referenced by line, excerpted, and surfaced by `bin/fm-order.sh health`, the duty banner, and the fleet-triage digest.
A corrupt `received` row loses a captain request verbatim, which is the one thing this system exists to keep; a skip with no trace could never be repaired.

An intake **write failure** exits non-zero, names which requests were recorded and which were not, and explicitly says not to acknowledge the lost ones.
Every append is read back and re-parsed before a single word of success is printed.
A false "recorded" is worse than a visible failure.

## Record schema (`firstmate/captain-order/v1`)

Each event row carries `schema`, `order_id`, `event`, `ts`, and only the fields it means to set.
The fold accumulates them, latest wins, and an explicit `null` is an update (which is how `release` clears an owner).
`duplicate_delivery` is the one event that does not merge: it only counts itself and files its evidence, so a re-delivery can never overwrite the order it duplicates.

The folded record:

```json
{
  "schema_version": "firstmate/captain-order/v1",
  "order_id": "ORD-104",
  "received_at": "2026-07-11T18:02:11Z",
  "source": "chat",
  "source_message_id": null,
  "idempotency_key": "cap-9f13c2a0b7d1",
  "original_request": "Fix the bug history mismatch.",
  "short_title": "Bug history mismatch",
  "project_or_ship": "fleet-bridge",
  "priority": "urgent",
  "priority_source": "captain_explicit",
  "status": "dispatched",
  "owner": "crew-bug-history-k3",
  "related_order_ids": [],
  "dependency_ids": [],
  "linked_task_ids": ["bug-history-k3"],
  "linked_scout_ids": [],
  "linked_bug_ids": ["BUG-31"],
  "hold_reason": null,
  "review_after": null,
  "captain_decision_required": false,
  "outcome_type": null,
  "outcome_link": null,
  "outcome_reason": null,
  "updated_at": "2026-07-11T18:09:40Z"
}
```

The captain's `original_request` is preserved verbatim forever.
A `short_title` is a convenience, never a replacement.

### Statuses

`received`, `triaging`, `queued`, `dispatched`, `blocked`, `held`, `needs_clarification`, `captain_decision`, `completed`, `superseded`, `rejected`.

There is deliberately no `acknowledged` status.
An acknowledgment means only that the durable record exists; it is not an outcome, and an order that was merely seen is still waiting.

### Lineage contract

`bin/fm-order-lib.sh`'s `fm_order_status_requires` is the one owner of this table, and `bin/fm-order.sh` refuses any write that violates it:

| Status | Requires |
| --- | --- |
| `dispatched` | a linked task, scout, or bug |
| `completed`, `superseded` | `--link` naming the evidence or the superseding order |
| `rejected` | `--reason` |
| `blocked`, `needs_clarification`, `captain_decision` | `--reason` |
| `held` | `--reason` and `--review-after` (a date, or an explicit unblock condition) |

A hold whose `--review-after` is a date or timestamp expires on its own and re-surfaces.
One phrased as an English condition never expires by itself, which is exactly why a hold also carries a reason a human can act on.

### Idempotency

The idempotency key is an explicit key when the caller has one (a chat capture's id, a bridge submission id), otherwise a hash of the source plus the whitespace-normalized request text.
The same request delivered twice - a repeated chat ingestion, a retry after a timeout, a watcher restart, a manual resubmission - resolves to the same key and therefore to the same order.
The second delivery is recorded as a `duplicate_delivery` event on the existing order, preserving the new arrival as evidence.
It never mints a second order, and it never merges two genuinely separate requests.

## Chat capture and the mandatory drain

A chat request cannot be recorded until firstmate takes a turn, so the operating rule - drain new captain requests into the inbox before any other work - is the primary guarantee.
An instruction alone is not a mechanism, so the runtime closes the gap on both sides:

- **Before the turn:** `bin/fm-order-capture-hook.sh` runs at prompt submission and spools the captain's words verbatim to `pending/`. From that moment the message exists on disk whether or not firstmate ever reasons about it. The capture id is a hash of the text, so a replayed prompt does not spool twice.
- **After the turn, until it is handled:** `bin/fm-order-duty.sh` prints a bordered banner on stderr - at every wake drain, at every supervision arm, and in the session-start digest - naming undrained captures, orders still needing action, and a corrupt inbox. It is read-only, non-blocking, and silent when the inbox is clear.

A capture is not an order.
A chat turn may be a request, a reply, an approval, or small talk, and only firstmate can tell which.
The drain records the real requests (`fm-order.sh add --from-pending <capture-id>`) and dismisses the rest with a recorded reason (`fm-order.sh dismiss <capture-id> --reason ...`).
There is no silent drop: a dismissal is a durable row with a reason.

### Installing the capture hook (Claude Code)

Add to the primary's settings (`~/.claude/settings.json`), pointing at this repo's `bin/`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "/path/to/firstmate/bin/fm-order-capture-hook.sh" }
        ]
      }
    ]
  }
}
```

The hook reads the harness payload on stdin, takes the prompt from `prompt`/`user_prompt`/`message`/`text`, and exits 0 unconditionally.
Any harness that can run a command on prompt submit works the same way.
A harness that cannot falls back to the operating rule alone, which is why the hook never blocks and never fails a prompt.

## Fleet Triage integration

Captain orders are an input **lane** of the existing Fleet Triage Control Loop, not a second orchestration system.
`bin/fm-fleet-triage.sh` reads the inbox through its sanctioned reader (`fm-order.sh list --json`) and surfaces the orders that still need firstmate:

| Reason | What it means |
| --- | --- |
| `untriaged` | received or triaging, not yet classified |
| `missing_lineage` | a status that requires a link or a reason is carrying neither |
| `blocker_cleared` | every order it depended on has finished |
| `hold_expired` | a hold's review date has arrived |
| `successor_missing` | its linked task, scout, or bug no longer exists in the fleet |
| `ownerless` | dispatched work with nobody on it |
| `stale` | unfinished and older than `FM_ORDER_STALE_SECS` (default 24h) |

`successor_missing` is computed by the enumerator rather than the inbox, because only the enumerator knows which ids the fleet still has.
An order whose `captain_decision_required` is set is a `CAPTAIN_GATE` item.

The inbox stays authoritative for order content and status; triage references and audits it and never writes an order.
Dispositions recorded against an order item use the existing triage ledger (`bin/fm-fleet-triage-record.sh surface|claim|successor|... captain_orders:ORD-001`), so there is no second processing ledger.

An inbox that exists and cannot be read is reported as an **unavailable lane with the reason**, never as zero orders.

## Concurrency

The order writer is deliberately **not** the session-lock holder: the captain must be able to record an order from any shell, with no firstmate turn and no live session.
Writes therefore serialize on the dedicated writer lock beside the inbox, which is what stops two concurrent writers from minting the same id or losing an update.
Reads take no lock.

A lock held by a live writer refuses the write loudly and records nothing.
A lock whose holder is gone is broken and reclaimed, so a killed writer can never wedge intake.

Order claims are visible across every process sharing a home, because they are rows in the same file: `fm-order.sh claim <id> --owner <who>` is what two co-inhabiting manager processes read to see that an order is already being worked.
Claims are **not** shared across homes, by design - each home has its own inbox, and a secondmate receives work routed to it by the primary rather than taking captain orders directly.

## Metrics

`bin/fm-order.sh metrics` reports totals, untriaged count and oldest untriaged age, ownerless, queued, dispatched, blocked, held, clarification, captain-decision, completed, rejected, superseded, duplicate deliveries, and undrained chat captures.
The fleet-triage digest carries the same block verbatim from the inbox rather than recomputing it.

`pending_chat_captures` is the honest proxy for "requests that exist only in chat": every capture the runtime saw and firstmate has not yet dealt with.
Its resting value is zero.
