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

### Round 4 (q122) — three ruling-conformance gaps closed

QA round 4 accepted the architecture but found three residual gaps; all fixed:

1. **Fable `ceiling` now enforced.** `effort_constraints` declared a Fable
   `ceiling` that the executable policy ignored. The validator now derives the
   effort order from the (schema-validated) `efforts_allowed` and enforces every
   declared operator generically — `effort_present`, `fixed`, `prohibited`, **and
   `ceiling`** — so a profile whose effort exceeds its tier ceiling fails closed.
2. **The three schemas are now genuinely closed/total.** The manifest `profiles`
   object is closed to exactly the 11 governed names (`additionalProperties:false`
   + `required` all 11 via `$defs`/`$ref`), so an unauthorized twelfth profile or a
   missing one fails at the schema. The frontmatter schema expresses the two
   conditional keys declaratively (`if/then/else`): EFFORT required for every
   non-haiku model and forbidden for haiku; `disallowedTools` exactly `["Agent"]`,
   required when the Agent tool is absent and forbidden when present. The governed
   bindings entry requires `harness`/`model`/`backups`, enum-constrains `effort`
   (an empty string is rejected), and types `backups` items with `uniqueItems`; the
   bindings cross-check proves effort presence/value per tier before comparing.
3. **The provenance sidecar is written only after the full pass succeeds.**
   `--write-sidecar` now writes (via temp file + atomic rename, mirroring
   `fm-bindings-validate.sh`) only after manifest, directory, frontmatter,
   projection, and bindings all pass — a failed validation never leaves a
   valid-looking attestation.

Each gap has a one-property invalid fixture (Fable-ceiling contradiction, a
twelfth/prohibited/missing profile, empty-effort/missing-key/bad-backup bindings,
and no-sidecar-after-failure on the frontmatter, projection, and bindings failure
paths).

### Round 5 (q123) — two residues closed

1. **Backup objects are total.** The governed bindings backup schema now requires
   both `harness` and `model` (effort enum-optional), so an incomplete backup —
   e.g. `{"model":"x"}` with no harness — fails closed instead of validating.
2. **Stale-authority sidecar removed (DJ stale-audit class).** Writing the sidecar
   only on success fixed the fresh path but left a *pre-existing* sidecar standing
   after a later failed run. Now, when `--write-sidecar` is requested, any existing
   sidecar is invalidated (removed) BEFORE any validation step or engine-refusal can
   fail, and re-created only after the whole pass succeeds — remove-first /
   write-last. A failed validation therefore leaves no usable attestation even when
   one existed before. Fixtures: a backup missing `harness`; and a first valid run
   that establishes a sidecar, an artifact mutation, a re-run that must remove it,
   and a later valid run that re-establishes it.

### Round 6 (q124) — the invalidation is itself proven

The round-5 pre-validation removal suppressed its own unlink error with `|| true`,
so if the unlink was refused (read-only directory, immutable file) a stale
attestation persisted silently while the run returned failure — the same
stale-authority class one level deeper. Now the invalidation is proven: after the
removal attempt the validator checks the sidecar is actually gone, and if it
remains it refuses loudly with `PROFILE_SIDECAR_INVALIDATION_FAILED` (exit 1)
BEFORE any validation runs — it cannot guarantee no stale attestation, so cleanup
failure is itself fail-closed. Symmetrically, a successful matrix whose attestation
cannot be written is a clean `PROFILE_SIDECAR_WRITE_FAILED` refusal (no traceback,
no partial temp file), not a silent gap. Fixtures (skipped only under root, which
bypasses directory permissions): a read-only manifest dir that denies unlink of a
pre-existing sidecar, and a read-only dir that denies the fresh write.

(The full-repo behavior suite's primary-only failures QA notes are the durable
crewmate-role guard refusing spawn/teardown/merge/etc. in a crewmate worktree —
not an S3 regression, and not bypassable from here.)

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
