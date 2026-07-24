# Slice 3 — Governed profile definitions (ORD-271 / ORD-224)

Tracked-material slice landed in the firstmate template repo (design decision
B.1 #15); the runtime home picks it up via the fold/sync path. Design authority:
`data/model-economy/ord-223-report.md` §G (profile matrix), §H (model-selection
policy), §I (effort policy), §T.2 (test group), §U/S3 (slice entry).

## What landed

- `docs/model-economy/governed-profiles.manifest.json` — the single
  machine-authoritative source of truth (`schema_version:
  firstmate/governed-profiles/v1`) for all 11 profiles; carries concrete
  `maxTurns` + `maxTurns_bounds`, per-profile `description`, and the
  `effort_constraints` tier policy.
- `docs/model-economy/schemas/*.schema.json` (3) — closed JSON Schemas (manifest,
  frontmatter object, governed bindings entry): the declarative authority.
- `.claude/agents/*.md` (11) — the IN-SESSION projection of the manifest; each
  carries `profile_version: 1`.
- `bin/fm-profile-matrix-check.sh` — the fail-closed schema-and-projection
  validator, with the `MATRIX_FINGERPRINT` provenance surface.
- `tests/fm-profile-matrix-check.test.sh` — one invalid fixture per schema
  property, policy rule, and projection field, plus the missing-engine paths.
- `docs/model-economy/governed-profiles.md` — the pointer doc.

Additive only: no dispatch is routed through the profiles yet (that is S4/S5).

## Fail-closed validation — the authority pattern (q119 → q120 → q121 — RESOLVED)

Three QA rounds each found a different symptom on the same broken spine: r1
(q119) did not parse the format; r2 (q120) parsed but only proved enumerated
fields; r3 (q121) parsed with a hard-tool prerequisite yet still false-passed on
un-enumerated properties (unknown root keys, wrong root types, `bool`-as-integer,
a bindings `model` given as a list). The senior ruling
(`data/me-s3-profiles/design-ruling.md`, precedent
`data/dj-orders-s2/design-ruling.md`) diagnosed the root cause: **authority was an
enumerated conjunction of hand predicates, not conformance to a closed schema.**
Round 3's fix implements the ruling's section (e) exactly:

- **Three committed closed JSON Schemas** (`docs/model-economy/schemas/`), one
  each for the manifest, a frontmatter object, and a governed bindings entry —
  `additionalProperties:false`, full `required`, exact `type`, `enum`,
  `uniqueItems`. Adding a property to an artifact without adding it to the schema
  fails closed; the schema is the enumeration, not a `die()` ladder.
- **Parse → duplicate-reject → jsonschema.** Each artifact is parsed once
  (JSON `object_pairs_hook` / YAML `StrictLoader` reject duplicate keys at any
  depth), then validated against its committed schema via `jsonschema`
  (Draft 2020-12), which excludes `bool` from `integer`/`number` by construction —
  closing the `profile_version: true` and mistyped-manifest holes.
- **`jsonschema` joins `python3`+PyYAML as a hard prerequisite.** If any engine
  (or a committed schema file) is absent the validator refuses with
  `PROFILE_VALIDATOR_UNAVAILABLE`, exit 1 — no degradation, no warn-and-pass.
- **The frontmatter is a derived projection, asserted by whole-object equality.**
  The manifest gained concrete `maxTurns` and per-profile `description` so the
  expected frontmatter object is fully manifest-derived; the validator asserts
  dict-equality, so any divergence on any key (enumerated or not) fails.
- **Tier policy from one source.** `effort_constraints` is schema-validated and is
  the only source of the executable tier rules; a null or contradicting policy
  fails closed.
- **Bindings type-before-compare.** A governed bindings entry is schema-checked
  (`model` must be a string) before any comparison, closing the list-membership
  bug.
- **Provenance.** On success the validator emits `MATRIX_FINGERPRINT=<sha256>`
  over the canonical manifest, pinnable via `--expect-fingerprint` and recordable
  via `--write-sidecar` — mirroring `bin/fm-bindings-validate.sh` for S4 to pin
  against.

The two canaries the ruling named — `M-extra-root` (an unknown manifest root key)
and `F-permissionMode-list` (permissionMode as a list) — were written first,
confirmed to false-pass on `d043626`, and now reject. Every schema property,
uniqueness/enum/closed-set rule, cross-property policy, and projection field has a
one-property-at-a-time invalid fixture, alongside the missing-engine refuse paths
and the retained r1/r2 regression cases.

## T.2 runtime probes — EXPLICIT deferral (QA qa-me-s3-q119 finding 2)

§T.2 lists two RUNTIME probes in its "Runtime probe (harmless)" column, and
§U/S3 binds "T.2 (profile definitions group) in full" (`ord-223-report.md:1584`):

1. **Agent-tool denial** — "a real dispatch on a non-nesting profile attempting
   to call Agent → tool-not-available error, observed once per profile family"
   (`ord-223-report.md:1435`).
2. **maxTurns cutoff** — "dispatch a deliberately long-running haiku-evidence
   task and confirm it is cut off at its `maxTurns`" (`ord-223-report.md:1437`).

**These two probes are deferred from this landing, deliberately and on the
record — not silently dropped.** Rationale:

- Both are **live-harness behavior observations**: they verify that the *harness*
  enforces the committed frontmatter (tool availability, turn ceiling), not that
  the S3 artifacts are internally correct. The artifact correctness that S3 is
  responsible for — the matrix content, tool/effort/nesting/maxTurns/version
  agreement across the manifest and all 11 files, and the prohibited-name and
  fail-closed-parsing invariants — is covered in full by the static suite.
- Each probe requires an **actual dispatch path and real model calls**. A "real
  dispatch" and "a run cut off at maxTurns" both presuppose the ability to route
  work *through* a profile, which is exactly the capability the later slices add:
  S4 (the governed dispatch schema/validator) and S5 (the PreToolUse guard).
  Running them belongs where a dispatch path exists.
- They are **non-deterministic and cost-bearing**, so they cannot join the
  always-on `tests/*.test.sh` CI loop (which runs offline, deterministically, and
  free). §T.2 itself frames them as "observed once per profile family," i.e. a
  one-time observation, not a repeatable unit test.
- Live sub-agent dispatch is additionally constrained under the active KrakenLoop
  maintenance mode in force during this slice.

### Deferral status: COORDINATOR-ACCEPTED, pending captain ratification

The senior design ruling (`data/me-s3-profiles/design-ruling.md` §5(d)9, §7 "Out
of scope by the slice") accepts this deferral: "the two §T.2 live-harness runtime
probes remain deferred pending explicit acceptance amendment … that deferral is a
coordinator/captain ratification item, not a thing to silently satisfy or silently
drop here." So the coordinator has accepted the deferral; the remaining step is the
captain's ratification of the acceptance amendment below.

**Acceptance amendment (awaiting captain ratification):** move the two §T.2
runtime probes to the S4/S5 slices that introduce the dispatch path they exercise,
keeping S3's binding acceptance to the T.2 STATIC rules (all implemented here).
This note is the explicit, design-referenced record until the captain ratifies.

### Ready-to-run probe procedure (run once, on demand, to capture evidence)

Run from a firstmate home whose `.claude/agents/` carries these profiles, with a
live Claude Code harness. These are harmless (Haiku-cheap) one-shot observations;
record the exact-SHA evidence alongside this note when performed.

1. Agent-tool denial (per non-nesting family — haiku, sonnet, opus):

   ```sh
   # Dispatch a non-nesting profile and instruct it to invoke the Agent tool.
   # Expected: the harness reports the Agent tool is unavailable for that agent
   # type (frontmatter tools/ disallowedTools honored), and no sub-agent spawns.
   claude -p 'Use the Agent tool to spawn a helper.' --agents haiku-evidence
   ```

2. maxTurns cutoff (haiku-evidence, maxTurns 8):

   ```sh
   # Dispatch a deliberately long, multi-step read-only task and confirm the run
   # halts at the profile's maxTurns rather than running unbounded.
   claude -p 'Inspect the repo across many separate steps; keep going.' --agents haiku-evidence
   ```

   (Exact invocation flags depend on the resolved harness adapter; the observable
   assertion is: the run stops at the profile's committed `maxTurns`.)
