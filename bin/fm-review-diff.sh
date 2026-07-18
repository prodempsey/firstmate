#!/usr/bin/env bash
# Review a crewmate branch against the base the work will actually land on.
#
# The base is chosen by the task's DELIVERY MODE, not by whether an origin remote
# happens to exist: a review that compares against a base nobody will merge into
# is worse than useless. A local-only task lands on the project's LOCAL default
# branch (bin/fm-merge-local.sh fast-forwards it), so that is its base even when
# the project also has an origin whose default branch is a different lineage -
# diffing such a task against origin/<default> reports the whole lineage gap as
# the change set and hides what actually changed. A PR-based task (no-mistakes,
# direct-PR) lands on origin/<default> via the merged PR, so that ref is its base
# and is fetched fresh, because pooled clones keep stale local default refs.
#
# The mode comes from mode= in state/<id>.meta (recorded by fm-spawn), falling
# back to the data/projects.md registry. If the mode - and therefore the landing
# base - cannot be resolved, this script FAILS LOUDLY rather than guessing a base:
# a confidently wrong diff is the failure this tool exists to prevent.
#
# When state/<id>.meta records pr= for an open PR, the compare side is the PR
# head (recorded pr_head= when reachable, else refs/pull/<n>/head) so review
# stays current after no-mistakes fix rounds push to the PR; if the PR head
# cannot be resolved, the script falls back to the local branch with a warning.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  n=$(pr_number_from_target "$pr_url") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  # Fetch into a PRIVATE, task-scoped ref rather than reading FETCH_HEAD. FETCH_HEAD
  # is a single shared ref per repository, so a concurrent `git fetch` in the same
  # object store (another task, fleet-sync, teardown, a human) can overwrite it
  # between the fetch and the read - yielding the wrong commit and a confidently
  # wrong diff, the exact failure this tool exists to prevent. A ref named for this
  # task ID is written atomically by the fetch and read back by name, immune to any
  # other fetch racing FETCH_HEAD.
  local priv="refs/fm-review/$ID/pr-head"
  git -C "$WT" fetch --quiet origin "+refs/pull/$n/head:$priv" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify "$priv^{commit}" 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

# The landing base follows the delivery mode. mode= in meta is authoritative;
# the registry is the fallback for a meta written before fm-spawn recorded it.
mode_from_registry() {
  local out mode
  out=$("$FM_ROOT/bin/fm-project-mode.sh" "$(basename "$PROJ")" 2>&1 || true)
  # fm-project-mode.sh warns and defaults to no-mistakes for an unknown project;
  # that default is a guess, and a guessed base is exactly what must not happen.
  case "$out" in *'warn:'*) return 1 ;; esac
  mode=$(printf '%s\n' "$out" | tail -1 | cut -d' ' -f1)
  [ -n "$mode" ] || return 1
  printf '%s' "$mode"
}

MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -z "$MODE" ]; then
  MODE=$(mode_from_registry) || {
    echo "error: cannot resolve the delivery mode for task $ID, so the base it would land on is unknown." >&2
    echo "       $META records no mode=, and $(basename "$PROJ") is not in the project registry." >&2
    echo "       Refusing to diff against a guessed base; add mode=<no-mistakes|direct-PR|local-only> to the meta or register the project." >&2
    exit 1
  }
fi

case "$MODE" in
  local-only)
    # fm-merge-local.sh fast-forwards the project's LOCAL default branch, so that
    # branch - not origin/<default>, which may be an entirely different lineage -
    # is what this work merges into.
    BASE="refs/heads/$DEFAULT"
    BASE_LABEL="$DEFAULT (local)"
    git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || {
      echo "error: task $ID is mode=local-only, so it lands on the local branch $DEFAULT, but $DEFAULT does not exist in $PROJ." >&2
      echo "       Refusing to diff against a base the merge will not use." >&2
      exit 1
    }
    ;;
  no-mistakes|direct-PR)
    # The PR merges into the remote default branch, so that is the base.
    git -C "$PROJ" remote get-url origin >/dev/null 2>&1 || {
      echo "error: task $ID is mode=$MODE (lands via a PR into origin/$DEFAULT), but $PROJ has no origin remote." >&2
      echo "       Refusing to diff against a guessed base; fix the project remote or correct the task's mode=." >&2
      exit 1
    }
    # Update the remote-tracking ref itself; a bare single-branch fetch can leave
    # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
    git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet || {
      echo "error: cannot fetch origin/$DEFAULT for task $ID; the base its PR would merge into is unknown." >&2
      echo "       Refusing to diff against a possibly stale base." >&2
      exit 1
    }
    BASE="refs/remotes/origin/$DEFAULT"
    BASE_LABEL="origin/$DEFAULT"
    git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || {
      echo "error: base origin/$DEFAULT does not exist in $WT after fetching it." >&2
      exit 1
    }
    ;;
  *)
    echo "error: task $ID records mode=$MODE, which is not a reviewable ship mode; the base it would land on is unknown." >&2
    echo "       Expected no-mistakes, direct-PR, or local-only. Refusing to diff against a guessed base." >&2
    exit 1
    ;;
esac

git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE_LABEL (mode=$MODE)"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE_LABEL"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "$BASE...$COMPARE_REF" --
fi
