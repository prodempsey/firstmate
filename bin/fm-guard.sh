#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode when another session holds the fleet lock.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then warn if a captain-gated order has no card in the Bridge's needs_human column,
# because a decision the captain cannot see is a decision that gets dropped.
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
WATCH="$SCRIPT_DIR/fm-watch.sh"
HARNESS=${FM_SUPERVISION_HARNESS:-}
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}
# ASCII unit separator, the repo's existing in-band field delimiter (see fm-marker-lib.sh).
# The dropped-captain-decision alarm below renders its jq result with this rather than a
# tab, because `read` collapses runs of IFS whitespace and would silently drop an empty
# field - a captain order with no linked task - shifting every field after it.
US=$'\x1f'

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
HARNESS=$(fm_supervision_primary_harness "$STATE" "$FM_HOME" "$HARNESS")
# The fm-harness.sh subprocess runs only when neither the durable record nor
# the ambient environment answers - never unconditionally on this hot path.
case "$HARNESS" in
  ''|unknown) HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown) ;;
esac

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
trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
triage_ok=''
triage_readable=false
# Read the cache's one gating field ONCE, here, because two alarms below consume it. jq's
# `//` treats `false` as no-value (same as null), so a plain `.ok // empty` would silently
# discard a genuine `ok: false` failure record. Read it with `tostring` so false survives.
if [ -f "$triage_last" ] && command -v jq >/dev/null 2>&1; then
  triage_readable=true
  triage_ok=$(jq -r '.ok | tostring' "$triage_last" 2>/dev/null)
fi
if [ "$triage_readable" = true ]; then
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

# --- Dropped-captain-decision alarm, checked THIRD and also independent of in-flight
# tasks. -------------------------------------------------------------------------------
# AGENTS.md section 9 requires every captain decision to be marked on the board before it is
# asked for in chat, and docs/captain-attention.md owns why. This is the detector for that
# rule: an unmarked decision is an unasked decision, and a rule that can be silently skipped
# eventually is. The rule tells firstmate what to do; this says so when it did not.
#
# WHAT IS PROVABLE. A card is keyed to an OPEN ITEM, so a captain-gated ORDER with no
# receipt is a decision the captain demonstrably cannot see. Captain-gated items in lanes
# with no open item (a standing visibility umbrella row) have nothing to key a card to, so
# they are named as context inside a firing banner and never alarm on their own: an alarm
# that fires forever on standing work is one nobody reads.
#
# CHEAP. Like the preflight above, this reads the cached last triage pass (its captain_gates
# block, recorded by bin/fm-triage-duty.sh) and one small append-only receipt ledger
# (state/.nf-to-captain, written by fm-nf-ack.sh only after the Bridge reads the card back).
# One jq invocation over two small local files. It never enumerates and never calls the
# Bridge, because fm-guard.sh runs on every single wake.
#
# READ-ONLY. It names the gap and prints the exact command; firstmate decides and marks.
# It must never route a decision to the captain's board itself: a false card on that board
# is worse than the bug this catches.
if [ -f "$triage_last" ] && [ "$triage_readable" = false ]; then
  # Could not check is not the same as all clear, and must never be reported as it.
  printf 'WARNING: cannot check for dropped captain decisions - jq is unavailable, so %s is unreadable.\n' \
    "$triage_last" >&2
elif [ "$triage_ok" = true ]; then
  gate_src=/dev/null
  [ -f "$STATE/.nf-to-captain" ] && gate_src="$STATE/.nf-to-captain"
  # One pass, emitting a tiny delimited rendering rather than JSON the shell would have to
  # re-enter jq to read. stdin is the receipt ledger (tab-separated, written by fm-nf-ack.sh);
  # --slurpfile is the triage cache.
  #
  # The rendering is separated by the ASCII unit separator, NOT by a tab: `read` treats tab
  # as IFS whitespace and collapses a run of them into one delimiter, so an order with no
  # linked task would silently shift its title into the task field and print a fix command
  # naming a task that does not exist. A non-whitespace delimiter preserves the empty field.
  gate_lines=$(jq -Rrn --arg us "$US" --slurpfile cache "$triage_last" '
    [inputs | split("\t")[0] | select(. != "")] as $marked
    | ($cache[0].captain_gates // null) as $g
    | if ($g | type) != "object" then ["STATE" + $us + "unavailable"]
      else
        # Bind the order before testing it: inside `$marked | index(...)` a bare .order_id
        # would be read against $marked (the receipt array), not against the order.
        (($g.orders // [])
         | map(. as $o | select(($marked | index($o.order_id)) == null))) as $unmarked
        | ["STATE" + $us + "ok",
           "COUNTS" + $us + (($g.orders_total // 0) | tostring)
                    + $us + ((($g.orders // []) | length) | tostring)
                    + $us + (($g.other_total // 0) | tostring)]
          + [$unmarked[]
             | "UNMARKED" + $us + .order_id + $us + (.task // "") + $us + (.title // "")]
          + [(($g.other // [])[])
             | "OTHER" + $us + .lane + $us + .source_id + $us + (.title // "")]
      end
    | .[]
  ' < "$gate_src" 2>/dev/null) || gate_lines="STATE${US}unavailable"

  gate_state=unavailable
  gate_orders_total=0 gate_orders_listed=0 gate_other_total=0
  gate_unmarked=()
  gate_other=()
  while IFS="$US" read -r kind f1 f2 f3; do
    case "$kind" in
      STATE) gate_state=$f1 ;;
      COUNTS) gate_orders_total=$f1; gate_orders_listed=$f2; gate_other_total=$f3 ;;
      UNMARKED) gate_unmarked+=("$f1$US$f2$US$f3") ;;
      OTHER) gate_other+=("$f1$US$f2$US$f3") ;;
    esac
  done <<EOF
$gate_lines
EOF
  # A corrupt cache must not turn an arithmetic comparison below into a shell error on a
  # wake. Same defense the ownerless count above uses.
  case "$gate_orders_total" in ''|*[!0-9]*) gate_orders_total=0 ;; esac
  case "$gate_orders_listed" in ''|*[!0-9]*) gate_orders_listed=0 ;; esac
  case "$gate_other_total" in ''|*[!0-9]*) gate_other_total=0 ;; esac

  if [ "$gate_state" != ok ]; then
    # The pass predates captain-gate recording (or wrote a null gate block). Missing
    # evidence, reported as missing - never folded into silence.
    printf 'WARNING: cannot check for dropped captain decisions - the last fleet-triage pass recorded no captain-gate detail; refresh it with bin/fm-triage-duty.sh session-start.\n' >&2
  elif [ "${#gate_unmarked[@]}" -gt 0 ]; then
    {
      printf '●%s\n' "$trule"
      printf '●  DROPPED CAPTAIN DECISION - GATED ON THE CAPTAIN, NOT ON HIS BOARD\n'
      printf '●  %s captain-gated order(s) have no card in the Bridge needs_human column, so the\n' "${#gate_unmarked[@]}"
      printf '●  captain cannot see that they are waiting on him. Escalating in chat alone is how\n'
      printf '●  a decision gets lost; the card is the only durable channel.\n'
      for row in "${gate_unmarked[@]}"; do
        IFS="$US" read -r g_order g_task g_title <<EOF
$row
EOF
        printf '●    %s: %s\n' "$g_order" "$(printf '%s' "$g_title" | cut -c1-90)"
        if [ -n "$g_task" ]; then
          printf '●      bin/fm-nf-ack.sh --to-captain %s %s\n' "$g_order" "$g_task"
        else
          printf '●      bin/fm-nf-ack.sh --to-captain %s <task-id>   (no linked task; link one first:\n' "$g_order"
          printf '●      bin/fm-order.sh link %s --task <id>)\n' "$g_order"
        fi
      done
      if [ "$gate_orders_total" -gt "$gate_orders_listed" ]; then
        printf '●  (%s of %s captain-gated orders listed; run bin/fm-fleet-triage.sh --json for the rest.)\n' \
          "$gate_orders_listed" "$gate_orders_total"
      fi
      if [ "$gate_other_total" -gt 0 ]; then
        printf '●  Also captain-gated, but with no open item to key a card to (record an order for\n'
        printf '●  one with bin/fm-order.sh add before it can reach the board):\n'
        for row in "${gate_other[@]}"; do
          IFS="$US" read -r g_lane g_src g_title <<EOF
$row
EOF
          printf '●    [%s] %s: %s\n' "$g_lane" "$g_src" "$(printf '%s' "$g_title" | cut -c1-70)"
        done
      fi
      if [ "$READ_ONLY" -eq 1 ]; then
        printf '●  This read-only session must not write the board; the session holding the fleet\n'
        printf '●  lock owns this.\n'
      else
        printf '●  %s\n' "$CONTINUE_LINE"
        printf '●  Mark each one, then tell the captain. Marking is yours; deciding is his.\n'
      fi
      printf '●%s\n' "$trule"
    } >&2
  fi
fi

# Compute in-flight count and watcher-beacon freshness via the shared
# grace-based predicate (bin/fm-supervision-lib.sh). Only act with tasks in
# flight; count them so the banner can say how much is riding on an absent
# watcher.
fm_supervision_health "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$HARNESS"
in_flight=$FM_SUP_IN_FLIGHT
supervision_healthy=$FM_SUP_HEALTHY
beacon_desc=$FM_SUP_BEACON_DESC
[ "$in_flight" -eq 0 ] && exit 0

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line.
if [ "$supervision_healthy" = false ]; then
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  queue_arg=0
  "$queue_pending" && queue_arg=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
    --harness "$HARNESS" \
    --read-only "$READ_ONLY" \
    --afk "$afk" \
    --x-mode "$x_mode" \
    --queue-pending "$queue_arg" \
    --repair-line 2>/dev/null || printf '%s\n' 'Resume supervision according to the session-start operating block.')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  WATCHER DOWN - SUPERVISION IS OFF\n'
    printf '●  %s task(s) in flight, but supervision continuity is unhealthy (%s: %s; last beat: %s, grace %ss).\n' \
      "$in_flight" "$FM_SUP_HEALTH_STATE" "$FM_SUP_HEALTH_REASON" "$beacon_desc" "$GRACE"
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
