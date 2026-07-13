#!/usr/bin/env bash
# Reclaim leaked treehouse worktree leases: free the pool slots still held by
# tasks that no longer exist, and PARK - never free - the ones that still hold work.
#
# THE LEAK
# treehouse leases are durable by design and are released only by an explicit
# `treehouse return` (bin/fm-teardown.sh does that on the normal path). A crewmate
# whose agent dies, is killed, or is abandoned never reaches teardown, so its slot
# stays leased forever; `treehouse prune` will not take it either, because prune
# skips anything with an owner reservation. The pool fills with ghosts until it hits
# exhaustion and blocks all new dispatch. This script is the abnormal path.
#
# THE RULE, in one line: a lease is freed only when its owner is provably gone AND
# its worktree provably holds nothing. Everything else is parked and reported.
# bin/fm-lease-lib.sh owns that safety model in full - read its header before
# changing any classification here. Freeing a lease runs `treehouse return --force`,
# which cleans and resets the worktree, so a false reclaim DESTROYS UNLANDED WORK.
# Parking is always the safe answer and every ambiguity resolves to it.
#
# --force is required on the return (the bare form prompts, and would hang a
# non-interactive session-start sweep). It is safe here only because it runs
# exclusively on a worktree already proven clean and landed - never on a parked one.
#
# Parked leases are re-reported on every run rather than escalating themselves:
# freeing them is a captain decision (AGENTS.md prime directive #3), so they stay
# loud until the captain rules on them. That also makes this idempotent - a second
# run sees reclaimed slots as available and re-parks the same held ones.
#
# Usage: fm-lease-reclaim.sh [--dry-run] [--project <dir>]...
#   --dry-run     classify and report only; never return a lease.
#   --project     sweep this project's pool (repeatable). Default: every project
#                 clone under this home's projects dir, plus every distinct
#                 project= recorded in this home's task meta.
# Prints "LEASE_RECLAIM: ..." lines. Silent when no dead lease was found, matching
# the bootstrap convention that silence means all good. Always exits 0 unless the
# arguments are unusable, so a pool problem can never block session start.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

DRY_RUN=0
EXPLICIT_PROJECTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --project)
      [ $# -ge 2 ] || { echo "usage: fm-lease-reclaim.sh [--dry-run] [--project <dir>]..." >&2; exit 2; }
      EXPLICIT_PROJECTS+=("$2")
      shift
      ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *) echo "usage: fm-lease-reclaim.sh [--dry-run] [--project <dir>]..." >&2; exit 2 ;;
  esac
  shift
done

command -v treehouse >/dev/null 2>&1 || exit 0

say() { printf 'LEASE_RECLAIM: %s\n' "$1"; }

# Pool discovery. A treehouse pool is per backing repo, and `treehouse status`
# resolves it from the working directory, so we need the project dirs. Take the
# union of this home's project clones and every project referenced by a task meta:
# the clones cover the standard layout, and the meta paths cover a fleet whose
# projects live outside $FM_HOME/projects. --project overrides both.
candidate_projects() {
  local d meta p
  if [ "${#EXPLICIT_PROJECTS[@]}" -gt 0 ]; then
    printf '%s\n' "${EXPLICIT_PROJECTS[@]}"
    return 0
  fi
  if [ -d "$PROJECTS" ]; then
    for d in "$PROJECTS"/*; do
      [ -d "$d" ] && printf '%s\n' "$d"
    done
  fi
  if [ -d "$STATE" ]; then
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      p=$(grep '^project=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$p" ] && printf '%s\n' "$p"
    done
  fi
}

# Resolve to real dirs that are git repos, deduped.
resolve_projects() {
  local p abs
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    abs=$(cd "$p" 2>/dev/null && pwd -P) || continue
    git -C "$abs" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    printf '%s\n' "$abs"
  done < <(candidate_projects) | sort -u
}

# Paths this sweep must never consider, whatever a pool says about them: the
# primary checkout, the worktree this script is running from, and every registered
# secondmate home (a persistent home is leased under its own id and is retired only
# by an explicit teardown - AGENTS.md section 7).
protected_paths() {
  local home
  printf '%s\n' "$FM_ROOT"
  (cd "$SCRIPT_DIR/.." && pwd -P)
  while IFS='|' read -r _ home _ _; do
    [ -n "$home" ] && printf '%s\n' "$home"
  done < <(live_secondmate_meta_records "$STATE" "$FM_HOME/data/secondmates.md")
  if [ -f "$FM_HOME/data/secondmates.md" ]; then
    sed -n 's/^[^(]*(home:[[:space:]]*\([^;)]*\);.*/\1/p' "$FM_HOME/data/secondmates.md" | sed 's/[[:space:]]*$//'
  fi
}

PROTECTED=$(protected_paths | sed '/^$/d' | sort -u || true)
is_protected() {
  local p=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$p" ] && return 0
  done <<< "$PROTECTED"
  return 1
}

STATE_DIRS=()
while IFS= read -r sd; do
  [ -n "$sd" ] && STATE_DIRS+=("$sd")
done < <(fm_lease_state_dirs "$FM_HOME" | sed '/^$/d' | sort -u)

TOTAL_RECLAIMED=0
TOTAL_PARKED=0

sweep_project() {
  local proj=$1 status_out label rec path holder procs verdict reason disp
  local reclaimed=0 parked=0 header_done=0

  status_out=$( (cd "$proj" && treehouse status) 2>/dev/null ) || {
    # No pool for this project, or treehouse could not read it. Not an error:
    # most projects have no pool at all.
    return 0
  }

  label=$(basename "$proj")

  while IFS=$'\t' read -r path holder procs; do
    [ -n "$path" ] || continue
    fm_lease_holder_is_ours "$holder" || continue
    path=$(fm_lease_expand_tilde "$path")
    is_protected "$path" && continue
    fm_lease_owner_is_dead "$holder" "$path" "$procs" "${STATE_DIRS[@]}" || continue

    disp=$(fm_lease_disposition "$path" "$proj")
    verdict=${disp%%$'\t'*}
    reason=${disp#*$'\t'}

    if [ "$header_done" -eq 0 ]; then
      say "pool $label: dead leases found"
      header_done=1
    fi

    if [ "$verdict" = park ]; then
      parked=$((parked + 1))
      say "  PARKED $holder $path: $reason"
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      reclaimed=$((reclaimed + 1))
      say "  would reclaim $holder $path: $reason"
      continue
    fi

    if (cd "$proj" && treehouse return --force "$path") >/dev/null 2>&1; then
      reclaimed=$((reclaimed + 1))
      say "  reclaimed $holder $path: $reason"
    else
      parked=$((parked + 1))
      say "  PARKED $holder $path: treehouse return failed; lease still held"
    fi
  done < <(printf '%s\n' "$status_out" | fm_lease_parse_status)

  if [ "$header_done" -eq 1 ]; then
    say "pool $label: reclaimed $reclaimed, parked $parked"
  fi
  TOTAL_RECLAIMED=$((TOTAL_RECLAIMED + reclaimed))
  TOTAL_PARKED=$((TOTAL_PARKED + parked))
}

while IFS= read -r project; do
  [ -n "$project" ] || continue
  sweep_project "$project"
done < <(resolve_projects)

if [ "$TOTAL_PARKED" -gt 0 ]; then
  say "$TOTAL_PARKED parked lease(s) still hold work and need the captain's decision; nothing was discarded"
fi

exit 0
