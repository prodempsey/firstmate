#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

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

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# Destructive-merge backstop (bug-20260714043857-416f07b4).
#
# Fast-forward-only is NOT enough to make this merge safe. A branch built on a
# base that is missing part of $DEFAULT - a stale pool worktree, or a base that
# predates local-only commits - carries a tree where those files simply do not
# exist. If such a branch is later made an ancestor-descendant of $DEFAULT (a
# merge that keeps the branch's tree, for instance), git will happily
# fast-forward $DEFAULT to it and the missing files are silently DELETED. That
# is how a nine-file change presented as 19,666 deletions across 154 files.
#
# So: every file this merge would delete must have been deleted DELIBERATELY, by
# one of the branch's own commits. Cumulative deletions ($DEFAULT..$BRANCH) that
# no branch commit ever recorded are collateral from a bad base, and they are
# refused. --no-renames on both sides so a rename reads as delete+add
# consistently and never lands in one set but not the other. Merge commits
# contribute no diff to `git log` without -m, so a tree-swallowing merge commit
# can never launder a deletion into the "intended" set - conservative by design.
#
# The failure modes are deliberately asymmetric: a false refusal costs one manual
# review, a false accept costs the fleet its tooling.
deleted_all=$(git -C "$PROJ" diff --no-renames --diff-filter=D --name-only "$DEFAULT..$BRANCH")
if [ -n "$deleted_all" ]; then
  deleted_intended=$(git -C "$PROJ" log --no-renames --diff-filter=D --name-only --pretty=format: "$DEFAULT..$BRANCH" | sed '/^$/d' | sort -u)
  collateral=$(printf '%s\n' "$deleted_all" | sort -u | comm -23 - <(printf '%s\n' "$deleted_intended"))
  if [ -n "$collateral" ]; then
    count=$(printf '%s\n' "$collateral" | wc -l | tr -d ' ')
    echo "REFUSED: merging $BRANCH into $DEFAULT would delete $count tracked file(s) that no commit on $BRANCH ever touched." >&2
    echo "This is the signature of a branch built on a base that is missing part of $DEFAULT: those files are absent from the branch's base, so the merge reads as deleting them. Merging would erase them from $DEFAULT." >&2
    echo "Files that would be deleted without any branch commit deleting them:" >&2
    printf '%s\n' "$collateral" | head -20 | sed 's/^/  /' >&2
    if [ "$count" -gt 20 ]; then
      echo "  ... and $((count - 20)) more" >&2
    fi
    echo "Have the crewmate re-base $BRANCH onto the current $DEFAULT (keeping only its intended changes), then retry. If these deletions really are intended, land them as an explicit commit on $BRANCH that deletes them." >&2
    exit 1
  fi
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
after_full=$(git -C "$PROJ" rev-parse "$DEFAULT")
if ! "$SCRIPT_DIR/fm-task-events.sh" "$ID" landed "merged into local $DEFAULT" "$BRANCH" local-only "$after_full" >/dev/null; then
  printf 'blocked: merge landed at %s but durable closure evidence write failed for %s\n' "$after_full" "$ID" >&2
  exit 1
fi
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

# A local-only merge is a ship completion with no PR and no CI, so this is the only
# moment the work lands. It can clear a blocker or resolve a bug before teardown runs.
"$SCRIPT_DIR/fm-triage-duty.sh" ship-complete --detail "$ID landed on local $DEFAULT in $PROJ." || true
