# Slice 5 — Anti-inheritance PreToolUse guard (ORD-271 / ORD-224)

Tracked-material slice landed in the firstmate template repo (design decision
B.1 #15); the runtime home picks it up via the fold/sync path. Design authority:
`data/model-economy/ord-223-report.md` §J (PreToolUse design: hook-input
K-matrix, validation sequence, the 8 pinned denial codes, the bash+jq sketch,
the 12 test cases), §U/S5 (slice entry, rollback, the highest-risk note), line 39
(governed-profile identification — manifest-driven; "any call with model
containing fable that is NOT a manifest fable-profile is denied"), T.3 (the
PreToolUse test group). Depends on S3 (the profile matrix the guard projects
from) and S4 (the dispatch-request schema whose `dispatch_request_id` form the
justification marker must carry). Authority pattern:
`data/me-s3-profiles/design-ruling.md`.

This is the FINAL retirement piece of the model-economy program: it PERMANENTLY
replaces the temporary ORD-227 maintenance guard. The permanent guard is landed
and proven here; the temporary guard's stand-down is a separate, captain-gated
act, DESIGNED (not performed) below under "Cutover".

## What landed

- `bin/fm-agent-dispatch-pretool.sh` — the permanent PreToolUse guard (Agent
  matcher). Reads the runtime-visible payload (`tool_input.subagent_type`,
  `tool_input.model`, `tool_input.description`, and — inside a subagent session —
  `agent_type`), projects the governed set / per-profile pinned model / per-profile
  nesting flag from the LANDED S3 manifest, and denies fail-closed with one stable
  code per failure. Consume-the-landed-manifest precedent: `bin/fm-dispatch-validate.sh`.
- `tests/fm-agent-dispatch-pretool.test.sh` — T.3 in full: §J's 12 pinned test
  cases, one positive control per governed profile projected from the matrix, the
  S3 Fable-ceiling interplay, the line-39 refinement, native-exception narrowness,
  caller-nesting authority, justification-marker rigor, matcher scoping, and every
  fail-closed engine/artifact path. 51 checks.

**Not created here (design-only, per the slice's constraints):** the hook
REGISTRATION in `firstmate-runtime/.claude/settings.json`. Registration is the
"go-live" moment and is captain-gated; see "Cutover". Because the guard is
additive until registered, landing the script changes no live behavior.

## Denial codes

§J pins eight. The guard implements all eight, plus one documented refinement and
four honest fail-closed infra codes.

| Code | Trigger | Source |
|---|---|---|
| `MODEL_REQUIRED` | non-fork Agent call, `model` absent | §J |
| `PROFILE_REQUIRED` | governed-tier model, `subagent_type` empty | §J |
| `MODEL_PROFILE_MISMATCH` | pinned profile, `model` ≠ its matrix pin | §J |
| `PROFILE_NOT_GOVERNED` | reserved prefix but not a pinned profile (typos, invented names, and the prohibited names — the Fable/Opus ceiling) | §J |
| `FABLE_JUSTIFICATION_MISSING` | `fable-*` profile, no well-formed `[governed:…]` marker | §J |
| `OPUS_XHIGH_JUSTIFICATION_MISSING` | `opus-xhigh`, no well-formed `[governed:…]` marker | §J |
| `NESTING_PROHIBITED` | the calling agent's own profile forbids nesting | §J |
| `NATIVE_INHERITANCE_EXCEPTION_INVALID` | `fork` call with an explicit `model` | §J |
| `FABLE_MODEL_UNGOVERNED` | `model` contains `fable` on a non-empty ungoverned `subagent_type` | line-39 refinement |
| `GUARD_ENGINE_UNAVAILABLE` | `jq` missing | fail-closed infra |
| `GUARD_PAYLOAD_UNREADABLE` | empty/unparseable payload | fail-closed infra |
| `GUARD_MANIFEST_UNVERIFIED` | the S3 matrix did not pass its landed validator (missing, corrupt, schema-invalid, injected/duplicate/tampered profile, projection drift, or validator engine absent) | fail-closed authority |
| `GUARD_SCHEMA_UNVERIFIED` | the S4 request schema is not the authoritative committed one (missing, non-object, wrong `$id`, or a non-canonical request-id pattern); checked only when a justification gate needs it | fail-closed authority |

## Design decisions (deviations from §J's sketch, and why)

1. **Manifest-projected, not hardcoded.** §J's bash sketch inlines the profile
   list, the profile→model map, and a `nesting_allowed_for()` that hardcodes
   `fable-*→true`. This guard instead projects all three from the landed S3 manifest
   (`governed-profiles.manifest.json`), per line 39's ruling ("the hook loads the
   manifest") and the S3 ruling's single-source-of-truth mandate ("never hand-
   maintain a second surface"). The nesting flag is read per-profile from the
   matrix's own `nesting` field, so a matrix change (a new profile, a changed
   nesting posture) reaches the guard with no code edit and no drift. This is the
   FC-001 posture: the guard's authority for what is governed comes from ONE
   declared source, not a parallel hand-maintained list.

2. **Line-39 refinement `FABLE_MODEL_UNGOVERNED` (beyond §J's default-allow).**
   §J's sketch `exit 0`s an ungoverned `subagent_type` (e.g. `general-purpose`)
   once it carries any explicit model — so `general-purpose` + `model: fable` would
   be allowed. The design-decision table (line 39) is explicit that "any call with
   model containing fable that is NOT a manifest fable-profile is denied": an
   explicit Fable child through an ungoverned type routes around the `fable-*`
   justification gate (the Opus-insufficiency handshake), which is exactly the
   smuggle this slice exists to close. The guard therefore denies a Fable model on
   a non-empty ungoverned type with its own clearly-named code, rather than
   overloading `PROFILE_REQUIRED` (whose §J trigger is specifically "`subagent_type`
   absent/empty"). Non-Fable explicit models on ungoverned types stay allowed (§J
   test #10); this design does not mechanically reclassify ungoverned work as
   governed.

3. **Marker validated against the S4 request-id form, not just present.** §J step
   8/9 checks marker presence with a bare `grep`. This guard additionally requires
   the marker's `dispatch_request_id` to match the exact pattern the S4 request
   schema pins (`.properties.dispatch_request_id.pattern`, read from the schema so
   the form has one owner), so `[governed:dispatch_request_id=]` or
   `[governed:dispatch_request_id=garbage]` cannot false-satisfy the gate. The guard
   does not — and structurally cannot — re-validate the referenced request's
   content; that is S4's owned pass at request-build time. This is the hook-layer
   "validated against the S4 schema" connection.

4. **Caller-nesting settled first.** §J's own step 10 says to deny a nested call
   "outright regardless of what it is trying to dispatch," yet its sketch places the
   nesting check last, after ungoverned targets have already `exit 0`d and after
   `fork` has already been allowed. This guard evaluates the caller's nesting
   authority before the target, so a nesting-barred caller is denied whatever it
   dispatches (including a `fork`). All 12 §J pinned cases still yield their pinned
   codes (only #12 carries a caller, and it is top-of-tree elsewhere). In practice
   this is defence-in-depth: only `fable-*` profiles carry the `Agent` tool at all,
   and they are the nesting-permitted ones, so the deny path is rarely reached —
   but the ordering makes the caller-authority guarantee unconditional.

5. **Fail closed on an artifact it cannot PROVE authoritative — via the artifacts'
   own landed validators (QA qa-me-s5-q163).** The guard treats the S3 matrix and the
   S4 request schema as policy authority, so it must prove each authoritative before
   reading a single value — a shallow field check is not proof. A manifest that keeps
   `schema_version`/`profiles`/`models_allowed` but injects a `fable-xhigh` past the
   ceiling, or a schema that keeps its `$id` but weakens the request-id `pattern` to
   `^.*$`, would pass a shallow check and produce a **false allow**. So:
   - the S3 matrix is proven by delegating to the LANDED validator
     `bin/fm-profile-matrix-check.sh` (closed schema, the eleven-profile set,
     duplicate keys, the prohibited-name rule, and the frontmatter projection) — never
     a re-implemented partial check; any non-zero exit → `GUARD_MANIFEST_UNVERIFIED`;
   - the S4 request schema is proven by an identity (`$id`) + canonical-pattern
     cross-check against the guard's OWN pinned `CANONICAL_REQUEST_ID_PATTERN` (kept
     byte-identical to the committed schema), and the marker is matched against that
     pinned value, not the mutable file; any divergence → `GUARD_SCHEMA_UNVERIFIED`.

   The maintenance guard fails OPEN on absent tooling because it is narrowly
   maintenance-scoped; the permanent guard is the fleet-wide policy floor and fails
   CLOSED on absent `jq`, absent `python3`/`jsonschema` (the S3 validator's engine),
   or any unproven artifact — matching S3/S4's "refuse if the engine is absent" and
   FC-002/FC-004 (a guard cannot clear a dispatch it cannot prove; absent/corrupt
   coverage retains "not authoritative"). The infra codes are honest about the real
   reason, never a fabricated policy verdict. Cost: the S3 validator runs in ~0.2 s,
   acceptable on a hook that gates a multi-second subagent spawn; if a hot path ever
   needs it cheaper, the validator's `--write-sidecar` attestation (verify a fresh
   `<manifest>.fingerprint` instead of re-running the validator) is the documented
   optimization. If a matrix corruption ever did halt governed dispatch fleet-wide,
   the mitigation is the same instant unregistration in "Cutover" — not a fail-open.

## Scope boundaries / deferrals

- **Registration is design-only** (this slice). Adding the PreToolUse/Agent hook to
  `firstmate-runtime/.claude/settings.json` is the captain-gated go-live; see
  "Cutover".
- **No ledger / telemetry.** §J step 11 mentions emitting `dispatch_started` to the
  routing ledger. That schema and every telemetry field are slice S6's owned surface
  (`bin/fm-agent-dispatch-posttool.sh`, `data/model-routing-events.jsonl`, schema
  `firstmate/model-routing-event/v1`). S5 stays a pure gate with no state writes, so
  a hot hook path has zero state coupling; denials are visible via the stderr reason
  the harness already captures.
- **`CLAUDE_CODE_SUBAGENT_MODEL` env detection NOT claimed as a control.** Design
  decision #9 (line 47) approved reading that env var as *best-effort* resolved-model
  detection "with a mandatory Slice-5 verification test before it is claimed as a
  control." No such empirical verification is performed here, so — per FC-001 (no
  authority from an unverified mechanism) — the guard does not read it and claims no
  resolved-model control. Model omission is detected purely from `tool_input.model`'s
  absence, which §J calls "the concrete mechanism the whole hook is built on." The
  resolved-vs-requested comparison remains S6/§K's post-dispatch surface, honestly
  flagged there as `resolved_effort_available:false` and IN-SESSION-only for
  resolved model.
- **Runtime probes (T.3) are documented, not run.** T.3's live-harness probes ("one
  real omitted-model Agent call in a disposable sandbox, confirm denial", etc.) can
  only exercise a REGISTERED hook, and registration is the captain-gated go-live.
  The guard's LOGIC is positively proven here by the 51 fixtures against real
  PreToolUse payloads; the live probes are the go-live acceptance step in "Cutover"
  and must not be reported as passed until then.

## Cutover: standing down the temporary ORD-227 guard (DESIGN ONLY)

The retirement rule is **never-two-competing-policy-systems**. The permanent guard
(this slice) and the temporary ORD-227 maintenance guard enforce *different*
policies over the *same* Agent-dispatch surface, so they must never both be
registered at once. The stand-down is a single captain-gated act; nothing here
performs it.

### The two systems, and why they conflict

| | Temporary ORD-227 guard | Permanent guard (this slice) |
|---|---|---|
| File | `~/.claude/skills/krakenloop-fable-maintenance/hooks/agent-guard.sh` | `bin/fm-agent-dispatch-pretool.sh` (runtime `.claude/settings.json`) |
| Matcher | `Agent\|Task` (user-level) | `Agent` (runtime deployment-local) |
| Scope | ONLY when maintenance mode is active AND cwd is inside an affected fleet path; otherwise allows everything | Fleet-wide standing policy, always on once registered |
| Fable posture | Fable is the maintenance LEAD only → denies EVERY Fable child (`FABLE_CHILD_PROHIBITED`), and denies bare `fork` (`NATIVE_INHERITANCE_EXCEPTION_INVALID`, since the lead may be Fable) | Fable is a governed exceptional tier → ALLOWS `fable-*` with a justification marker, and ALLOWS bare `fork` (native carve-out) |
| Approved agents | the four `krakenloop-*` maintenance agents | the eleven governed profiles |
| jq absent | fail OPEN (allow) | fail CLOSED (deny) |

The conflict is concrete: while maintenance mode is active, the temporary guard
enforces the STRICTER posture (no Fable children at all, no bare fork). The
permanent guard would ALLOW a marker-carrying `fable-*` dispatch and a bare fork
that the maintenance policy forbids. Registering both would subject one dispatch
to two contradictory rulesets — the exact "two competing policy systems" the
retirement rule bars.

### Stand-down sequence (captain-gated; single owner per step)

The temporary package's own retirement trigger already anticipates this:
`~/.claude/skills/krakenloop-fable-maintenance/references/rollback.md` — "Retire
this package when ORD-224 Phases 4-9 … are installed and verified from a fresh
session. Never run both policy systems side by side once the permanent one is
live." This slice is the last of those pieces. The ordered cutover:

1. **Land the permanent guard** (this slice) into the template repo and let the
   runtime home pick it up via the normal fold/sync path. Still additive — no hook
   is registered, no live behavior changes.
2. **Sandbox verification (T.3 runtime probes).** In a disposable sandbox / a
   secondmate home, register the permanent guard and run T.3's live probes: a real
   omitted-model Agent call is denied; a real valid dispatch is allowed; a
   mismatched dispatch is denied; a real `fork` passes and never spuriously trips
   `NATIVE_INHERITANCE_EXCEPTION_INVALID` when the resolved model is non-Fable. Per
   §U, staged rollout in a sandbox first is the mitigation for this slice's
   highest-of-ten risk (an over-broad denial rule blocking ordinary crewmate work).
3. **Captain confirms verification.** Go-live is the captain's decision, made on the
   sandbox evidence from step 2.
4. **Register the permanent guard** in `firstmate-runtime/.claude/settings.json`
   (PreToolUse, matcher `Agent`) — deployment-local config, the go-live moment.
5. **Retire the temporary package atomically with go-live**, per the ORD-227
   rollback's "Full removal (retirement)": restore the pre-ORD227 user settings
   backup (removing the `Agent|Task` maintenance-guard registration AND the
   SessionStart reminder), remove the temporary CLAUDE.md maintenance section, the
   four `krakenloop-*` agents, and the skill package; PRESERVE the maintenance
   records (`state/krakenloop-maintenance-mode.json` set inactive, the guard log,
   any exceptions file) by moving them into `data/model-economy/` for history. Steps
   4 and 5 are the same captain-gated window so there is never a moment with BOTH
   guards live or NEITHER guarding model omission.

   *Ordering note.* Because the maintenance guard is the STRICTER of the two while
   maintenance mode is active, its stand-down is tied to maintenance-mode
   RETIREMENT itself, not merely to the permanent guard being available. If the
   captain chooses to keep maintenance mode active past permanent go-live, the safe
   posture is to KEEP the maintenance guard as the sole registered system (it is
   stricter and maintenance-scoped) and defer registering the permanent guard until
   maintenance retires — never to run both. Either way the invariant holds: exactly
   one policy system over the Agent surface at any instant.

6. **Post-cutover verification** (ORD-227 rollback step 6): from a fresh session in
   a fleet repo, no maintenance banner appears, and a model-omitted Agent call is
   now denied by the PERMANENT guard's `MODEL_REQUIRED` (not the maintenance
   guard) — confirming the standing policy floor is the one enforcing it.

### Rollback of the permanent guard itself

Instant and data-free (§U): remove the PreToolUse/Agent registration from
`firstmate-runtime/.claude/settings.json` and `git revert` the script. Because the
guard writes no state, there is nothing to migrate or unwind. This is also the
emergency valve if a live denial rule ever proves over-broad.
