# Slice 3 — Governed profile definitions (ORD-271 / ORD-224)

Tracked-material slice landed in the firstmate template repo (design decision
B.1 #15); the runtime home picks it up via the fold/sync path. Design authority:
`data/model-economy/ord-223-report.md` §G (profile matrix), §H (model-selection
policy), §I (effort policy), §T.2 (test group), §U/S3 (slice entry).

## What landed

- `docs/model-economy/governed-profiles.manifest.json` — the single committed
  source of truth (`schema_version: firstmate/governed-profiles/v1`) for all 11
  profiles.
- `.claude/agents/*.md` (11) — the IN-SESSION profile definitions; each carries
  `profile_version: 1`.
- `bin/fm-profile-matrix-check.sh` — the fail-closed matrix validator.
- `tests/fm-profile-matrix-check.test.sh` — the T.2 static rules in full, plus
  fail-closed-parsing negative cases.
- `docs/model-economy/governed-profiles.md` — the pointer doc.

Additive only: no dispatch is routed through the profiles yet (that is S4/S5).

## Fail-closed validation — the authority pattern (QA q119 + q120 — RESOLVED)

QA round 1 (q119) surfaced duplicate-key and unterminated-block holes; QA round
2 (q120) surfaced two deeper validator-class holes — schema-invalid YAML and
mistyped manifest values still passed, and duplicate detection false-passed on
hosts without `python3`. Rather than spot-patch each shape, the validator was
rebuilt on the fleet's proven authority pattern
(`data/dj-orders-s2/design-ruling.md`): **one strict validation pass that must
POSITIVELY PROVE every property before the matrix is authoritative; any parse
ambiguity, type violation, or absent tool = non-authoritative = fail closed,
never a weaker check.**

Concretely:

- The regex line-scraping of YAML is gone. Every `.claude/agents/*.md`
  frontmatter is parsed as a whole YAML document with a strict PyYAML loader that
  rejects duplicate keys; any syntax error anywhere in the document (e.g. the q120
  `permissionMode: [` repro) fails closed (`PROFILE_FRONTMATTER_INVALID`), and any
  unrecognized frontmatter key fails closed rather than being ignored.
- The manifest is validated against an explicit type schema in one JSON pass:
  duplicate keys at any depth (`PROFILE_MANIFEST_DUPLICATE_KEY`), and exact types
  for every field — `writes`/`nesting` must be booleans (a `"true"` string is
  rejected), `version`/`maxTurns.min`/`maxTurns.max` must be integers, `tools`
  must be a unique non-empty string list, `min<=max`, no unknown or missing
  profile keys — all `PROFILE_MANIFEST_INCONSISTENT`.
- Frontmatter values are type-checked after the real parse: `maxTurns` must be an
  integer, `tools`/`disallowedTools` must be lists of strings.
- The parser (`python3` + PyYAML + json) is a **hard prerequisite**. If it is
  absent the validator REFUSES with `PROFILE_VALIDATOR_UNAVAILABLE` and a nonzero
  exit — it never degrades to a weaker best-effort check. This closes the q120
  "duplicate manifest key false-passes without python3" hole at its root: there is
  no path in which a missing tool yields success.

Every property above is encoded as a test with an invalid fixture (the q120 repro
set included): malformed YAML, unknown frontmatter key, mistyped tools, the full
manifest wrong-type matrix (`writes`/`nesting`/`version`/`min` as strings, `min`
> `max`, non-list/non-unique `tools`, wrong-type `effort`, non-list
`models_allowed`, unknown/missing profile key), and the missing-`python3`
refuses-not-degrades path, alongside the round-1 duplicate/delimiter cases.

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

### Proposed S3-acceptance amendment (for coordinator/captain ratification)

Move the two §T.2 runtime probes to the S4/S5 slices that introduce the dispatch
path they exercise, keeping S3's binding acceptance to the T.2 STATIC rules
(all implemented here). This is the "amend the binding S3 acceptance explicitly
rather than silently deferring" resolution the QA recommended. Until ratified,
this note is the explicit, design-referenced record of the deferral.

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
