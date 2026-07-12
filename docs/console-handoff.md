# FirstMate console hand-off contract

`bin/fm-console.sh` boots the FirstMate console the captain drives from the cockpit Helm.
A context hand-off lets a fresh console inherit every in-flight workstream from the outgoing one by reading a brief at `state/fm-handoff.md`.
This document owns the contract that decides when that brief is inherited.

## The rule

A brief is inherited only against a fresh, unconsumed handoff request token.
Mere existence of `state/fm-handoff.md` on disk is not a hand-off.

Before this contract existed, `fm-console.sh` seeded from the brief whenever the file existed.
Every crash relaunch and every manual `bin/fm-console.sh` run therefore booted as if the captain had just requested a hand-off, and the new console adopted superseded status as the current state of the world.
That reproduced twice on 2026-07-11 (08:20, and again at ~17:51 after a fleet-bridge restart killed the console), each time replaying a brief written the previous evening.

## The token

The cockpit hand-off flow writes `state/fm-handoff.request.json` when the captain requests a hand-off:

```json
{"requestedAtMs": 1783804768000, "requestedAt": "2026-07-11T21:19:28.000Z"}
```

An optional `id` field is honored when present; otherwise the id is derived as `h-<requestedAtMs>`.

A request is *ready* when the brief's mtime is at least the request timestamp, meaning the outgoing console wrote the brief in response to this request.
This is the same readiness math the cockpit's `firstmateHandoffStatus()` reports, computed here at second granularity with a one-second tolerance.

## What a console start does

| Situation | Seed | Token |
| --- | --- | --- |
| `FM_CONSOLE_SEED` set and the file exists | that file | untouched (deliberate caller override) |
| `FM_CONSOLE_SEED` set and the file is absent | none | untouched (the cockpit's forced clean boot) |
| Request pending and brief ready | `state/fm-handoff.md` | claimed and archived |
| Request pending, brief missing or older | none | left pending, so the hand-off can still complete |
| No request (stale brief, crash relaunch, manual start) | none | n/a |

The token is claimed by renaming `state/fm-handoff.request.json` into the evidence directory.
The rename is atomic and can succeed exactly once, so a concurrent start, a later crash relaunch, or a manual run can never re-seed from the same request.
The claim happens only after model selection succeeds, at the point the launch is committed, so a refused launch never burns a genuine pending hand-off.

## Lifecycle evidence

`state/handoff/events.jsonl` is an append-only record, one JSON object per line, of every seeding decision:

```json
{"event":"consumed","id":"h-1783804768000","at":"2026-07-11T21:20:03Z","atMs":1783804803000,"reason":"request-claimed","brief":"...","request":"..."}
```

`event` is `consumed`, `seeded`, or `skipped`; `reason` is the deciding condition (`request-claimed`, `stale-brief-no-request`, `brief-missing`, `brief-older-than-request`, `claim-lost`, `explicit-seed`, `explicit-seed-absent`).
The claimed request and the brief it seeded are archived at `state/handoff/<id>/request.json` and `state/handoff/<id>/brief.md`.

This exists so a future dispute about "was this a real hand-off" is settled from records rather than inference.
Writing evidence is best-effort and can never fail a console launch.

## Cockpit-side counterpart

The firstmate half needs no fleet-bridge change to be correct: fleet-bridge's respawn route runs `fm-console.sh` while the request file is still present, and its later `clearFirstmateHandoffRequest()` becomes a harmless no-op once the console has claimed the token.
Two optional cockpit improvements would complete the picture:

- Write an explicit `id` into the request JSON and append `requested` and `cancelled` events to `state/handoff/events.jsonl`, so the full request/ready/complete/cancel lifecycle lives in one record.
- Drop the `FM_CONSOLE_SEED` no-seed-path workaround for the pending-not-ready case, which is now redundant.
