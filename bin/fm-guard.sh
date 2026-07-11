#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode when another session holds the fleet lock.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud, clearly delimited
# banner so the agent cannot skim past it in the tool output of whatever it was
# doing - the one channel every harness has. Normal wake handling (watcher
# briefly down between a wake and the next supervision resume) stays inside the
# grace window and stays silent. Always exits 0: the guard warns, it never
# blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to the session holding the fleet lock.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# --- Fleet-triage supervision preflight, checked SECOND and also independent of
# in-flight tasks. -------------------------------------------------------------------
# A deterministic, cheap check that a return to silent supervision is not walking past
# actionable work nobody owns. This reads the LAST recorded bin/fm-triage-duty.sh pass
# (state/.triage-duty-last.json, a small cache written by that script) rather than
# re-running the read-only enumerator here - fm-guard.sh runs on every wake, and
# re-enumerating on every guard check would pay the full snapshot/NF/bug/ledger cost far
# more often than any actual fleet-state change. The duty script is what keeps this
# cache fresh; this is purely a deterministic file read. Banner-only: it never blocks,
# and it fires independent of in-flight task count because ownerless triage items (a
# bug, an unreconciled report, a captain-gated backlog row) are fleet-wide, not tied to
# whether any task happens to be in flight right now.
triage_last="$STATE/.triage-duty-last.json"
if [ -f "$triage_last" ] && command -v jq >/dev/null 2>&1; then
  # jq's `//` treats `false` as no-value (same as null), so a plain `.ok // empty`
  # would silently discard a genuine `ok: false` failure record. Read it with
  # `tostring` instead so false survives.
  triage_ok=$(jq -r '.ok | tostring' "$triage_last" 2>/dev/null)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  if [ "$triage_ok" = false ]; then
    t_trigger=$(jq -r '.trigger // "unknown"' "$triage_last" 2>/dev/null)
    t_ts=$(jq -r '.ts // "unknown"' "$triage_last" 2>/dev/null)
    t_err=$(jq -r '.error // "unknown error"' "$triage_last" 2>/dev/null)
    {
      printf '●%s\n' "$trule"
      printf '●  FLEET TRIAGE DUTY - LAST PASS FAILED TO ENUMERATE\n'
      printf '●  The %s pass at %s did not complete: %s\n' "$t_trigger" "$t_ts" "$t_err"
      printf '●  Fleet-triage visibility may be stale until this is fixed.\n'
      printf '●  Investigate directly: bin/fm-fleet-triage.sh --json\n'
      printf '●%s\n' "$trule"
    } >&2
  elif [ "$triage_ok" = true ]; then
    t_ownerless=$(jq -r '.ownerless // 0' "$triage_last" 2>/dev/null)
    case "$t_ownerless" in ''|*[!0-9]*) t_ownerless=0 ;; esac
    if [ "$t_ownerless" -gt 0 ]; then
      t_actionable=$(jq -r '.actionable // 0' "$triage_last" 2>/dev/null)
      t_captain_gated=$(jq -r '.captain_gated // 0' "$triage_last" 2>/dev/null)
      t_trigger=$(jq -r '.trigger // "unknown"' "$triage_last" 2>/dev/null)
      t_ts=$(jq -r '.ts // "unknown"' "$triage_last" 2>/dev/null)
      {
        printf '●%s\n' "$trule"
        printf '●  FLEET TRIAGE ATTENTION - RETURNING TO SUPERVISION WITH OWNERLESS WORK\n'
        printf '●  %s of %s actionable item(s) have no owner (%s captain-gated), as of the\n' "$t_ownerless" "$t_actionable" "$t_captain_gated"
        printf '●  %s pass at %s.\n' "$t_trigger" "$t_ts"
        if [ "$READ_ONLY" -eq 1 ]; then
          printf '●  This read-only session cannot record dispositions; the session holding the\n'
          printf '●  fleet lock owns this.\n'
        else
          printf '●  Load the fleet-triage skill and disposition them with\n'
          printf '●  bin/fm-fleet-triage-record.sh before going quiet.\n'
        fi
        printf '●%s\n' "$trule"
      } >&2
    fi
  fi
fi

# Compute in-flight count and watcher-beacon freshness via the shared
# grace-based predicate (bin/fm-supervision-lib.sh). Only act with tasks in
# flight; count them so the banner can say how much is riding on an absent
# watcher.
fm_supervision_status "$STATE" "$GRACE"
in_flight=$FM_SUP_IN_FLIGHT
watcher_fresh=$FM_SUP_WATCHER_FRESH
beacon_desc=$FM_SUP_BEACON_DESC
[ "$in_flight" -eq 0 ] && exit 0

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line.
if [ "$watcher_fresh" = false ]; then
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  queue_arg=0
  "$queue_pending" && queue_arg=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
    --read-only "$READ_ONLY" \
    --afk "$afk" \
    --x-mode "$x_mode" \
    --queue-pending "$queue_arg" \
    --repair-line 2>/dev/null || printf '%s\n' 'Resume supervision according to the session-start operating block.')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  WATCHER DOWN - SUPERVISION IS OFF\n'
    printf '●  %s task(s) in flight, but no watcher has a fresh beacon (last beat: %s, grace %ss).\n' "$in_flight" "$beacon_desc" "$GRACE"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session should report the lapse, not repair it.\n'
    else
      printf '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.\n'
    fi
    printf '●  %s\n' "$CONTINUE_LINE"
    printf '●  %s\n' "$fix"
    printf '●%s\n' "$rule"
  } >&2
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched for the session holding the fleet lock." >&2
  else
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
