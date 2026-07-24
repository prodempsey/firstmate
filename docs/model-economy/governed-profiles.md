# Governed agent profiles

The model-economy program (ORD-224) defines 11 canonical, immutable,
schema-versioned agent profiles. This slice (S3) commits their definitions;
nothing dispatches through them yet — the dispatch schema (S4) and the
anti-inheritance PreToolUse guard (S5) are separate, later slices.

Design authority: `data/model-economy/ord-223-report.md` §G (profile matrix),
§H (model-selection policy), §I (effort policy); coordinator adjudications B.1
#1 (committed manifest) and #15 (tracked material lands in this template repo and
reaches the runtime home via the fold/sync path).

## The three artifacts

- **The manifest** — `docs/model-economy/governed-profiles.manifest.json`
  (`schema_version: firstmate/governed-profiles/v1`) is the single committed
  source of truth for all 11 profiles: each profile's model, effort, tool list,
  write capability, nesting, `maxTurns` range, and version. Do not maintain the
  matrix independently in two places; edit this manifest and the matching agent
  file together, then run the validator.
- **The IN-SESSION surface** — `.claude/agents/<profile>.md`, one file per
  profile, whose YAML frontmatter is the actual runtime definition Claude Code
  loads. Each file carries `profile_version`.
- **The SHELL-CREW surface** — the runtime-local, gitignored
  `state/crew-profile-bindings.json`. It carries the legacy crew-dispatch
  profiles today; when it later gains governed-profile entries keyed by these 11
  names, the validator cross-checks their model/effort against the manifest too.

## The 11 profiles

| Profile | Model | Effort | Writes | Nesting |
|---|---|---|---|---|
| `haiku-evidence` | haiku | (none) | no | no |
| `haiku-log-compressor` | haiku | (none) | no | no |
| `sonnet-high-engineer` | sonnet | high | yes | no |
| `sonnet-high-reviewer` | sonnet | high | no | no |
| `opus-low` | opus | low | no | no |
| `opus-medium` | opus | medium | yes | no |
| `opus-high` | opus | high | yes | no |
| `opus-xhigh` | opus | xhigh | yes | no |
| `fable-low` | fable | low | no | yes (restricted) |
| `fable-medium` | fable | medium | no | yes (restricted) |
| `fable-high` | fable | high | no | yes (restricted) |

Pinned invariants enforced by the validator: Haiku profiles carry **no** effort
key (Haiku rejects the parameter at the API); Sonnet profiles are fixed at
`high`; `opus-max`, `fable-xhigh`, and `fable-max` are prohibited and no such
profile file may exist; non-nesting profiles both exclude `Agent` from `tools`
and list it in `disallowedTools`; fable profiles include `Agent` and never
disallow it. `maxTurns` values and tool lists are calibration-pending proposals
(§G / B.1 #5), not measured optimums — the range in the manifest is the
committed envelope.

The `model` field uses the family token (`haiku`/`sonnet`/`opus`/`fable`)
exactly as the §G frontmatter sketch specifies; the manifest is the mapping from
profile to tier.

## Validating the matrix

`bin/fm-profile-matrix-check.sh` fails closed on any drift between the manifest
and the `.claude/agents/*.md` files (and, when given `--bindings`, the
SHELL-CREW file). Each failure prints one stable `PROFILE_*` code — see the
script header for the full list. Run it after any profile change:

```sh
bin/fm-profile-matrix-check.sh            # validate the committed matrix
bin/fm-profile-matrix-check.sh --bindings state/crew-profile-bindings.json
```

Coverage lives in `tests/fm-profile-matrix-check.test.sh` (the T.2 static rules
in full, plus fail-closed parsing of malformed/duplicate keys). The two T.2
*runtime* probes (a real Agent-denial dispatch, a live maxTurns cutoff) require a
dispatch path and real model calls; their explicit, design-referenced deferral
and the ready-to-run probe procedure are recorded in
`docs/model-economy/slice3-notes.md`. Wiring this validator into bootstrap
diagnostics and into the governed dispatch path is later-slice work
(bootstrap/S4), not part of S3.

## Maintaining this file

Keep this to what almost every future session touching the profiles needs.
Point to the manifest, the agent files, and the validator rather than restating
their contents; when a profile changes, update the manifest and the agent file
together and rerun the validator. Prefer pruning stale detail over appending.
