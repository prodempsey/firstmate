#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's CANONICAL TRUNK to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward onto the declared canonical
# trunk. See AGENTS.md prime directives, project management, and task lifecycle.
#
# THE GATE IS CLOSED, NOT ADVISORY. The merge target is not guessed from
# origin/HEAD-or-main any more: it is the canonical trunk DECLARED in the
# firstmate home's config/canonical-trunk.json (bin/fm-trunk-check.sh owns the
# declaration and the verification; docs/configuration.md owns the schema). This
# script refuses - never warns - when:
#   * there is no declaration for the project, or it is malformed (absence is an
#     error, never a pass);
#   * the canonical trunk invariant is already violated (the serving lineage is
#     ahead of, or divergent from, trunk) - converge before landing more;
#   * the task's project path is NOT the declared trunk checkout, e.g. a landing
#     aimed at the serving worktree. That is the exact recurrence this gate
#     exists to stop: firstmate landed a branch into the serving checkout out of
#     habit, trunk fell behind, and nothing detected it. A warning here is what
#     firstmate would have blown past;
#   * the landing would leave canonical trunk behind or divergent from the
#     serving lineage.
# It never repairs anything: it names the exact fix and exits non-zero. The only
# ref it ever moves is the declared trunk, by a clean fast-forward, after every
# check above has passed.
#
# Usage: fm-merge-local.sh <task-id>
# Exit:  0 merged (or already landed), 1 refused, 2 declaration/verification error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-role-context-lib.sh
. "$SCRIPT_DIR/fm-role-context-lib.sh"
fm_require_primary "fm-merge-local.sh (local merge)" || exit 2
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "error: jq not found; the canonical-trunk declaration cannot be read" >&2; exit 2; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

TRUNK_CHECK="$SCRIPT_DIR/fm-trunk-check.sh"
BRANCH="fm/$ID"

realpath_of() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
# The shared git object store behind a checkout, resolved to an absolute real path,
# so two worktrees of one repo compare equal.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$dir" && cd "$common" && pwd -P)
}
PROJ_ABS=$(realpath_of "$PROJ")

# Which declared project is this task landing into? Resolve by REPOSITORY, not by
# path: a landing aimed at the serving worktree is still a landing in that
# project's repo, and it must be refused with that project's canonical trunk
# named - not dismissed as an unknown project. Prefer an exact trunk-checkout
# match, then any declared project sharing this checkout's git object store, then
# the directory name (the registry name in data/projects.md).
ALL=$("$TRUNK_CHECK" --all --json 2>/dev/null || true)
NAME=$(printf '%s' "$ALL" | jq -r --arg p "$PROJ_ABS" '.projects[]? | select(.trunk.checkout == $p) | .project' 2>/dev/null | head -1)
if [ -z "$NAME" ]; then
  PROJ_COMMON=$(common_dir_of "$PROJ_ABS" || true)
  if [ -n "$PROJ_COMMON" ]; then
    for candidate in $(printf '%s' "$ALL" | jq -r '.projects[]? | select(.declared) | .project' 2>/dev/null); do
      cand_checkout=$(printf '%s' "$ALL" | jq -r --arg c "$candidate" '.projects[] | select(.project == $c) | .trunk.checkout' 2>/dev/null)
      [ -n "$cand_checkout" ] || continue
      if [ "$(common_dir_of "$cand_checkout" || echo none)" = "$PROJ_COMMON" ]; then
        NAME=$candidate
        break
      fi
    done
  fi
fi
[ -n "$NAME" ] || NAME=$(basename "$PROJ_ABS")

# THE DECLARATION GATE. A missing or malformed declaration, an unreadable serving
# lineage, or an already-violated invariant all stop the landing here.
REPORT=$("$TRUNK_CHECK" "$NAME" --json 2>/dev/null || true)
STATUS=$(printf '%s' "$REPORT" | jq -r '.status // "error"' 2>/dev/null || echo error)
case "$STATUS" in
  error)
    echo "REFUSED: cannot land $BRANCH - the canonical trunk of '$NAME' is not verifiable." >&2
    "$TRUNK_CHECK" "$NAME" >/dev/null || true   # re-run for the human report on stderr
    exit 2 ;;
  drift)
    {
      echo "REFUSED: cannot land $BRANCH - the canonical trunk invariant for '$NAME' is ALREADY violated."
      echo "Converge trunk and the serving lineage first; landing more work on top compounds the drift."
    } >&2
    "$TRUNK_CHECK" "$NAME" >/dev/null || true
    exit 1 ;;
esac

TRUNK_BRANCH=$(printf '%s' "$REPORT" | jq -r '.projects[0].trunk.branch')
TRUNK_CHECKOUT=$(printf '%s' "$REPORT" | jq -r '.projects[0].trunk.checkout')
TRUNK_SHA=$(printf '%s' "$REPORT" | jq -r '.projects[0].trunk.sha')
SERVING_SHA=$(printf '%s' "$REPORT" | jq -r '.projects[0].serving.sha // ""')
SERVING_BRANCH=$(printf '%s' "$REPORT" | jq -r '.projects[0].serving.branch // ""')
TRUNK_ABS=$(realpath_of "$TRUNK_CHECKOUT")

# THE RECURRENCE GATE: the landing must target canonical trunk itself. A task whose
# project path is the serving worktree (or any other checkout of the repo) is the
# exact habit that moved serving ahead of trunk twice.
if [ "$PROJ_ABS" != "$TRUNK_ABS" ]; then
  {
    echo "REFUSED: task $ID targets $PROJ_ABS, which is NOT the canonical trunk checkout of '$NAME'."
    echo "Canonical trunk is '$TRUNK_BRANCH' in $TRUNK_ABS (declared, not guessed)."
    if [ "$(common_dir_of "$PROJ_ABS" || echo proj)" = "$(common_dir_of "$TRUNK_ABS" || echo trunk)" ]; then
      echo "That path is another checkout of the same repo - landing there moves the serving lineage"
      echo "ahead of trunk and leaves trunk silently behind. That is the drift this gate exists to stop."
    fi
    echo "Fix: point the task's project= at $TRUNK_ABS (state/$ID.meta) and land on '$TRUNK_BRANCH'."
  } >&2
  exit 1
fi

git -C "$TRUNK_ABS" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
  || { echo "error: branch $BRANCH does not exist in $TRUNK_ABS" >&2; exit 1; }

# The trunk checkout must be on canonical trunk and clean, so the fast-forward
# lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$TRUNK_ABS" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$TRUNK_BRANCH" ] || {
  echo "REFUSED: $TRUNK_ABS is on '$cur', not canonical trunk '$TRUNK_BRANCH'; cannot merge safely." >&2
  echo "Fix: git -C $TRUNK_ABS checkout $TRUNK_BRANCH" >&2
  exit 1
}
if [ -n "$(git -C "$TRUNK_ABS" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "REFUSED: $TRUNK_ABS has a dirty working tree; refusing to merge into it." >&2
  exit 1
fi

BRANCH_SHA=$(git -C "$TRUNK_ABS" rev-parse --verify "refs/heads/$BRANCH")

# Already landed: the branch's work is contained in trunk. This is a no-op success,
# not a refusal - re-running the gate after a merge must not read as a failure.
if git -C "$TRUNK_ABS" merge-base --is-ancestor "$BRANCH_SHA" "$TRUNK_SHA"; then
  echo "already landed: $BRANCH is contained in $TRUNK_BRANCH ($(git -C "$TRUNK_ABS" rev-parse --short "$TRUNK_SHA")) in $TRUNK_ABS"
  exit 0
fi

# Clean fast-forward only: canonical trunk must be an ancestor of the branch.
if ! git -C "$TRUNK_ABS" merge-base --is-ancestor "$TRUNK_SHA" "$BRANCH_SHA"; then
  {
    echo "REFUSED: $BRANCH is not a fast-forward of canonical trunk '$TRUNK_BRANCH' (it has diverged)."
    echo "Fix: have the crewmate rebase $BRANCH onto $TRUNK_BRANCH, then retry."
  } >&2
  exit 1
fi

# THE INVARIANT, PROJECTED ONTO THE LANDING: after this merge, trunk will be at the
# branch tip, so the serving commit must be equal to or an ancestor of that tip. If
# the serving lineage holds commits this branch does not, landing would leave trunk
# behind or divergent from what is actually running - refuse, and name the fix.
if [ -n "$SERVING_SHA" ]; then
  if ! git -C "$TRUNK_ABS" cat-file -e "$SERVING_SHA^{commit}" 2>/dev/null \
     || ! git -C "$TRUNK_ABS" merge-base --is-ancestor "$SERVING_SHA" "$BRANCH_SHA"; then
    {
      echo "REFUSED: landing $BRANCH would leave canonical trunk '$TRUNK_BRANCH' behind the serving lineage."
      echo "Serving is at ${SERVING_SHA:0:12}${SERVING_BRANCH:+ ($SERVING_BRANCH)}, which is not contained in $BRANCH."
      echo "Fix: land the serving lineage on '$TRUNK_BRANCH' first, then rebase $BRANCH onto it and retry."
    } >&2
    exit 1
  fi
fi

# Destructive-merge backstop (bug-20260714043857-416f07b4).
#
# Fast-forward-only is NOT enough to make this merge safe. A branch built on a
# base that is missing part of canonical trunk - a stale pool worktree, or a base
# that predates local-only commits - carries a tree where those files simply do
# not exist. If such a branch is later made an ancestor-descendant of trunk (a
# merge that keeps the branch's tree, for instance), git will happily
# fast-forward trunk to it and the missing files are silently DELETED. That
# is how a nine-file change presented as 19,666 deletions across 154 files.
#
# So: every file this merge would delete must have been deleted DELIBERATELY, by
# one of the branch's own commits. Cumulative deletions ($TRUNK_BRANCH..$BRANCH)
# that no branch commit ever recorded are collateral from a bad base, and they
# are refused. --no-renames on both sides so a rename reads as delete+add
# consistently and never lands in one set but not the other. Merge commits
# contribute no diff to `git log` without -m, so a tree-swallowing merge commit
# can never launder a deletion into the "intended" set - conservative by design.
#
# The failure modes are deliberately asymmetric: a false refusal costs one manual
# review, a false accept costs the fleet its tooling.
deleted_all=$(git -C "$TRUNK_ABS" diff --no-renames --diff-filter=D --name-only "$TRUNK_BRANCH..$BRANCH")
if [ -n "$deleted_all" ]; then
  deleted_intended=$(git -C "$TRUNK_ABS" log --no-renames --diff-filter=D --name-only --pretty=format: "$TRUNK_BRANCH..$BRANCH" | sed '/^$/d' | sort -u)
  collateral=$(printf '%s\n' "$deleted_all" | sort -u | comm -23 - <(printf '%s\n' "$deleted_intended"))
  if [ -n "$collateral" ]; then
    count=$(printf '%s\n' "$collateral" | wc -l | tr -d ' ')
    echo "REFUSED: merging $BRANCH into canonical trunk '$TRUNK_BRANCH' would delete $count tracked file(s) that no commit on $BRANCH ever touched." >&2
    echo "This is the signature of a branch built on a base that is missing part of $TRUNK_BRANCH: those files are absent from the branch's base, so the merge reads as deleting them. Merging would erase them from $TRUNK_BRANCH." >&2
    echo "Files that would be deleted without any branch commit deleting them:" >&2
    printf '%s\n' "$collateral" | head -20 | sed 's/^/  /' >&2
    if [ "$count" -gt 20 ]; then
      echo "  ... and $((count - 20)) more" >&2
    fi
    echo "Have the crewmate re-base $BRANCH onto the current $TRUNK_BRANCH (keeping only its intended changes), then retry. If these deletions really are intended, land them as an explicit commit on $BRANCH that deletes them." >&2
    exit 1
  fi
fi

before=$(git -C "$TRUNK_ABS" rev-parse --short "$TRUNK_BRANCH")
git -C "$TRUNK_ABS" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$TRUNK_ABS" rev-parse --short "$TRUNK_BRANCH")
after_full=$(git -C "$TRUNK_ABS" rev-parse "$TRUNK_BRANCH")
if ! "$SCRIPT_DIR/fm-task-events.sh" "$ID" landed "merged into local $TRUNK_BRANCH" "$BRANCH" local-only "$after_full" >/dev/null; then
  printf 'blocked: merge landed at %s but durable closure evidence write failed for %s\n' "$after_full" "$ID" >&2
  exit 1
fi
echo "merged $BRANCH into canonical trunk $TRUNK_BRANCH ($before -> $after) in $TRUNK_ABS"

# A local-only merge is a ship completion with no PR and no CI, so this is the only
# moment the work lands. It can clear a blocker or resolve a bug before teardown runs.
"$SCRIPT_DIR/fm-triage-duty.sh" ship-complete --detail "$ID landed on local $TRUNK_BRANCH in $TRUNK_ABS." || true

# Post-merge state, reported not repaired: the serving lineage is now behind trunk
# until it is redeployed, which is the tolerable direction of the invariant.
"$TRUNK_CHECK" "$NAME" >/dev/null || true
