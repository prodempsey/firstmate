#!/usr/bin/env bash
# The canonical seed set for the failure-class ledger (Compounding Fleet stage C,
# ORD-274): the seven failure classes distilled from the binding design rulings and
# the 2026-07-22..24 QA FAIL corpus, each with a one-line invariant, detection cues,
# a fix pattern, and cited provenance.
#
# This builder is NON-DESTRUCTIVE. The ledger is durable append-only history, so
# this script never deletes it and never rebuilds it in place. Every class is
# emitted through `fm-failure-class.sh ensure`, which is idempotent-additive: an
# already-present class id is a skip, never a drop or a rewrite. Re-running against
# a populated ledger therefore preserves every appended occurrence.
#
# Modes:
#   --check (default)  Build the canonical seed into a throwaway temp ledger and
#                      byte-compare its class-defined lines against the committed
#                      ledger. Proves reproducibility; writes nothing durable.
#   --apply            Idempotently ensure the seven classes into $FM_FC_LEDGER
#                      (default: the committed ledger). Additive; never drops a row.
#   --to <path>        Build a fresh seed into <path>, which MUST NOT already exist
#                      (refuses to overwrite). For inspection / test fixtures.
#
# Provenance refs point at firstmate-runtime's data/ corpus (the home where the
# rulings and QA reports live); the runtime home is where `register --live` is run.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FC="$ROOT/bin/fm-failure-class.sh"
COMMITTED="$ROOT/docs/failure-classes/ledger.jsonl"
die() { echo "seed: $*" >&2; exit 1; }

MODE=check
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --apply) MODE=apply; shift ;;
    --to) MODE=to; OUT=${2:-}; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) die "unknown flag '$1' (see --help)" ;;
  esac
done

# emit_seed ensures the seven canonical classes into the ledger named by
# FM_FC_LEDGER. Idempotent and additive; safe to run against a populated ledger.
emit_seed() {

"$FC" ensure --id FC-001 \
  --name "Authority as allowlist instead of closed-schema positive proof" \
  --invariant "A conclusion may be drawn only from ONE atomic pass that positively proves conformance to a single declared, closed schema; authority defaults to none and is NEVER inferred from the absence of a failing check." \
  --fix "Replace the enumerated per-property check ladder with conformance to one committed closed schema (additionalProperties:false, full required, exact type, enum, uniqueItems) proven in a single pass; any property the schema does not positively admit is a failure. Prove conformance; do not spot-check known-bad shapes." \
  --cue "the validator is a growing ladder of per-property die()/if checks discovered one adversary at a time" \
  --cue "'validated' means 'the substrings/fields I remembered to check passed', not 'the whole document conforms'" \
  --cue "each QA round finds a NEW corruption/drift shape the previous round did not enumerate (r1->r2->r3 same spine)" \
  --cue "additionalProperties is open in effect: an admitted-key-set is treated as a closed schema" \
  --cue "the brief/finding says 'add a check for X' rather than 'prove conformance to the schema'" \
  --provenance "ruling:data/dj-orders-s2/design-ruling.md#1-root-cause:authority defined as a growing ad-hoc conjunction of checks rather than one positive invariant with a fail-closed default" \
  --provenance "ruling:data/me-s3-profiles/design-ruling.md#1:authority = enumerated conjunction of hand-authored per-property predicates instead of conformance to one closed schema" \
  --provenance "qa:data/qa-me-s3r4-q122/report.md:type validation keeps false-passing across three implementations (uphold FAIL)" \
  --provenance "qa:data/qa-dj-s2r3-q107/report.md:partial-ID audit deemed globally authoritative under a reactively-assembled validator"

"$FC" ensure --id FC-002 \
  --name "Absence read as discharge" \
  --invariant "An obligation is cleared ONLY by positive proof from a fresh, structurally-complete, authoritative snapshot that provably enumerates that obligation's status; absent/stale/corrupt/partial coverage RETAINS the prior fact unchanged (fail-open when CREATING a block, fail-closed when DISCHARGING one)." \
  --fix "Consume coverage as positive per-item proof; retain every prior obligation whenever the source is non-authoritative for any reason; never read an id's absence-from-a-set-of-unknown-coverage as accounted; keep block creation fail-open and block discharge fail-closed by construction." \
  --cue "code concludes 'id absent from the current set => accounted/done/discharged'" \
  --cue "a stale or partially-read file is allowed to shrink or clear a tracked set" \
  --cue "a 'count == length' style check is treated as proof of complete coverage" \
  --cue "a timeout/contention path silently drops the occurrence it could not record" \
  --provenance "ruling:data/dj-orders-s2/design-ruling.md#1:the gate decides an order's fate by inference from the audit file's silence; absence read as discharge" \
  --provenance "ruling:data/dj-orders-s2/design-ruling.md#2.3-2.4:non-authoritative audit covers no id; every prior order:X is retained" \
  --provenance "qa:data/qa-dj-s2r2-q106/report.md:stale read reporting zero orders dropped a prior blocked order (silence was discharge)" \
  --provenance "qa:data/qa-g2-q4/report.md#39:contention timeout must not silently discard the occurrence; preserve an append-safe fallback record"

"$FC" ensure --id FC-003 \
  --name "Digest/verification not covering the whole document" \
  --invariant "A content digest or verification that gates a mutation must hash the ENTIRE canonical document (minus only explicitly-excluded volatile keys), so a change to ANY field - including fields no check enumerates - invalidates the approval." \
  --fix "Compute the digest over the whole canonical serialization (sorted keys; exclude only named volatile keys) and recompute-and-compare before any mutation; parse whole documents with a strict loader instead of grepping first-occurrence substrings; compare the whole replayed object, not a hand-picked set of leaves." \
  --cue "the approval digest/hash is computed over a hand-selected subset of fields" \
  --cue "the parser scrapes first-occurrence substrings (regex/jq -e .) instead of parsing the whole document" \
  --cue "a mutation to an un-enumerated field still passes an 'approved' gate" \
  --cue "a per-field comparison enumerates 'the fields we check' rather than proving whole-object equality" \
  --provenance "ruling:data/me-s3-profiles/design-ruling.md#1:r1 scraped substrings; validated meant the substrings I grepped for were present" \
  --provenance "qa:data/qa-mem-pr3r2-q113/report.md#70:computeDigest now hashes the canonical WHOLE proposal document rather than a hand-selected projection (migrate.mjs:95-116)" \
  --provenance "qa:data/qa-mem-pr4r3-q117/report.md#35:manifest digest recomputed and the whole replayed object (counts/omitted/fallbackReason/identity) compared, not selected leaves"

"$FC" ensure --id FC-004 \
  --name "Fail-open on a missing prerequisite tool" \
  --invariant "When a required validation engine/tool is absent, the validator REFUSES (stable code, non-zero exit) - never a best-effort, warn-and-pass, or weaker path. There is no code path in which a missing tool yields success." \
  --fix "Make every engine a HARD prerequisite that prints a stable *_UNAVAILABLE code and exits non-zero when missing; test each absent-tool path explicitly and independently; never gate a correctness check on the presence of an optional dependency." \
  --cue "command -v X || <skip the check> / <weaker path>" \
  --cue "'if python3/jq/jsonschema/timeout absent, fall back to ...'" \
  --cue "a duplicate/type/deadline check that only runs when an optional tool is present" \
  --cue "the fix relies on GNU-only tooling that is simply absent on a supported platform (macOS)" \
  --detection '{"engine":"awk-ere","pattern":"command -v .*[|][|][[:space:]]*(true|:|return 0|continue)([[:space:]#]|$)","cue_ref":"command -v X || <skip the check> / <weaker path>"}' \
  --provenance "ruling:data/me-s3-profiles/design-ruling.md#3.2:python3+PyYAML+jsonschema are hard prerequisites; if any is absent print PROFILE_VALIDATOR_UNAVAILABLE and exit 1, never warn-and-pass" \
  --provenance "ruling:data/me-s3-profiles/design-ruling.md#5:MUST NOT degrade when any engine is absent" \
  --provenance "qa:data/qa-me-s3r7-q125/report.md:engine fail-closed / no-degradation contract under absent tool"

"$FC" ensure --id FC-005 \
  --name "Proof/validation not atomic with the mutation it authorizes" \
  --invariant "The values a mutation is authorized against must come from the SAME atomic read/parse that validated them, and the proof (or audit annotation) must be atomic with the mutation, so no consumer can ever observe a different generation than the one validated." \
  --fix "One parse per artifact feeds duplicate-rejection, validation, and the downstream consume, emitting the validated payload from the validating pass; make the proof/annotation atomic with (or transactionally bound to) the mutation; close the two-pass read race." \
  --cue "two jq/parse passes over the same file (validate, then re-read the ids/values)" \
  --cue "a proof written non-atomically with the mutation it attests" \
  --cue "a per-row audit annotation that is not atomic with the reconciliation it records" \
  --cue "a pair of writes/renames each individually atomic but not jointly atomic or writer-serialized" \
  --provenance "ruling:data/dj-orders-s2/design-ruling.md#2.2:one atomic jq pass validates AND emits the ids so no consumer sees a different generation (MUST NOT read in two passes)" \
  --provenance "qa:data/qa-mem-pr4-q115/report.md#144:F3 - proof mutation and proof verification are not atomic/complete" \
  --provenance "qa:data/qa-scr-q93/report.md#125:the required per-row audit annotation is not atomic with reconciliation" \
  --provenance "qa:data/qa-m1r3-q22/report.md#30:each rename is atomic but the pair is not atomic or writer-serialized"

"$FC" ensure --id FC-006 \
  --name "Unbounded/synchronous wait on a critical path" \
  --invariant "Any call on a latency-critical path (spawn, dispatch, turn-end) must be bounded by a PORTABLE hard deadline that a missing tool cannot defeat, and must fail-open to the no-op outcome when the deadline hits - never block the critical operation." \
  --fix "Wrap the call in a portable deadline (a PID-watchdog fallback when GNU timeout/gtimeout are absent) that kills only the exact recorded child PID and returns the fail-open outcome; regression-test the no-timeout PATH; keep recall/delivery out-of-band so it can never wedge the primary." \
  --cue "a helper invoked synchronously on the spawn/dispatch path with no timeout" \
  --cue "|| true that handles a non-zero exit but NOT a child that never returns" \
  --cue "a deadline implemented with a GNU-only timeout that is absent on a supported host" \
  --cue "a network/HTTP/recall call awaited inline on the critical path" \
  --detection '{"engine":"awk-ere","pattern":"(curl|wget|nc|ssh|wait|sleep)([[:space:]][^|]*)?[|][|][[:space:]]*true([[:space:]#]|$)","cue_ref":"|| true that handles a non-zero exit but NOT a child that never returns"}' \
  --provenance "qa:data/qa-mem-pr4-q115/report.md#104:injection cannot block a spawn - FAIL: the memory CLI is executed synchronously with no timeout (fm-memory-inject.sh:113)" \
  --provenance "qa:data/qa-mem-pr4r2-q116/report.md#69:supported hosts without GNU timeout remain unbounded" \
  --provenance "qa:data/qa-mem-pr4r4-q118/report.md#84:fix - portable PID-watchdog deadline completes a 2s budget against a 12s child, brief unchanged" \
  --provenance "report:data/kl-improve-scout-f5/report.md#improvement-3:delivery must never touch the composer/transcript path and must never block a spawn"

"$FC" ensure --id FC-007 \
  --name "Stale artifact preserved on failure (cleanup-failure ignored)" \
  --invariant "On a failed or refused operation, any stale attestation/index/output must be provably invalidated (removed or atomically superseded) BEFORE proceeding, and a cleanup/unlink failure must itself fail the operation - never '|| true'. A stale artifact must never be read as a fresh, authoritative result." \
  --fix "Verify the stale artifact is actually gone (or atomically superseded) and refuse loudly if invalidation fails; write outputs via temp-file + fsync + atomic rename so a crash leaves no partial file; treat a stale/missing derived index as non-authoritative => no injection / no consume." \
  --cue "rm -f ... 2>/dev/null || true guarding an attestation/sidecar/lock" \
  --cue "a stale derived index treated as a 'proven' result and consumed" \
  --cue "an operation that leaves a partial/temp file on crash (no atomic rename)" \
  --cue "'invalidate' that neither verifies the old artifact is gone nor refuses on failure" \
  --detection '{"engine":"awk-ere","pattern":"rm[[:space:]].*2>/dev/null.*[|][|][[:space:]]*true","cue_ref":"rm -f ... 2>/dev/null || true guarding an attestation/sidecar/lock"}' \
  --provenance "qa:data/qa-me-s3r6-q124/report.md#98:unlink refusal leaves stale authority; the unconditional || true neither verifies the old attestation is gone nor refuses" \
  --provenance "qa:data/qa-mem-pr4-q115/report.md#112:F1 - stale or missing derived index injects instead of failing open" \
  --provenance "qa:data/qa-s6-q72/report.md#90:fix pattern - temp write + fsync + atomic rename; the crashed child leaves no final partial file"
}

# class-defined lines only: the canonical seed. Occurrence events appended later
# through `bump` are legitimate history and are intentionally NOT part of the seed
# comparison, so a reproducibility check never fights real appended provenance.
class_defined_lines() { jq -c 'select(.event=="class-defined")' "$1"; }

case "$MODE" in
  apply)
    export FM_FC_LEDGER="${FM_FC_LEDGER:-$COMMITTED}"
    emit_seed
    "$FC" validate
    echo "seed: applied (additive/idempotent) to $FM_FC_LEDGER"
    ;;
  to)
    [ -n "$OUT" ] || die "--to requires a path"
    [ ! -e "$OUT" ] || die "refusing to overwrite existing $OUT (choose a fresh path)"
    mkdir -p "$(dirname "$OUT")"
    FM_FC_LEDGER="$OUT" emit_seed
    FM_FC_LEDGER="$OUT" "$FC" validate
    echo "seed: wrote fresh seed to $OUT"
    ;;
  check)
    [ -f "$COMMITTED" ] || die "committed ledger not found: $COMMITTED"
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    FM_FC_LEDGER="$tmp" emit_seed >/dev/null
    if diff <(class_defined_lines "$tmp") <(class_defined_lines "$COMMITTED") >/dev/null; then
      echo "seed: OK - committed ledger's class-defined lines match the canonical seed (writes nothing)"
    else
      echo "seed: MISMATCH - committed ledger's class-defined lines differ from the canonical seed:" >&2
      diff <(class_defined_lines "$tmp") <(class_defined_lines "$COMMITTED") >&2 || true
      exit 1
    fi
    ;;
esac
