# Slice 4 — Dispatch schema + validator (ORD-271 / ORD-224)

Tracked-material slice landed in the firstmate template repo (design decision
B.1 #15); the runtime home picks it up via the fold/sync path. Design authority:
`data/model-economy/ord-223-report.md` §F (dispatch request schema), §H (the
enumerated Opus-insufficiency denylist §F rule 6 defers to), §T.1 (dispatch
schema rejections), §U/S4 (slice entry); brief §6 (the must-reject list).
Depends on S3 (the profile matrix must exist for the validator to project
against). Authority pattern: `data/me-s3-profiles/design-ruling.md` (binding
precedent), precedent `data/dj-orders-s2/design-ruling.md`.

## What landed

- `docs/model-economy/schemas/governed-dispatch-request.schema.json` — the closed
  (`additionalProperties:false`, total) JSON Schema `firstmate/governed-dispatch-request/v1`.
- `docs/model-economy/governed-dispatch-policy.json` — the single authoritative
  source for the semantic data the request schema cannot enumerate declaratively
  (supported request schema id, model tier order, committed governed task-class
  taxonomy, §H insufficient-reason denylist), plus its own closed schema
  `docs/model-economy/schemas/governed-dispatch-policy.schema.json`.
- `bin/fm-dispatch-validate.sh` — the fail-closed validator the dispatch path
  consults; `python3` + `jsonschema` hard prerequisites; one stable §F denial code
  per failure; `REQUEST_FINGERPRINT` provenance surface.
- `tests/fm-dispatch-validate.test.sh` — the exhaustive fixture matrix (T.1 in
  full plus the structural closed-schema properties and the fail-closed
  engine/artifact paths).
- `docs/model-economy/governed-dispatch.md` — the pointer doc.

Additive only: no dispatch is routed through the validator yet (that binding is
S5), and the existing `fm-spawn.sh`/`fm-spawn-profile.sh` paths are untouched.

## The authority pattern, applied to a request (not a matrix)

S3's ruling closed the "authority as an enumerated conjunction of hand predicates"
class by proving conformance to a closed schema plus whole-object projection. S4
reuses that spine on a different subject — a one-shot dispatch request rather than
a pinned matrix:

- **Structure is proven by closed committed JSON Schemas**, not hand-rolled type
  predicates: the request schema, the policy schema, and (reused) the S3 manifest
  schema. `jsonschema` excludes `bool` from numeric types and enforces
  `additionalProperties:false`/`enum`/`uniqueItems` by construction, so the r3
  false-pass classes cannot recur. `python3`+`jsonschema` are hard prerequisites
  that refuse (`DISPATCH_VALIDATOR_UNAVAILABLE`) rather than degrade. (No PyYAML: a
  request is JSON.)
- **The §F cross-field rules are the permitted residue** the S3 ruling explicitly
  allows beyond declarative schema — relations *between* fields, projection
  *against* the S3 manifest, and *live-environment* agreement, none expressible in
  JSON Schema. They run only after the structural schema has type-proven every
  field, so no check compares-before-type (ruling §5.7).
- **The profile axis is projected from the single S3 source, never re-authored.**
  `requested_model`/`configured_effort`/`write_allowed`/`allowed_tools`/
  `nesting_allowed` are asserted equal to the manifest projection for
  `selected_profile`; `max_turns` is bounds-checked against the profile's
  `maxTurns_bounds` (§F "profile-bounded", not the concrete frontmatter value —
  the §F denial-2 example's `max_turns: 32` is a valid in-bounds choice). The
  manifest is loaded and schema-checked before it is trusted as a projection
  source; a malformed manifest fails closed (`DISPATCH_MANIFEST_INVALID`).
- **Denial codes are the exact §F taxonomy.** Where §F names a dedicated code
  (rules 1-13), the validator emits that code so T.1 can assert it per rule;
  purely structural violations with no §F-named rule are `DISPATCH_SCHEMA_INVALID`.

## Deliberate design decisions (§F left several to the implementer)

- **The validator is the deliverable, not a spawning dispatcher.** The slice entry
  is "the dispatch-request schema + the validator the dispatch path consults", and
  T.1 is schema rejections. Mirroring S3 (which shipped `fm-profile-matrix-check.sh`,
  a validator, not a dispatcher), S4 ships `bin/fm-dispatch-validate.sh`. The
  SHELL-CREW dispatcher entry point the report calls `fm-dispatch-governed.sh` is
  the thing that *consults* this validator and then spawns; building that spawn/
  routing surface is S5+ work and would expand S4 scope (ruling §5.9's analogue:
  do not expand the slice).
- **`configured_effort` excludes `max` from the enum (stronger than rule 2).** §F's
  field table says "`max` is never a valid member of this governed enum"; §F rule 2
  says max is caught "by construction". Excluding it from the closed enum IS that
  by-construction catch, at the earliest (structural) layer: Opus-max and Fable-max
  are `DISPATCH_SCHEMA_INVALID`. Fable-`xhigh` (a real enum member, wrong for a
  Fable profile) is caught one layer later by the effort projection
  (`PROFILE_EFFORT_MISMATCH`). Both fail closed; the split is documented in the
  test.
- **`PROFILE_IMMUTABLE_MISMATCH` and `NEXT_LOWER_MODEL_INVALID` are added codes.**
  §F's named list does not give codes for the `write_allowed`/`allowed_tools`/
  `max_turns` immutable-profile fields or for the `next_lower_model` relation, but
  §F declares them immutable-profile / required-when fields. Enforcing them is
  fail-closed-correct and the ruling explicitly permits extending the code set;
  they are the projection-equality analogue of S3's `PROFILE_PROJECTION_MISMATCH`.
- **Task-class taxonomy home.** §F says `task_class` is "one of
  `config/crew-profiles.json`'s committed task-class taxonomy, extended per §D5",
  but the report's own canonical examples use governed classes
  (`routine_investigation`, `complex_bounded_engineering`,
  `exceptional_orchestration`) not present in that file. S4 commits the governed
  taxonomy in `governed-dispatch-policy.json` (the committed `crew-profiles.json`
  classes plus the report's governed classes) so the validator is self-contained
  and the canonical examples validate. Reconciling this list *into*
  `config/crew-profiles.json` is the separate §D5 firstmate-repo change, out of S4
  scope.
- **`evidence_packet_id` — field-table vs. example conflict, reconciled.** The §F
  field table marks it required "when `selected_profile` is any `opus-*` or
  `fable-*`", but the §F valid example is `opus-high` with `evidence_packet_id:
  null`. The example is authoritative for opus; brief §7 explicitly requires an
  evidence packet for *Fable*. So S4 requires it for `fable-*`, treats it as
  optional-but-resolvable for `opus-*`, and, when a `--packets-dir` is supplied,
  requires a present id to resolve to a packet file. This is the SHALLOW form of
  §F rule 10; the DEEP §M packet-schema validation depends on the S7 evidence-
  packet validator and is deferred there (see below).
- **`runtime_state_fingerprint` format is defined here.** §F says "sha256 of
  {repository, branch, HEAD, worktree-clean-flag}" without pinning a serialization.
  S4 defines it as `sha256:` + `sha256("<repository>\n<branch>\n<HEAD>\n<clean|dirty>")`
  and the rule-9 check recomputes it from the live worktree. The schema patterns it
  `^sha256:[0-9a-f]{64}$`. (The report's illustrative `sha256:4a7e...c912` is an
  abbreviated placeholder, not a passing fixture.)
- **Environment coupling is fail-closed by default.** Rules 8 (parent linkage), 9
  (repo state), 10 (packet resolution), and 11 (captain exception) need context the
  dispatcher supplies (`--session-id`/`--state-dir`, the request's own worktree,
  `--packets-dir`, `--captain-orders`). When the context needed to *confirm* a
  claim is absent, the validator refuses rather than assume — an unverifiable
  captain exception is `CAPTAIN_EXCEPTION_INVALID`, an unresolvable parent is
  `PARENT_LINKAGE_MISSING`. Fail-closed means the dispatch path must provide the
  resolution context; it is not a soft check.
- **The §H denylist is a best-effort text screen, screened across fields.** Per §F
  rule 6 / §H's own automation caveat, the denylist catches the laziest violations
  only; the real backstop for reasoning that sounds specific while still failing
  the gate is calibration (§R, Part 2). Per §F denial-2 the screen applies to the
  reasoning offered regardless of which field carried it, so it covers the union of
  `why_opus_is_insufficient`, `why_next_lower_model_is_insufficient`, and
  `routing_reason` for a Fable dispatch.

## Explicitly deferred (not silently dropped)

- **Deep evidence-packet validation (§F rule 10 / §M).** S4 resolves a packet
  *reference*; validating the packet's own schema/contents is the S7 evidence-
  packet validator's job and is deferred there. When S7 lands, rule 10 gains the
  full packet-conformance check.
- **The dispatcher entry point and live routing (S5).** `fm-dispatch-governed.sh`,
  the PreToolUse anti-inheritance hook, `.claude/settings.json` registration, and
  the routing ledger are S5/S6 — a validated request has no routing effect until
  then, by design (§U/S4 "no effect on actual routing until S5").
- **`config/crew-profiles.json` reconciliation (§D5).** Adding the governed
  profile names and task classes to that file is a separate firstmate-repo change.

## Verification (at build)

`bash tests/fm-dispatch-validate.test.sh` (30 tests) and
`bash tests/fm-profile-matrix-check.test.sh` (S3, unaffected) both exit 0;
`shellcheck --norc` over `bin/fm-dispatch-validate.sh`,
`tests/fm-dispatch-validate.test.sh`, and `tests/lib.sh` is clean at the pinned
0.11.0; `git diff --check` is clean. Every one of the 11 governed profiles yields
a valid base request; every §F denial code and every closed-schema property has a
one-property-at-a-time fixture; the two §F canonical denials (omitted model →
`MODEL_REQUIRED`, Fable without justification → `FABLE_JUSTIFICATION_MISSING`)
reproduce.
