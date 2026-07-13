# shellcheck shell=bash
# Shared treehouse lease-reclamation logic.
# Usage: . bin/fm-lease-lib.sh   (after FM_ROOT and FM_HOME are set)
#
# WHY THIS EXISTS
# treehouse leases are durable BY DESIGN. From `treehouse get --help`: a leased
# worktree "is never handed out by a later get and never removed by prune, even
# with no process running inside it, until you release it with 'treehouse return
# <path>'". bin/fm-teardown.sh is that release, and it is the normal path. But a
# crewmate whose agent dies, is killed, or is abandoned never reaches teardown, so
# its lease is held forever and NOTHING reclaims it - not even `treehouse prune`,
# which skips anything with an owner reservation. Over days the pool silently
# fills with slots held by tasks that no longer exist until it hits exhaustion and
# blocks all new dispatch. This library is the ABNORMAL path: it identifies leases
# whose owning task is provably gone and frees only the ones that provably hold no
# work.
#
# THE SAFETY MODEL (read before changing anything here)
# Returning a lease runs `treehouse return --force`, which CLEANS AND RESETS the
# worktree. On a lease that still holds work, that is destruction of unlanded work
# - the exact thing AGENTS.md prime directive #3 forbids without the captain's
# explicit word. So the bar for touching a lease is deliberately asymmetric:
#
#   A false "park" costs one noisy report line. A false "reclaim" destroys work.
#
# Every ambiguity therefore resolves to park. Two independent signals must BOTH say
# the owner is gone before a lease is even considered dead, and the worktree must
# then independently prove it holds nothing:
#
#   1. DEAD OWNER (fm_lease_owner_is_dead): treehouse reports no live process in
#      the slot, AND no state/<id>.meta records the task in this firstmate home or
#      in any registered secondmate home. Either signal alone means LIVE.
#      - The process check covers the cross-home case: a secondmate's crew, or a
#        crew from a home we cannot see, still shows its agent process. An idle
#        secondmate and a long-paused crew both keep their agent process alive, so
#        both read as LIVE here - which is exactly right, since an idle pane is
#        healthy (AGENTS.md section 8).
#      - The meta check covers the crashed-agent case: a task whose agent died but
#        whose meta still exists is firstmate's to recover or tear down, NOT ours
#        to reclaim. Reclaiming it would destroy the worktree recovery needs.
#      Both are matched by holder id AND by worktree path, so a drifted holder
#      label cannot make a live task look like an orphan.
#
#   2. NO WORK (fm_lease_disposition): the worktree is clean (by teardown's own
#      dirty definition) and its HEAD content is already contained in the project's
#      default branch or reachable from a remote. Anything else parks.
#
# The landed check is deliberately OFFLINE: no fetch, no gh/PR lookup, unlike
# bin/fm-teardown.sh's richer work_is_landed. Reclamation runs at session start and
# must be fast and network-independent, and the failure mode of a stale local
# default branch is a park, never a false reclaim. Teardown remains the authority
# for landed work on the normal path; this is the conservative subset.

# fm_lease_expand_tilde <path>: `treehouse status` prints ~-relative paths, so the
# tildes below are LITERAL match patterns for that output, not shell expansions -
# we do the expanding here.
# shellcheck disable=SC2088
fm_lease_expand_tilde() {
  case "$1" in
    '~') printf '%s\n' "$HOME" ;;
    '~/'*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# fm_lease_parse_status: read `treehouse status` on stdin, emit one TAB-delimited
# record per LEASED slot: <path>\t<holder>\t<procs|noprocs>.
#
# The parsed shape, which is treehouse's public CLI surface:
#   2     leased       ~/.treehouse/pool/2/repo  (held by fm-console-start-guard-x2)
#   1     leased       ~/.treehouse/pool/1/repo  (held by fm-inspector-a1)
#                      bash (1017480), claude (1017872)
#   7     available    ~/.treehouse/pool/7/repo
# A record line starts with the slot number; any following non-blank line that is
# not a record line is that slot's live-process list. Available slots and leases we
# cannot parse a holder or path out of are dropped rather than guessed at, so a
# format change can only ever make us reclaim LESS, never more.
fm_lease_parse_status() {
  awk '
    function emit() {
      if (have) printf "%s\t%s\t%s\n", path, holder, (procs ? "procs" : "noprocs")
    }
    /^[ \t]*[0-9]+[ \t]+[a-zA-Z]/ {
      emit()
      have = 0; procs = 0; holder = ""
      state = $2; path = $3
      if (match($0, /\(held by [^)]+\)/))
        holder = substr($0, RSTART + 9, RLENGTH - 10)
      if (state == "leased" && holder != "" && path != "")
        have = 1
      next
    }
    { if (have && $0 ~ /[^ \t]/) procs = 1 }
    END { emit() }
  '
}

# fm_lease_holder_task_id <holder>: firstmate leases are held under the task's
# window label, fm-<id>. A holder without that prefix is not ours; callers skip it.
fm_lease_holder_task_id() {
  printf '%s\n' "${1#fm-}"
}

fm_lease_holder_is_ours() {
  case "$1" in
    fm-?*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_lease_state_dirs <fm-home>: every state dir whose meta files can vouch for a
# lease - this home's, plus each registered secondmate home's. A secondmate's crews
# lease from the same per-project pool but record their meta in the SECONDMATE's
# state dir, so a main-home-only check would see them as orphans (AGENTS.md
# section 5: another home's children are not this home's orphans).
fm_lease_state_dirs() {
  local home=$1 state rec smhome
  state="${FM_STATE_OVERRIDE:-$home/state}"
  printf '%s\n' "$state"
  [ -d "$state" ] || return 0
  while IFS='|' read -r _ smhome _ _; do
    [ -n "$smhome" ] || continue
    [ -d "$smhome/state" ] || continue
    printf '%s\n' "$smhome/state"
  done < <(live_secondmate_meta_records "$state" "$home/data/secondmates.md")
  # Registry backstop: a secondmate whose meta was lost still owns its home's work.
  if [ -f "$home/data/secondmates.md" ]; then
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      [ -d "$rec/state" ] || continue
      printf '%s\n' "$rec/state"
    done < <(sed -n 's/^[^(]*(home:[[:space:]]*\([^;)]*\);.*/\1/p' "$home/data/secondmates.md" | sed 's/[[:space:]]*$//')
  fi
}

# fm_lease_task_is_recorded <holder> <worktree> <state-dir>...: does ANY known home
# still have a task record for this lease? Matched by BOTH the holder's task id and
# the worktree path, so a drifted or relabelled holder cannot orphan a live task.
fm_lease_task_is_recorded() {
  local holder=$1 wt=$2 id state meta
  shift 2
  id=$(fm_lease_holder_task_id "$holder")
  for state in "$@"; do
    [ -d "$state" ] || continue
    [ -n "$id" ] && [ -f "$state/$id.meta" ] && return 0
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      grep -qxF "worktree=$wt" "$meta" 2>/dev/null && return 0
    done
  done
  return 1
}

# fm_lease_owner_is_dead <holder> <worktree> <procs-field> <state-dir>...
# Both independent signals must say gone. Anything else is LIVE.
fm_lease_owner_is_dead() {
  local holder=$1 wt=$2 procs=$3
  shift 3
  [ "$procs" = noprocs ] || return 1
  fm_lease_task_is_recorded "$holder" "$wt" "$@" && return 1
  return 0
}

fm_lease_default_branch() {
  local proj=$1 ref branch
  ref=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# fm_lease_content_in_default <worktree> <project>: is HEAD's content already in the
# project's default branch? Mirrors bin/fm-teardown.sh's content_in_default (merging
# HEAD into the default yields the default's own tree => it adds nothing), minus the
# fetch: see the offline note in the header. Prefers the remote-tracking default,
# falling back to the local one, so a pooled clone's frozen local ref cannot alone
# decide the answer.
fm_lease_content_in_default() {
  local wt=$1 proj=$2 name ref default_tree merged_tree
  name=$(fm_lease_default_branch "$proj") || return 1
  if git -C "$wt" rev-parse --quiet --verify "refs/remotes/origin/$name" >/dev/null 2>&1; then
    ref="refs/remotes/origin/$name"
  elif git -C "$wt" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# fm_lease_disposition <worktree> <project>: emits "<reclaim|park>\t<reason>".
# Called ONLY for a lease whose owner is already proven dead. This is the second,
# independent gate: it decides whether that dead lease holds work. Every failure to
# inspect - a missing git dir, an index.lock, a corrupt repo - parks, because we
# cannot prove the worktree is empty and `treehouse return --force` would reset it.
# The dirty definition matches teardown's, including its ignore list for the crew
# harness droppings (.claude/, .fm-grok-turnend) that are not the captain's work;
# without that, every dead lease would look dirty and nothing would ever be freed.
fm_lease_disposition() {
  local wt=$1 proj=$2 dirty_raw dirty unpushed n

  if [ ! -d "$wt" ]; then
    printf 'reclaim\tworktree path is gone; no work can be present\n'
    return 0
  fi
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'park\tnot an inspectable git worktree; refusing to guess\n'
    return 0
  fi
  if ! dirty_raw=$(git -C "$wt" status --porcelain 2>/dev/null); then
    printf 'park\tcannot inspect for uncommitted changes\n'
    return 0
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | sed '/^$/d' || true)
  if [ -n "$dirty" ]; then
    n=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')
    printf 'park\tUNCOMMITTED CHANGES (%s path(s)) - never auto-returned\n' "$n"
    return 0
  fi
  if ! unpushed=$(git -C "$wt" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    printf 'park\tcannot inspect commits\n'
    return 0
  fi
  unpushed=$(printf '%s\n' "$unpushed" | sed '/^$/d')
  if [ -z "$unpushed" ]; then
    printf 'reclaim\tclean; every commit is reachable from a remote\n'
    return 0
  fi
  if fm_lease_content_in_default "$wt" "$proj"; then
    printf 'reclaim\tclean; work already contained in the default branch\n'
    return 0
  fi
  n=$(printf '%s\n' "$unpushed" | wc -l | tr -d ' ')
  printf 'park\tUNLANDED WORK (%s commit(s) on no remote, not in the default branch) - never auto-returned\n' "$n"
  return 0
}
