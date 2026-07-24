# Governed agent profiles

The model-economy program (ORD-224) defines 11 canonical, immutable,
schema-versioned agent profiles. This slice (S3) commits their definitions;
nothing dispatches through them yet — the dispatch schema (S4) and the
anti-inheritance PreToolUse guard (S5) are separate, later slices.

Design authority: `data/model-economy/ord-223-report.md` §G (profile matrix),
§H (model-selection policy), §I (effort policy); coordinator adjudications B.1
#1 (committed manifest) and #15 (tracked material lands in this template repo and
reaches the runtime home via the fold/sync path).

## The artifacts

- **The manifest** — `docs/model-economy/governed-profiles.manifest.json`
  (`schema_version: firstmate/governed-profiles/v1`) is the single
  machine-authoritative source of truth for all 11 profiles: each profile's
  model, effort, description, tool list, write capability, nesting, concrete
  `maxTurns` (plus `maxTurns_bounds`), and version, and the `effort_constraints`
  tier policy. It is the ONLY authored surface; everything else is a derived
  projection of it.
- **The committed schemas** — `docs/model-economy/schemas/*.schema.json`: three
  closed (`additionalProperties:false`, total) JSON Schema documents — one for the
  manifest, one for a frontmatter object, one for a governed bindings entry.
  These are the declarative authority the validator enforces; adding a property to
  an artifact without adding it to the schema fails closed.
- **The IN-SESSION surface** — `.claude/agents/<profile>.md`, one file per
  profile, whose YAML frontmatter Claude Code loads to define the sub-agent. It is
  a **derived projection** of the manifest, not an independent authority: the
  validator derives each expected frontmatter object from the manifest and asserts
  whole-object equality.
- **The SHELL-CREW surface** — the runtime-local, gitignored
  `state/crew-profile-bindings.json`. It carries the legacy crew-dispatch
  profiles today; when it later gains governed-profile entries keyed by these 11
  names, the validator schema-checks and cross-checks them against the manifest.

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
disallow it. Concrete `maxTurns` values, their `maxTurns_bounds`, and tool lists
are calibration-pending proposals (§G / B.1 #5), not measured optimums; the
concrete value must sit inside the committed bounds.

The `model` field uses the family token (`haiku`/`sonnet`/`opus`/`fable`)
exactly as the §G frontmatter sketch specifies; the manifest is the mapping from
profile to tier. The tier policy (haiku → no effort, sonnet → fixed high, opus →
not max, fable → ≤ high) lives once in the manifest's `effort_constraints` and is
read from there by the validator — never hard-coded a second time.

## Validating the matrix

`bin/fm-profile-matrix-check.sh` fails closed on any drift. It follows the fleet
authority pattern (`data/me-s3-profiles/design-ruling.md`, precedent
`data/dj-orders-s2/design-ruling.md`): one atomic pass proves authority by
*conformance to the closed committed schemas* plus *whole-object projection
equality*, not by an enumerated ladder of hand predicates. Concretely — the
manifest JSON and every frontmatter document parse cleanly and reject duplicate
keys at any depth; the manifest conforms to its closed schema (every property
present, exactly typed via `jsonschema` which excludes `bool` from `integer`,
enum-constrained, unique, no property the schema does not admit); each frontmatter
object conforms to its closed schema and then equals the manifest projection
exactly; and any governed bindings entry is type-proven before comparison. Any
parse ambiguity, unproven/extra property, or projection divergence is
non-authoritative and fails closed.

`python3`, PyYAML, **and `jsonschema`** are all hard prerequisites — if any is
absent the validator refuses (`PROFILE_VALIDATOR_UNAVAILABLE`, exit 1) rather than
degrading. On success it prints `PROFILES_OK=<n>` and a `MATRIX_FINGERPRINT=`
(sha256 of the canonical manifest), pinnable via `--expect-fingerprint` and
recordable via `--write-sidecar` — the analogue of `fm-bindings-validate.sh`'s
provenance surface, for S4 to pin against. Each failure prints one stable
`PROFILE_*` code — see the script header for the full list.

```sh
bin/fm-profile-matrix-check.sh            # validate the committed matrix
bin/fm-profile-matrix-check.sh --bindings state/crew-profile-bindings.json
```

Coverage lives in `tests/fm-profile-matrix-check.test.sh`: one invalid fixture per
schema property, uniqueness/enum/closed-set rule, cross-property policy, and
projection field, plus the missing-engine refuse paths and the two canaries
(`M-extra-root`, `F-permissionMode-list`). The two T.2 *runtime* probes (a real
Agent-denial dispatch, a live maxTurns cutoff) require a dispatch path and real
model calls; their explicit, design-referenced deferral — coordinator-accepted,
pending captain ratification — and the ready-to-run probe procedure are in
`docs/model-economy/slice3-notes.md`. Wiring this validator into bootstrap
diagnostics and into the governed dispatch path is later-slice work
(bootstrap/S4), not part of S3.

## Maintaining this file

Keep this to what almost every future session touching the profiles needs.
Point to the manifest, the agent files, and the validator rather than restating
their contents; when a profile changes, update the manifest and the agent file
together and rerun the validator. Prefer pruning stale detail over appending.
