#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Dispatch-recall (Seasoning stage B) is ON by default for real fm-spawn
# dispatch, so a spawn test that keeps node on PATH would otherwise recall against
# the operator's PRODUCTION memory registry ($HOME/fleet/state/memory) and write a
# proof sidecar into its brief dir. Pin it OFF for the general suite so every
# unrelated spawn/brief test stays byte-identical, fast, and can never read or write
# production memory. The dispatch-recall path is exercised deliberately in
# tests/fm-memory-inject.test.sh, which unsets this (to test the intrinsic default)
# or forces it on, always against an isolated fixture registry (MEM_REGISTRY_DIR).
export FM_MEMORY_INJECT=0

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir that is removed when the test
# process ends, however it ends.
#
# Ownership is recorded in the root itself, not in shell state. Every call site
# spells `TMP_ROOT=$(fm_test_tmproot ...)`, and a command substitution is a
# SUBSHELL: an array append or a `trap` installed inside fm_test_tmproot would
# die with that subshell and never reach the test process. (That was the old
# bug: the registry was always empty in the parent, no EXIT trap was ever
# installed there, and every run of every suite leaked its whole temp root -
# invisibly, because tests mkdir -p their fixtures back into existence.)
#
# So instead each root carries an FM_TEST_OWNER_MARKER file naming the owning
# process, and cleanup finds its roots by reading those markers. That survives
# subshells, and it is also what lets bin/fm-test-tmp-sweep.sh reclaim roots
# orphaned by a SIGKILL, which no trap can ever catch.
#
# The traps below are installed at source time - i.e. in the test process, not
# in a subshell - and cover the signals that ARE catchable. A test file needing
# extra teardown (e.g. killing a daemon) may install its own EXIT trap and call
# fm_test_cleanup from inside it; cleanup is idempotent.

FM_TEST_OWNER_MARKER=.fm-test-owner

# Identity of the owning test process. $$ is the test process even when read
# from inside a subshell, which is exactly the property the marker needs.
FM_TEST_OWNER_PID=$$
FM_TEST_SESSION="$$-${EPOCHSECONDS:-$(date +%s)}-${RANDOM}"
FM_TEST_SUITE=$(basename -- "${0:-unknown}")
export FM_TEST_OWNER_PID FM_TEST_SESSION FM_TEST_SUITE

# Retained for backward compatibility: suites may still register extra dirs.
FM_TEST_CLEANUP_DIRS=()

# fm_test_cleanup: remove every temp root owned by THIS test process (matched by
# session token, so a recycled pid can never make us delete someone else's root)
# plus any explicitly registered dirs. Safe to call more than once.
fm_test_cleanup() {
  local d marker session
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  for d in "${TMPDIR:-/tmp}"/*/; do
    marker="${d%/}/$FM_TEST_OWNER_MARKER"
    [ -f "$marker" ] || continue
    session=$(sed -n 's/^session=//p' "$marker" 2>/dev/null)
    [ "$session" = "$FM_TEST_SESSION" ] && rm -rf "${d%/}"
  done
  return 0
}

# fm_test_signal_cleanup <signal-name> <exit-code>: clean up, then die with the
# conventional 128+signo so a killed suite still reports as killed.
fm_test_signal_cleanup() {
  local sig=$1 code=$2
  fm_test_cleanup
  trap - "$sig"
  exit "$code"
}

# EXIT covers normal and error exits; INT/TERM/HUP cover the catchable kills a
# timeout, a harness interrupt, or a crew teardown sends. SIGKILL cannot be
# trapped by anything, which is why the sweep exists.
trap fm_test_cleanup EXIT
trap 'fm_test_signal_cleanup INT 130' INT
trap 'fm_test_signal_cleanup TERM 143' TERM
trap 'fm_test_signal_cleanup HUP 129' HUP

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  {
    printf 'session=%s\n' "$FM_TEST_SESSION"
    printf 'pid=%s\n' "$FM_TEST_OWNER_PID"
    printf 'suite=%s\n' "$FM_TEST_SUITE"
    printf 'started=%s\n' "${EPOCHSECONDS:-$(date +%s)}"
  } > "$root/$FM_TEST_OWNER_MARKER"
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- pre-flight headroom guard ----------------------------------------------
#
# fm_test_require_tmp_headroom [min_free_inodes] [min_free_mb]: refuse to start a
# heavy suite on a TMPDIR that is already near exhaustion. Without this, a suite
# that seeds firstmate homes finishes the job the last leak started and takes the
# whole box down with ENOSPC - including writes that must never fail, like the
# captain order inbox. A stale-root sweep is attempted first, so the common case
# (our own orphans from an earlier kill) self-heals instead of failing.

fm_test_require_tmp_headroom() {
  local min_inodes=${1:-50000} min_mb=${2:-2000} tmp="${TMPDIR:-/tmp}" swept=
  local free_inodes free_mb attempt

  for attempt in 1 2; do
    free_inodes=$(df -Pi "$tmp" 2>/dev/null | awk 'NR==2 {print $4}')
    free_mb=$(df -Pk "$tmp" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
    # A df we cannot parse is not evidence of trouble; do not block the suite.
    [ -n "${free_inodes:-}" ] && [ -n "${free_mb:-}" ] || return 0
    if [ "$free_inodes" -ge "$min_inodes" ] && [ "$free_mb" -ge "$min_mb" ]; then
      return 0
    fi
    [ "$attempt" -eq 2 ] && break
    swept=$("$ROOT/bin/fm-test-tmp-sweep.sh" --tmpdir "$tmp" 2>/dev/null) || true
  done

  printf 'not ok - %s: refusing to run, %s is near exhaustion\n' "$FM_TEST_SUITE" "$tmp" >&2
  printf '  free inodes: %s (need %s)\n  free space: %sMB (need %sMB)\n' \
    "$free_inodes" "$min_inodes" "$free_mb" "$min_mb" >&2
  [ -n "$swept" ] && printf '  sweep reclaimed:\n%s\n' "$swept" >&2
  printf '  this suite seeds firstmate homes; running it now would exhaust %s.\n' "$tmp" >&2
  printf '  free space, then re-run. bin/fm-test-tmp-sweep.sh reclaims orphaned test roots.\n' >&2
  exit 1
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
