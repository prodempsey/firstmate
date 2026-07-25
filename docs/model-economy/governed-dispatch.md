# Governed dispatch request schema and validator

The model-economy program (ORD-224) routes governed Opus/Fable-class decision
work through a single validated dispatch-request document. This slice (S4)
commits that request schema and the fail-closed validator the dispatch path
consults; it does **not** wire the PreToolUse anti-inheritance guard (S5), the
routing ledger (S6), or any actual spawn — until S5, a validated request has no
effect on live routing. S4 builds directly on S3: the profile axis (model,
effort, tools, writes, nesting, maxTurns bounds) is projected from the landed
`governed-profiles.manifest.json`, never re-authored here.

Design authority: `data/model-economy/ord-223-report.md` §F (dispatch request
schema — field table, cross-field rules 1-13, fail-closed outcomes, versioning,
the one valid + two denied examples), §H (the enumerated Opus-insufficiency
denylist §F rule 6 defers to); brief §6 (the must-reject list). Authority
pattern: `data/me-s3-profiles/design-ruling.md` (binding precedent for this
program), precedent `data/dj-orders-s2/design-ruling.md`.

## The artifacts

- **The request schema** — `docs/model-economy/schemas/governed-dispatch-request.schema.json`
  (`$id: firstmate/governed-dispatch-request/v1`): the closed, total
  (`additionalProperties:false`) JSON Schema for a dispatch request. It enumerates
  every §F field, each fully typed, with enums for `task_type`/`requested_model`/
  `configured_effort`/`next_lower_model`, a UUIDv4 `dispatch_request_id`, a 40-hex
  `HEAD`, a `sha256:<64hex>` `runtime_state_fingerprint`, and `const` pins on
  `schema_version`/`policy_version`. It proves **structure**. `configured_effort`
  deliberately excludes `max`, so Opus-max / Fable-max fail closed at the schema.
- **The policy artifact** — `docs/model-economy/governed-dispatch-policy.json`
  (`schema_version: firstmate/governed-dispatch-policy/v1`, validated against its
  own closed schema): the single machine-authoritative source for the semantic
  data the request schema cannot enumerate declaratively — the supported request
  schema id, the model tier order (for `next_lower_model` derivation), the
  committed governed task-class taxonomy (§F `task_class` / §D5), and the
  Opus-insufficiency denylist phrases (§H). The profile axis is **not** duplicated
  here; the validator reads the S3 manifest directly.
- **The validator** — `bin/fm-dispatch-validate.sh`: THE validator the dispatch
  path consults, fail-closed on every §F rule.

## Validating a dispatch request

`bin/fm-dispatch-validate.sh <request.json>` follows the S3 authority pattern: one
atomic pass proves authority by *conformance to the closed committed schemas*
(request, policy, and the S3 manifest it projects from) plus the §F named
cross-field/cross-artifact rules — never an enumerated ladder of hand-written type
predicates. `python3` and `jsonschema` are hard prerequisites; if either is absent
the validator refuses (`DISPATCH_VALIDATOR_UNAVAILABLE`, exit 1) rather than
degrading. The ordered pass:

1. **schema_version gate** (§F rule 13) — any value but the supported version is
   `SCHEMA_VERSION_UNSUPPORTED`, never coerced and never drowned in structural
   errors.
2. **model/profile presence** — a null/absent `requested_model` or
   `selected_profile` gets its specific shared-with-hook code (`MODEL_REQUIRED` /
   `PROFILE_REQUIRED`) ahead of the structural schema.
3. **structural conformance** — the closed request schema is the enumeration;
   anything structural not owned by a named rule is `DISPATCH_SCHEMA_INVALID`.
   After this, every field is type-proven, so the named checks below never
   compare-before-type.
4. **governance + taxonomy** — `selected_profile` must be one of the 11 governed
   names (prohibited names are simply absent from the matrix →
   `PROFILE_NOT_GOVERNED`); `task_class` must be in the committed taxonomy
   (`TASK_CLASS_UNKNOWN`).
5. **immutable-profile projection against the S3 manifest** — `requested_model`
   (`MODEL_PROFILE_MISMATCH`), `configured_effort` (`PROFILE_EFFORT_MISMATCH`,
   including the Sonnet-fixed-high invariant), `nesting_allowed`
   (`NESTING_PROHIBITED`), and `write_allowed`/`allowed_tools`/`max_turns`-bounds
   (`PROFILE_IMMUTABLE_MISMATCH`) must equal the manifest projection for the
   profile.
6. **justification gates** — `opus-xhigh` requires a non-empty
   `opus_xhigh_justification` (`OPUS_XHIGH_JUSTIFICATION_MISSING`); every Fable
   dispatch requires a non-empty `why_opus_is_insufficient` free of the §H
   denylist phrases and an `evidence_packet_id` (`FABLE_JUSTIFICATION_MISSING` /
   `EVIDENCE_PACKET_MISSING`); a non-haiku dispatch needs a correct
   `next_lower_model` and its justification (`NEXT_LOWER_MODEL_INVALID`).
7. **environment agreement** — `captain_exception_id` must be attributable to a
   captured captain instruction (`CAPTAIN_EXCEPTION_INVALID`); `parent_task_id`
   must resolve to a tracked task or the in-session id (`PARENT_LINKAGE_MISSING`);
   where exact repo state is required (a `ship`/`review` dispatch or any claimed
   `HEAD`/`worktree`/`branch`/`runtime_state_fingerprint`), the validator re-reads
   the LIVE worktree and compares rather than trust a possibly-stale snapshot
   (`REPO_STATE_STALE`) — a harmless `git` probe, no model call.

On success it prints `DISPATCH_OK=<profile>` and `REQUEST_FINGERPRINT=` (sha256 of
the canonical request), which the dispatch path records so a routing decision is
traceable to the exact request that produced it (`--expect-fingerprint` pins it).
Every failure prints exactly one stable code — see the script header for the full
list. Fail-closed everywhere: a captain override changes a would-be-denied outcome
only by supplying a resolvable `captain_exception_id`, never by suppressing a
check.

```sh
bin/fm-dispatch-validate.sh request.json --session-id <in-session-id>
bin/fm-dispatch-validate.sh request.json --state-dir state --packets-dir data/<t>/packets
```

Coverage lives in `tests/fm-dispatch-validate.test.sh`: a valid base request
projected from the committed matrix for every governed profile, the two §F
canonical denials, the fail-closed engine/artifact paths, one structural fixture
per closed-schema property, and one fixture per §F dedicated denial code (the full
T.1 must-reject list). Scope boundaries and the S7-deferred pieces are recorded in
`docs/model-economy/slice4-notes.md`.

## Maintaining this file

Keep this to what almost every future session touching governed dispatch needs.
Point to the request schema, the policy artifact, and the validator rather than
restating them; when a §F rule changes, update the schema/policy/validator and its
test together. Prefer pruning stale detail over appending.
