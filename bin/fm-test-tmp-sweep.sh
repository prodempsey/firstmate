#!/usr/bin/env bash
# Reclaim temp roots orphaned by firstmate's own test suites.
#
# tests/lib.sh cleans up on EXIT INT TERM HUP, but SIGKILL cannot be trapped by
# anything, and a `kill -9`, an OOM kill, a timeout's final blow, or a crew
# teardown that terminates the process group leaves the whole root behind. The
# secondmate suites seed real firstmate homes into that root (hundreds of MB and
# thousands of inodes each), so a handful of orphans is enough to exhaust /tmp -
# it did, on 2026-07-13, and every write on the box began failing with ENOSPC,
# including the captain order inbox write that must never fail.
#
# A sweep is the only mechanism that can recover from a SIGKILL, so this runs at
# session start (bin/fm-bootstrap.sh) and reports what it reclaimed. It never
# sweeps silently.
#
# Staleness is proven, never assumed. A root is reclaimed only when:
#   - it carries a .fm-test-owner marker written by tests/lib.sh, AND
#   - the owning process is gone (a live owner is ALWAYS left alone, and a pid we
#     cannot conclusively call dead counts as alive), AND
#   - it has not been modified for --min-age-seconds (default 600).
# Deleting a root out from under a running test would corrupt that test, so every
# uncertain case biases toward leaving it alone.
#
# Legacy roots predating the marker are recognized only by the two unambiguous
# suite prefixes below, and only after FM_TEST_SWEEP_LEGACY_MIN_AGE (default 24h).
# Nothing else in TMPDIR is ever touched: runtime temp dirs are not test roots.
#
# Usage: fm-test-tmp-sweep.sh [--tmpdir <dir>] [--min-age-seconds <n>] [--dry-run]
# Prints one line per root acted on (reclaimed / would-reclaim / kept-live) and
# nothing at all when there is nothing to report. Exit 0 unless usage is wrong.
set -eu

MARKER=.fm-test-owner
TMP_DIR=${TMPDIR:-/tmp}
MIN_AGE=${FM_TEST_SWEEP_MIN_AGE:-600}
LEGACY_MIN_AGE=${FM_TEST_SWEEP_LEGACY_MIN_AGE:-86400}
DRY_RUN=0

# Markerless roots from before tests/lib.sh recorded ownership. Both prefixes are
# test-only and cannot collide with a runtime temp dir.
LEGACY_PREFIXES="fm-secondmate-safety fm-secondmate-lifecycle"

while [ $# -gt 0 ]; do
  case "$1" in
    --tmpdir) shift; TMP_DIR=${1:?--tmpdir needs a dir} ;;
    --min-age-seconds) shift; MIN_AGE=${1:?--min-age-seconds needs a number} ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$TMP_DIR" ] || exit 0

now=$(date +%s)

# pid_alive <pid>: true unless the process is provably gone. A pid owned by
# another user (kill -0 fails with EPERM) is alive, and an unparseable pid is
# treated as alive, because a false "dead" here destroys a running test.
pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  ps -p "$pid" >/dev/null 2>&1 && return 0
  kill -0 "$pid" 2>/dev/null && return 0
  return 1
}

age_of() {
  local path=$1 mtime
  mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo "$now")
  echo $(( now - mtime ))
}

# Size is reported, not decided on: the captain needs the reclaimed footprint.
footprint_of() {
  local root=$1 kb inodes
  kb=$(du -sk "$root" 2>/dev/null | cut -f1)
  inodes=$(find "$root" 2>/dev/null | wc -l)
  printf '%sMB, %s files' "$(( ${kb:-0} / 1024 ))" "$(( inodes ))"
}

reclaim() {
  local root=$1 why=$2 footprint
  footprint=$(footprint_of "$root")
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would-reclaim %s (%s; %s)\n' "$root" "$why" "$footprint"
    return 0
  fi
  rm -rf "$root" 2>/dev/null || {
    printf 'kept %s (reclaim failed)\n' "$root"
    return 0
  }
  printf 'reclaimed %s (%s; %s)\n' "$root" "$why" "$footprint"
}

is_legacy_root() {
  local base=$1 prefix
  for prefix in $LEGACY_PREFIXES; do
    case "$base" in
      "$prefix".*) return 0 ;;
    esac
  done
  return 1
}

for dir in "$TMP_DIR"/*/; do
  root=${dir%/}
  [ -d "$root" ] || continue
  base=$(basename -- "$root")
  age=$(age_of "$root")

  if [ -f "$root/$MARKER" ]; then
    pid=$(sed -n 's/^pid=//p' "$root/$MARKER" 2>/dev/null | head -1)
    suite=$(sed -n 's/^suite=//p' "$root/$MARKER" 2>/dev/null | head -1)
    if pid_alive "$pid"; then
      # Age is not proof of staleness: a slow suite can outlive any threshold.
      # The owner is running, so this root is in use. Leave it alone.
      printf 'kept %s (owner pid %s of %s still alive)\n' "$root" "$pid" "${suite:-unknown suite}"
      continue
    fi
    [ "$age" -ge "$MIN_AGE" ] || continue
    reclaim "$root" "orphaned by ${suite:-unknown suite}, owner pid ${pid:-?} gone, idle ${age}s"
    continue
  fi

  if is_legacy_root "$base" && [ "$age" -ge "$LEGACY_MIN_AGE" ]; then
    reclaim "$root" "legacy unowned test root, idle ${age}s"
  fi
done
