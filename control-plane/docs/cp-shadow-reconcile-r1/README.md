# cp shadow-reconcile (ORD-257)

A narrow, sanctioned administrative verb for reconciling **documented pre-shadow-enable
divergence** during the CW2+ shadow window.

## The problem it solves

Eight production rows (`qa-cw2-q87`, `qa-cw2r2-q88`, `qa-cw2r3-q89`, `qa-cw2r4-q90`,
`qa-cw3-q91`, `qa-cw3r2-q92`, `cutover-w2`, `cutover-w3`) have a legacy-derived expected
terminal status of `completed`, but their store rows read `failed` — the result of the
reconciler's spawn-timeout close of a synthetic generation-1 run. `cp shadow-diff` reports
each as `mismatched`. The S3 identity-binding guard correctly refuses hand-authored
completions (`record-spawn` requires a real launch registration), so there is no normal
`complete` path: `complete` is legal only from `{running, waiting_firstmate}` over an open
run, and forging a run would be the anti-ghost violation CW1/CW2 forbid.

## What the verb does

```
cp shadow-reconcile --ledger <path> --data-dir <path> --out <path> --captain-approved [--task <id>]
```

Reads a captain-approved reconcile ledger (`control-plane/shadow-reconcile/ledger/v1`) that
names each `task_id`, its expected terminal status, and evidence (source refs into the legacy
home). For each entry it advances **only the task row's** `status` through the sanctioned
domain command envelope (`executeCommand`) — fabricating no run, event, or launch binding. The
junk generation-1 run history is left byte-untouched (not deleted): the closed `failed` run
and its `failed` terminal event remain; only `tasks.status` moves to the expected terminal.

The reconcile is recorded two ways: a `reconcile_terminals` marker row (producer `reconciler`,
from/to status, ledger digest) and an audit annotation per row in the shared
`shadow_annotations` table carrying the ledger digest. `cp shadow-diff` then counts the row as
matching, because it compares `tasks.status` directly (no shadow-diff change was needed).

## Gates (each refuses loudly, before any store write)

- `--captain-approved` is **required** as an explicit bare flag (fail-closed consent).
- the ledger must exist, be valid JSON, carry the v1 schema, and name well-formed entries
  (task_id, terminal `expected_status` ∈ {completed, failed}, `evidence.source_refs[]`).
- a `--task <id>` not named in the ledger is refused (the ledger is the allowlist).
- the shadow window must be open (the target store must show shadow-mode activity — the
  `shadow_annotations` table present); a store the shadow writer never touched is refused.
- a row already at its expected terminal is recorded `already_matched`, never rewritten.

Idempotent: each entry's command is keyed by a deterministic command-id derived from the
ledger digest and task id, so a re-run replays and changes nothing.

## The proposed ledger

`reconcile-ledger.json` in this directory is the **proposed, UNAPPROVED** ledger for the eight
production rows. firstmate/captain must review the evidence `source_refs` against the legacy
home, then place and approve it before running the verb against the real store. Do **not** run
it against `/home/prode/fleet/control-plane/pgdata` without that approval.
