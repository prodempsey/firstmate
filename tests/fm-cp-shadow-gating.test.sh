#!/usr/bin/env bash
# Colocated tests for the FILE GATE added to bin/fm-cp-shadow.sh (ORD-267 slice).
#
# Env-only gating (CP_SHADOW=1 exported in a bashrc) silently no-ops in a non-interactive
# shell that never sourced it, so lifecycle actions went unmirrored. The hook now also reads
# FM_HOME/config/cp-shadow.env when CP_SHADOW is UNSET in the environment. These tests pin the
# four behaviours the slice must preserve:
#   * gated-off inert          - no ambient CP_SHADOW, no config file -> the mirror never fires;
#   * file-gated on            - config file CP_SHADOW=1 -> the mirror fires with the file's
#                                exported values and the caller's args passed through;
#   * ambient-env precedence   - an ambient value always wins over the file (and an ambient
#                                CP_SHADOW=0 suppresses the file entirely);
#   * malformed never fails    - a garbage config file leaves the caller's exit status 0.
#
# The mirror is a detached background process, so "did it fire" is observed by shimming a fake
# `node` onto PATH that records its env+args to a marker file, then polling for that marker.
# The real control-plane/bin/cp-shadow.mjs is never run; only the hook's gate logic is under
# test. Every case also asserts the hook itself exits 0 - the never-fails-the-caller contract.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-cp-shadow.sh"
TMP_ROOT=$(fm_test_tmproot fm-cp-shadow-gating)

# A fake `node` that records the environment the hook exported and the args it forwarded, then
# exits. The marker path travels in via CP_SHADOW_TEST_MARKER (the hook passes the whole
# environment through to the mirror child, so the shim inherits it).
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/node" <<'SH'
#!/usr/bin/env bash
# argv: <cp-shadow.mjs path> <forwarded hook args...>
shift  # drop the script path; keep only the forwarded action args
{
  printf 'ARGS=%s\n' "$*"
  printf 'CP_SHADOW=%s\n' "${CP_SHADOW-<unset>}"
  printf 'CP_SHADOW_DATA_DIR=%s\n' "${CP_SHADOW_DATA_DIR-<unset>}"
  printf 'CP_ORDER_SOURCE_PATH=%s\n' "${CP_ORDER_SOURCE_PATH-<unset>}"
  printf 'CP_SHADOW_DIVERGENCE=%s\n' "${CP_SHADOW_DIVERGENCE-<unset>}"
} > "$CP_SHADOW_TEST_MARKER"
exit 0
SH
chmod +x "$FAKEBIN/node"

# Poll for the marker (the mirror is detached). Bounded ~10s.
wait_for_marker() { # <path>
  local m=$1 _
  for _ in $(seq 1 40); do
    [ -f "$m" ] && return 0
    command sleep 0.25 2>/dev/null || true
  done
  return 1
}

# Assert the marker never appears within a short settle window.
assert_no_marker() { # <path> <msg>
  command sleep 1 2>/dev/null || true
  [ ! -f "$1" ] || fail "$2"
}

# Run the hook for a named case with a controlled home. Echoes the hook's exit code. The
# caller sets any ambient CP_* vars in its own shell before calling; we pass a per-case
# marker path and PATH shim. FM_HOME points at the case home so config/cp-shadow.env resolves.
make_home() { # <name> -> echoes home dir
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/config"
  printf '%s' "$home"
}

pass_line() { pass "$1"; }

# --- gated-off inert --------------------------------------------------------------
test_gated_off_inert() {
  local home marker rc
  home=$(make_home gatedoff)          # no config/cp-shadow.env written
  marker="$TMP_ROOT/gatedoff/marker"
  # No ambient CP_SHADOW, no file -> inert.
  env -u CP_SHADOW -u CP_SHADOW_DATA_DIR -u CP_ORDER_SOURCE_PATH -u CP_SHADOW_DIVERGENCE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" CP_SHADOW_TEST_MARKER="$marker" \
    "$HOOK" status --task t1 --status working
  rc=$?
  expect_code 0 "$rc" "gated-off hook must exit 0"
  assert_no_marker "$marker" "with no ambient CP_SHADOW and no config file the mirror must not fire"
  pass_line "gated-off (no env, no file) -> inert, exit 0"
}

# --- file-gated on ----------------------------------------------------------------
test_file_gated_on() {
  local home marker rc
  home=$(make_home filegated)
  marker="$TMP_ROOT/filegated/marker"
  cat > "$home/config/cp-shadow.env" <<EOF
# firstmate operational enable for the CW2 shadow run
CP_SHADOW=1
CP_SHADOW_DATA_DIR=$home/store/pgdata
CP_ORDER_SOURCE_PATH=$home/orders.md
CP_SHADOW_DIVERGENCE=$home/divergence.jsonl
EOF
  env -u CP_SHADOW -u CP_SHADOW_DATA_DIR -u CP_ORDER_SOURCE_PATH -u CP_SHADOW_DIVERGENCE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" CP_SHADOW_TEST_MARKER="$marker" \
    "$HOOK" status --task t2 --status working
  rc=$?
  expect_code 0 "$rc" "file-gated hook must exit 0"
  wait_for_marker "$marker" || fail "config CP_SHADOW=1 must let the mirror fire"
  assert_grep "CP_SHADOW=1" "$marker" "the file's CP_SHADOW must be exported to the mirror"
  assert_grep "CP_SHADOW_DATA_DIR=$home/store/pgdata" "$marker" "the file's data dir must be exported"
  assert_grep "CP_ORDER_SOURCE_PATH=$home/orders.md" "$marker" "the file's order source must be exported"
  assert_grep "CP_SHADOW_DIVERGENCE=$home/divergence.jsonl" "$marker" "the file's divergence path must be exported"
  assert_grep "ARGS=status --task t2 --status working" "$marker" "the caller's action args must pass through unchanged"
  pass_line "file-gated (config CP_SHADOW=1) -> mirror fires with exported values + args"
}

# --- ambient-env precedence -------------------------------------------------------
test_ambient_off_suppresses_file() {
  local home marker rc
  home=$(make_home ambientoff)
  marker="$TMP_ROOT/ambientoff/marker"
  # File would enable it, but an explicit ambient CP_SHADOW=0 wins and the file is never read.
  printf 'CP_SHADOW=1\nCP_SHADOW_DATA_DIR=%s/store\n' "$home" > "$home/config/cp-shadow.env"
  env -u CP_SHADOW_DATA_DIR -u CP_ORDER_SOURCE_PATH -u CP_SHADOW_DIVERGENCE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" CP_SHADOW_TEST_MARKER="$marker" CP_SHADOW=0 \
    "$HOOK" status --task t3 --status working
  rc=$?
  expect_code 0 "$rc" "ambient-off hook must exit 0"
  assert_no_marker "$marker" "an explicit ambient CP_SHADOW=0 must suppress the file and stay inert"
  pass_line "ambient CP_SHADOW=0 -> file not consulted, inert"
}

test_ambient_value_wins_per_key() {
  local home marker rc
  home=$(make_home ambientkey)
  marker="$TMP_ROOT/ambientkey/marker"
  # CP_SHADOW is unset ambiently (so the file IS read and turns the mirror on), but
  # CP_SHADOW_DATA_DIR is set ambiently and must beat the file's value for that key.
  printf 'CP_SHADOW=1\nCP_SHADOW_DATA_DIR=%s/from-file\n' "$home" > "$home/config/cp-shadow.env"
  env -u CP_SHADOW -u CP_ORDER_SOURCE_PATH -u CP_SHADOW_DIVERGENCE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" CP_SHADOW_TEST_MARKER="$marker" \
    CP_SHADOW_DATA_DIR="$home/from-ambient" \
    "$HOOK" status --task t4 --status working
  rc=$?
  expect_code 0 "$rc" "ambient-per-key hook must exit 0"
  wait_for_marker "$marker" || fail "file CP_SHADOW=1 should still enable the mirror"
  assert_grep "CP_SHADOW_DATA_DIR=$home/from-ambient" "$marker" "an ambient CP_SHADOW_DATA_DIR must win over the file"
  assert_no_grep "from-file" "$marker" "the file's data dir must not override an ambient one"
  pass_line "ambient CP_SHADOW_DATA_DIR wins over the file while file CP_SHADOW=1 still enables"
}

# --- malformed file never fails the caller ----------------------------------------
test_malformed_file_never_fails() {
  local home marker rc
  home=$(make_home malformed)
  marker="$TMP_ROOT/malformed/marker"
  # A deliberately hostile file: no '=' lines, a stray '=', an unrelated key, binary-ish junk,
  # a very long line, and no valid CP_SHADOW. The hook must ignore all of it and exit 0.
  {
    printf 'this is not a key=value line at all\n'
    printf '=leadingequals\n'
    printf 'CP_SHADOW\n'                       # no '=' -> ignored
    printf 'SOMETHING_ELSE=whatever\n'         # unknown key -> ignored
    printf 'CP_SHADOW_DATA_DIR\n'              # honoured key but no '=' -> ignored
    printf '\x01\x02\x03 garbage \xff\n'
    printf 'padding=%s\n' "$(head -c 5000 </dev/zero | tr '\0' x)"
    printf 'no trailing newline here'
  } > "$home/config/cp-shadow.env"
  env -u CP_SHADOW -u CP_SHADOW_DATA_DIR -u CP_ORDER_SOURCE_PATH -u CP_SHADOW_DIVERGENCE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" CP_SHADOW_TEST_MARKER="$marker" \
    "$HOOK" status --task t5 --status working
  rc=$?
  expect_code 0 "$rc" "a malformed config file must never fail the caller"
  assert_no_marker "$marker" "a malformed file with no valid CP_SHADOW=1 must stay inert"
  pass_line "malformed config file -> ignored, caller exit 0, inert"
}

test_malformed_plus_valid_still_enables() {
  local home marker rc
  home=$(make_home malformedon)
  marker="$TMP_ROOT/malformedon/marker"
  # Garbage lines around a single valid CP_SHADOW=1: the junk is skipped, the valid line wins.
  {
    printf 'garbage line one\n'
    printf 'CP_SHADOW=1\n'
    printf '\x00\x01 more junk\n'
    printf 'CP_SHADOW=0\n'                     # duplicate: first honoured value wins, stays 1
  } > "$home/config/cp-shadow.env"
  env -u CP_SHADOW -u CP_SHADOW_DATA_DIR -u CP_ORDER_SOURCE_PATH -u CP_SHADOW_DIVERGENCE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" CP_SHADOW_TEST_MARKER="$marker" \
    "$HOOK" status --task t6 --status working
  rc=$?
  expect_code 0 "$rc" "malformed+valid hook must exit 0"
  wait_for_marker "$marker" || fail "a valid CP_SHADOW=1 among junk must still enable the mirror"
  assert_grep "CP_SHADOW=1" "$marker" "the first valid CP_SHADOW value must win (1, not the later 0)"
  pass_line "malformed lines around a valid CP_SHADOW=1 -> mirror fires, first value wins"
}

test_gated_off_inert
test_file_gated_on
test_ambient_off_suppresses_file
test_ambient_value_wins_per_key
test_malformed_file_never_fails
test_malformed_plus_valid_still_enables
