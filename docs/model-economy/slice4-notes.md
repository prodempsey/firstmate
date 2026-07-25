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
  per failure; `REQUEST_FINGERPRINT` provenance surface plus the `--write-sidecar`
  write-after-proof / invalidate-before-validation attestation lifecycle mirroring
  `bin/fm-profile-matrix-check.sh`.
- `tests/fm-dispatch-validate.test.sh` — the exhaustive fixture matrix (T.1 in
  full, a wrong-type fixture for all 31 root properties, each always-required
  field's absence, the `binding_fingerprint` format, the both-tier evidence-packet
  requirement, the full sidecar lifecycle, and the fail-closed engine/artifact
  paths).
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
- **Added codes: `PROFILE_IMMUTABLE_MISMATCH`, `NEXT_LOWER_MODEL_INVALID`, and the
  two `DISPATCH_SIDECAR_*` codes.** §F's named list does not give codes for the
  `write_allowed`/`allowed_tools`/`max_turns` immutable-profile fields or for the
  `next_lower_model` relation, but §F declares them immutable-profile / required-when
  fields; the sidecar codes come from the S3 provenance contract the brief requires.
  Enforcing them is fail-closed-correct and the S3 ruling explicitly permits
  extending the code set; the projection codes are the analogue of S3's
  `PROFILE_PROJECTION_MISMATCH`, and the sidecar codes mirror
  `PROFILE_SIDECAR_INVALIDATION_FAILED` / `PROFILE_SIDECAR_WRITE_FAILED`.
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
- **`evidence_packet_id` — field-table vs. example conflict, resolved to the field
  table (QA q156 finding 3).** The §F field table marks it required for every
  `opus-*` or `fable-*` profile, but the §F prose valid example is `opus-high` with
  `evidence_packet_id: null`. Round 1 resolved that conflict in favor of the example
  (requiring the packet only for Fable), which QA q156 rejected as silently
  weakening the binding field-table requirement under a "section-F schema" QA
  contract, and the captain confirmed the field table is binding. S4 now requires a
  non-null `evidence_packet_id` for **every** `opus-*` and `fable-*` profile
  (`EVIDENCE_PACKET_MISSING`); a haiku/sonnet dispatch needs none. When a
  `--packets-dir` is supplied, a present id must resolve to a packet file. This is
  the SHALLOW form of §F rule 10; the DEEP §M packet-schema validation depends on
  the S7 evidence-packet validator and is deferred there (see below).
- **`binding_fingerprint` is a positively-verified format, not a presence check
  (QA q156 FC-003).** Round 1 admitted any non-empty string, so `"x"` false-passed.
  It is now patterned to the exact form its producer emits — `bin/fm-bindings-validate.sh`
  computes `sha256sum | awk '{print $1}'`, i.e. a **bare** 64-hex digest (no
  `sha256:` prefix) — so the schema pattern is `^[0-9a-f]{64}$`. The §F prose
  example's `sha256:9b1f...e04a` is illustrative and does not match the real
  producer; patterning to the prefix would false-*reject* a genuine bindings
  fingerprint, so the bare-hex form is correct. A malformed, prefixed, uppercase, or
  wrong-typed value now fails closed (`DISPATCH_SCHEMA_INVALID`).
- **The provenance sidecar lifecycle is present (QA q156 finding 1).** `--write-sidecar`
  mirrors `bin/fm-profile-matrix-check.sh`'s stale-authority-safe contract exactly:
  the sidecar path is `<request minus .json>.fingerprint`; any pre-existing
  attestation is INVALIDATED in the bash preamble before any validation (or engine
  refusal) can run, and that invalidation is PROVEN — an unlink refused by a
  read-only dir is `DISPATCH_SIDECAR_INVALIDATION_FAILED` (refuse before validation,
  never proceed under stale authority); the fresh attestation is written (temp +
  atomic rename) ONLY after the whole pass proves the request, and an unwritable
  attestation is a clean `DISPATCH_SIDECAR_WRITE_FAILED` with no partial temp file.
  Round 1 omitted this entirely; the suite now covers success-writes-after-proof,
  no-sidecar-on-early/late-failure, stale-sidecar-invalidation, invalidation-failure,
  and write-failure (the last two root-skipped, like S3).
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

## Fixture discipline (QA q156 finding)

The invalid-fixture matrix is now genuinely per-property, not a grouped subset:
`test_every_root_property_wrong_type` asserts a wrong-type fixture for **all 31**
admitted root properties (with a runtime assertion that all 31 ran), and
`test_required_field_absence` deletes each of the 18 always-required fields. Those
sit alongside the format/enum/uniqueness fixtures, the per-§F-denial-code fixtures,
the `binding_fingerprint` format fixtures, the both-tier evidence-packet fixtures,
and the full sidecar lifecycle.

## Explicitly deferred (not silently dropped)

- **Deep evidence-packet validation (§F rule 10 / §M).** S4 requires a non-null
  packet reference for every Opus/Fable dispatch and resolves it against a supplied
  `--packets-dir`; validating the packet's own schema/contents is the S7 evidence-
  packet validator's job and is deferred there. When S7 lands, rule 10 gains the
  full packet-conformance check.
- **The dispatcher entry point and live routing (S5).** `fm-dispatch-governed.sh`,
  the PreToolUse anti-inheritance hook, `.claude/settings.json` registration, and
  the routing ledger are S5/S6 — a validated request has no routing effect until
  then, by design (§U/S4 "no effect on actual routing until S5").
- **`config/crew-profiles.json` reconciliation (§D5).** Adding the governed
  profile names and task classes to that file is a separate firstmate-repo change.

## Verification (at build)

`bash tests/fm-dispatch-validate.test.sh` (38 tests) and
`bash tests/fm-profile-matrix-check.test.sh` (S3, unaffected — both canaries still
reject) both exit 0; `shellcheck --norc` over `bin/fm-dispatch-validate.sh`,
`tests/fm-dispatch-validate.test.sh`, and `tests/lib.sh` is clean at the pinned
0.11.0; `git diff --check` is clean; the request schema is valid Draft 2020-12 and
the policy self-validates. Every one of the 11 governed profiles yields a valid base
request; every §F denial code, all 31 closed-schema properties, and every
always-required field have one-property-at-a-time fixtures; the two §F canonical
denials (omitted model → `MODEL_REQUIRED`, Fable without justification →
`FABLE_JUSTIFICATION_MISSING`) reproduce; and the three QA q156 findings —
sidecar lifecycle, `binding_fingerprint` format, Opus/Fable evidence-packet
requirement — each have direct fixtures.
