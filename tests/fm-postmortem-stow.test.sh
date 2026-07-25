#!/usr/bin/env bash
# Colocated unit tests for bin/fm-postmortem-stow.sh (ORD-274 Seasoning stage A -
# postmortem capture at closeout).
#
# The hook distills a finished task's closeout into a STRUCTURED POSTMORTEM memory CANDIDATE via
# `mem propose`, fire-and-forget, mirroring the cp-shadow contract. These tests pin the invariants
# the slice must guarantee:
#   * gated-off inert            - no ambient FM_POSTMORTEM_STOW, no config file -> nothing written;
#   * chokepoint fires (gate on) - env FM_POSTMORTEM_STOW=1 -> a CANDIDATE lands in the FIXTURE
#                                  registry, carrying source_type/task provenance, status candidate
#                                  (proposed, 0 active - propose-not-auto-activate lifecycle);
#   * file-gated on              - config/postmortem-stow.env FM_POSTMORTEM_STOW=1 fires too, and an
#                                  ambient FM_POSTMORTEM_STOW=0 suppresses the file;
#   * malformed/unreadable gate  - a garbage or unreadable gate file never fails the caller;
#   * inert when memory absent   - no resolvable memory CLI -> silent no-op, nothing written;
#   * never fails the caller     - a failing/unwritable memory write leaves the caller exit 0.
#
# The write is a detached background process, so "did a candidate land" is observed by POLLING the
# fixture registry. FIXTURE REGISTRY ONLY: every case points MEM_REGISTRY_DIR at a per-case temp
# dir, so the canonical registry ($HOME/fleet/state/memory) is never touched. Every case also
# asserts the hook exits 0 - the never-fails-the-caller contract.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-postmortem-stow.sh"
TMP_ROOT=$(fm_test_tmproot fm-postmortem-stow)

# Poll for a proposed candidate carrying <task> in the fixture registry (bounded ~15s). The write
# is detached, so read-once would race it.
wait_for_candidate() { # <registry-dir> <task>
  local reg=$1 task=$2 f="$1/memory-registry.jsonl" _
  for _ in $(seq 1 40); do
    if [ -f "$f" ] && grep -Fq "\"$task\"" "$f" 2>/dev/null; then return 0; fi
    command sleep 0.3 2>/dev/null || true
  done
  return 1
}

# Assert no registry file ever appears within a short settle window.
assert_no_registry() { # <registry-dir> <msg>
  command sleep 1 2>/dev/null || true
  [ ! -f "$1/memory-registry.jsonl" ] || fail "$2"
}

# Build a per-case home with a data/<task>/report.md so distillation has real material.
make_case() { # <name> <task> -> echoes "<home>|<registry-dir>|<report>"
  local name=$1 task=$2 home reg report
  home="$TMP_ROOT/$name/home"
  reg="$TMP_ROOT/$name/reg"
  report="$home/data/$task/report.md"
  mkdir -p "$home/config" "$home/data/$task"
  {
    printf '# %s report\n\n' "$task"
    printf '## What worked\nclean fast-forward, no conflicts.\n\n'
    printf '## Sharp edges\nthe pool clone lagged origin; used the authoritative base.\n'
  } > "$report"
  printf '%s|%s|%s' "$home" "$reg" "$report"
}

# --- gated-off inert --------------------------------------------------------------
test_gated_off_inert() {
  local c home reg report rc
  c=$(make_case gatedoff off-1); home=${c%%|*}; reg=$(printf '%s' "$c" | cut -d'|' -f2); report=${c##*|}
  env -u FM_POSTMORTEM_STOW -u MEM_CLI MEM_REGISTRY_DIR="$reg" FM_HOME="$home" \
    "$HOOK" --task off-1 --kind scout --project firstmate --report "$report"
  rc=$?
  expect_code 0 "$rc" "gated-off hook must exit 0"
  assert_no_registry "$reg" "with no ambient gate and no config file, nothing must be written"
  pass "gated-off (no env, no file) -> inert, exit 0"
}

# --- chokepoint fires + fixture registry only + propose-not-activate --------------
test_env_gate_fires_candidate() {
  local c home reg report rc regfile
  c=$(make_case envon ship-1); home=${c%%|*}; reg=$(printf '%s' "$c" | cut -d'|' -f2); report=${c##*|}
  env -u MEM_CLI FM_POSTMORTEM_STOW=1 MEM_REGISTRY_DIR="$reg" FM_HOME="$home" \
    "$HOOK" --task ship-1 --kind ship --project firstmate --mode local-only --outcome landed \
      --report "$report" --sha deadbeefcafe --pr https://github.com/o/r/pull/7
  rc=$?
  expect_code 0 "$rc" "gate-on hook must exit 0"
  wait_for_candidate "$reg" ship-1 || fail "env FM_POSTMORTEM_STOW=1 must land a postmortem candidate"
  regfile="$reg/memory-registry.jsonl"
  assert_grep '"event":"proposed"' "$regfile" "the record must be PROPOSED (a candidate), never activated"
  assert_no_grep '"event":"activated"' "$regfile" "the hook must never auto-activate (curated activation stands)"
  assert_grep '"type":"source-type","ref":"task-postmortem"' "$regfile" "source_type=task-postmortem provenance must be recorded"
  assert_grep '"type":"task","ref":"ship-1"' "$regfile" "task provenance must be recorded"
  assert_grep '"type":"sha","ref":"deadbeefcafe"' "$regfile" "SHA provenance must be recorded"
  assert_grep '"type":"pr","ref":"https://github.com/o/r/pull/7"' "$regfile" "PR provenance must be recorded"
  assert_grep '"confidence":"unverified"' "$regfile" "a fresh postmortem candidate must be unverified"
  # propose-not-auto-activate: the record is a candidate, so the fold reports 0 active.
  MEM_REGISTRY_DIR="$reg" node "$ROOT/memory/bin/mem.mjs" audit 2>/dev/null | grep -q '0 active' \
    || fail "the candidate must not be active (propose lifecycle: activation stays curated)"
  pass "env gate on -> candidate lands in fixture registry with provenance, 0 active"
}

# --- file-gated on ----------------------------------------------------------------
test_file_gate_fires() {
  local c home reg report rc
  c=$(make_case fileon scout-9); home=${c%%|*}; reg=$(printf '%s' "$c" | cut -d'|' -f2); report=${c##*|}
  # The registry override travels in the gate file itself, exactly as cp-shadow's data-dir does.
  cat > "$home/config/postmortem-stow.env" <<EOF
# firstmate operational enable for postmortem capture
FM_POSTMORTEM_STOW=1
MEM_REGISTRY_DIR=$reg
EOF
  env -u FM_POSTMORTEM_STOW -u MEM_REGISTRY_DIR -u MEM_CLI FM_HOME="$home" \
    "$HOOK" --task scout-9 --kind scout --project firstmate --report "$report"
  rc=$?
  expect_code 0 "$rc" "file-gated hook must exit 0"
  wait_for_candidate "$reg" scout-9 || fail "config FM_POSTMORTEM_STOW=1 must land a candidate in the file's registry"
  pass "file-gated (config FM_POSTMORTEM_STOW=1 + MEM_REGISTRY_DIR) -> candidate lands"
}

test_ambient_off_suppresses_file() {
  local c home reg report rc
  c=$(make_case ambientoff off-2); home=${c%%|*}; reg=$(printf '%s' "$c" | cut -d'|' -f2); report=${c##*|}
  printf 'FM_POSTMORTEM_STOW=1\nMEM_REGISTRY_DIR=%s\n' "$reg" > "$home/config/postmortem-stow.env"
  env -u MEM_CLI FM_POSTMORTEM_STOW=0 MEM_REGISTRY_DIR="$reg" FM_HOME="$home" \
    "$HOOK" --task off-2 --kind ship --project firstmate --report "$report"
  rc=$?
  expect_code 0 "$rc" "ambient-off hook must exit 0"
  assert_no_registry "$reg" "an explicit ambient FM_POSTMORTEM_STOW=0 must suppress the file and stay inert"
  pass "ambient FM_POSTMORTEM_STOW=0 -> file not consulted, inert"
}

# --- malformed / unreadable gate file never fails the caller ----------------------
test_malformed_gate_never_fails() {
  local c home reg rc
  c=$(make_case malformed off-3); home=${c%%|*}; reg=$(printf '%s' "$c" | cut -d'|' -f2)
  {
    printf 'not a key=value line at all\n'
    printf '=leadingequals\n'
    printf 'FM_POSTMORTEM_STOW\n'          # no '=' -> ignored
    printf 'SOMETHING_ELSE=whatever\n'     # unknown key -> ignored
    printf '\x01\x02\x03 garbage \xff\n'
    printf 'no trailing newline here'
  } > "$home/config/postmortem-stow.env"
  env -u FM_POSTMORTEM_STOW -u MEM_REGISTRY_DIR -u MEM_CLI FM_HOME="$home" \
    "$HOOK" --task off-3 --kind ship
  rc=$?
  expect_code 0 "$rc" "a malformed gate file must never fail the caller"
  pass "malformed gate file -> ignored, caller exit 0, inert"
}

test_unreadable_gate_never_fails() {
  local c home reg rc
  c=$(make_case unreadable off-4); home=${c%%|*}; reg=$(printf '%s' "$c" | cut -d'|' -f2)
  printf 'FM_POSTMORTEM_STOW=1\n' > "$home/config/postmortem-stow.env"
  chmod 000 "$home/config/postmortem-stow.env"
  if [ -r "$home/config/postmortem-stow.env" ]; then
    chmod 700 "$home/config/postmortem-stow.env"
    pass "unreadable-gate case SKIPPED (file still readable; likely running as root)"
    return 0
  fi
  env -u FM_POSTMORTEM_STOW -u MEM_REGISTRY_DIR -u MEM_CLI FM_HOME="$home" \
    "$HOOK" --task off-4 --kind ship
  rc=$?
  chmod 700 "$home/config/postmortem-stow.env"
  expect_code 0 "$rc" "an unreadable gate file must never fail the caller (exit 0)"
  pass "unreadable gate file -> inert, exit 0 (never fails the caller)"
}

# --- inert when memory is unavailable ---------------------------------------------
test_inert_when_memory_absent() {
  local c home reg report rc altbin
  c=$(make_case memabsent ship-2); home=${c%%|*}; reg=$(printf '%s' "$c" | cut -d'|' -f2); report=${c##*|}
  # Run a COPY of the hook from a bin dir with NO sibling memory/ package. The hook resolves its
  # package relative to its own location, so mem.mjs is then absent -> memory unavailable -> inert.
  # (MEM_CLI is unset, so it cannot fall back to a CLI override.)
  altbin="$TMP_ROOT/memabsent/altroot/bin"
  mkdir -p "$altbin"
  cp "$HOOK" "$altbin/fm-postmortem-stow.sh"
  [ -e "$TMP_ROOT/memabsent/altroot/memory/bin/mem.mjs" ] && fail "test setup: alt root must not ship the memory package"
  env -u MEM_CLI FM_POSTMORTEM_STOW=1 MEM_REGISTRY_DIR="$reg" FM_HOME="$home" \
    "$altbin/fm-postmortem-stow.sh" --task ship-2 --kind ship --project firstmate --report "$report"
  rc=$?
  expect_code 0 "$rc" "memory-unavailable hook must exit 0"
  assert_no_registry "$reg" "with no resolvable memory CLI the hook must write nothing (inert)"
  pass "no resolvable memory CLI -> inert, exit 0 (memory unavailable)"
}

# --- never fails the caller when the memory write itself fails --------------------
test_never_fails_on_write_failure() {
  local c home reg report rc
  c=$(make_case writefail ship-3); home=${c%%|*}; reg=$(printf '%s' "$c" | cut -d'|' -f2); report=${c##*|}
  # A memory CLI that always fails: the backgrounded write exits non-zero, but the detached call
  # can never propagate to the caller. No candidate lands, and the caller still exits 0.
  env FM_POSTMORTEM_STOW=1 MEM_REGISTRY_DIR="$reg" MEM_CLI="/bin/false" FM_HOME="$home" \
    "$HOOK" --task ship-3 --kind ship --project firstmate --report "$report"
  rc=$?
  expect_code 0 "$rc" "a failing memory write must never fail the caller"
  assert_no_registry "$reg" "a failing memory write leaves no candidate (and never fails the caller)"
  pass "failing memory write -> caller exit 0, no candidate (never fails the closeout)"
}

test_gated_off_inert
test_env_gate_fires_candidate
test_file_gate_fires
test_ambient_off_suppresses_file
test_malformed_gate_never_fails
test_unreadable_gate_never_fails
test_inert_when_memory_absent
test_never_fails_on_write_failure
