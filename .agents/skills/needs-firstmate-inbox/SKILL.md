---
name: needs-firstmate-inbox
description: >-
  Agent-only playbook for FirstMate's standing Needs FirstMate (NF) inbox duty.
  Load on session-start recovery, every terminal done/PR-ready wake, AFK exit flush, and heartbeat when any terminal meta remains.
  Classifies unfinished closeouts, packages captain-gated land/merge batches under yolo=off, and forbids re-arming silent supervision with an unaddressed actionable NF queue.
user-invocable: false
metadata:
  internal: true
---

# needs-firstmate-inbox

Standing duty: unfinished terminal work must not go quiet.

If `state/<id>.meta` still exists and the last status line is captain-relevant (`done:`, `needs-decision:`, `blocked:`, `failed:`, `PR ready`, `checks green`, `ready in branch`, `merged`), closeout is incomplete.
Notification via seen-markers is not closeout.
Board "Needs FirstMate" is a projection, not the work queue; `state/*.meta` + last status + backlog notes are source of truth.

## When to load

- Session-start recovery (AGENTS §5 step 9)
- Any terminal `done` / `blocked` / `failed` / `needs-decision` / `PR ready` / `checks green` / `ready in branch` signal
- AFK exit flush (captain returned)
- Heartbeat fleet review when any terminal meta remains

Prefer `bin/fm-needs-firstmate-reconcile.sh --digest` (full) or `--id <task>` (wake path).
When the script is absent (older home), scan last status lines of every `state/*.meta` with `fm-classify-lib.sh` captain-relevant tests and classify with the table below.

## Standing rule

**Do not re-arm supervision with an actionable NF queue left unaddressed** (no captain package and no policy-allowed self-action).
Empty (`NEEDS_FIRSTMATE: none`) is healthy - do not invent work.
Presentation is mandatory; landing is gated by yolo and captain word.

## Classification table

| class | Detection | yolo=off next | Captain gate? |
| --- | --- | --- | --- |
| `ready_to_land_local` | ship + local-only + `done: ready in branch` (no serving configured) | `fm-review-diff`, package FF land via `fm-merge-local` | **Yes** (merge) |
| `ready_to_land_serving` | same + `FM_SERVING_WORKTREE` / serving git dir set | review + serving FF plan (see Serving-land) | **Yes** (merge) + later clear |
| `pr_ready` | `done: PR … checks green` or equivalent | `fm-pr-check` if needed; present full URL | **Yes** (merge) unless yolo=on |
| `pr_open_unchecked` | PR URL present, checks not green | wait / report red | No land |
| `scout_report` | kind=scout + `done:` + `data/<id>/report.md` | read report, relay findings, teardown | No (unless product call needed) |
| `needs_decision` | last `needs-decision:` | relay options | **Yes** |
| `blocked` / `failed` | those verbs | triage; steer or fail with evidence | Maybe |
| `already_live` | tip ancestor of serving/default HEAD | package clearout | **Yes** if force |
| `superseded` | SUPERSEDED / replaced-by in backlog or status | package clearout; never land | **Yes** if force |
| `hold_fold` | HOLD / quiet-window / fold notes | schedule; do not land casually | **Yes** for fold window |
| `unclassifiable` | terminal but rules miss | peek + escalate | Maybe |

yolo=on lets firstmate perform allowed merges after review, still never red PRs, and still escalates destructive / irreversible / security-sensitive actions.
yolo=off never land/merge without the captain's explicit word.

## Action matrix (summary)

| Action | yolo=off | yolo=on | AFK daemon alone |
| --- | --- | --- | --- |
| Enumerate / classify / review diff | Yes | Yes | No |
| Relay scout report | Yes | Yes | No |
| Present land/merge package | Yes (required) | Optional FYI if self-merged | N/A |
| `fm-merge-local` / serving FF | **Captain word** | FirstMate may | **Never** |
| `fm-pr-merge` green PR | **Captain word** | FirstMate may + FYI | **Never** |
| `fm-teardown` after true landed | Yes if checks pass | Yes | Never |
| `fm-teardown --force` | **Captain discard-OK** | Still escalate | Never |

## Review commands

```sh
bin/fm-needs-firstmate-reconcile.sh --digest
bin/fm-needs-firstmate-reconcile.sh --id <task>
bin/fm-review-diff.sh <id>          # ship branch vs authoritative base
# scout:
#   read data/<id>/report.md then bin/fm-teardown.sh <id>
# PR-ready:
#   bin/fm-pr-check.sh <id> <full PR URL>
```

Do not trust board branch labels; treehouse slots get reused.
Prefer tip from status `@ <sha>`, then worktree HEAD, then branch against serving common dir.

## Captain package template (yolo=off)

When reconcile produces captain_gated items, surface **one** batched ask:

```text
Ready for your approval (N items):

1) Land (local or serving), order:
   - <id> @ <tip> (notes…)

2) Clear without land (superseded / already live):
   - <id> → reason

3) Hold (need your quiet window):
   - <id>

Reply: land batch / land only <id> / hold all / discard <id> …
```

Speak in outcomes to the captain (section 9 etiquette), not watcher/meta vocabulary.
Keep packaging in the next session-start digest until closed.

After explicit "land it" / "merge it", execute the mode-appropriate path, then closeout (teardown when landed, backlog Done).
Without that word, **stop at package** - but do not treat the queue as optional.

## Serving-land notes

Cockpit / serving-branch homes may land with a fast-forward into a serving worktree rather than stock `fm-merge-local` into default.
Until stock serving-land tooling ships, follow fleet-local procedure in `data/learnings.md` (serving-land + teardown gap).
`fm-teardown.sh` landed checks use remote / PR head / **default branch** content, not an arbitrary serving branch - so serving land may still need captain-gated clearout if default does not contain the work.
Never `--force` teardown without captain discard-OK.

## AFK

Away mode never expands approval authority.
Daemon escalates captain-relevant signals once; seen-markers stop re-injection, not inbox obligation.
On AFK exit flush and every FirstMate process turn for NF ids: full reconcile, package under yolo=off, never daemon auto-merge.
Do not clear `.subsuper-seen-status-*` on every reconcile (re-escalation storm).

## What not to do

- Auto-merge under yolo=off
- Re-arm silent supervision with open NF and no package / no allowed self-action
- Trust board branch labels over meta + git tips
- Force-teardown unlanded unique commits without captain discard-OK
- Invent work when `NEEDS_FIRSTMATE: none`
- Make Bridge API a hard dependency
