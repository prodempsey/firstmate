#!/usr/bin/env bash
# The Reconciler - a continuous, bounded, idempotent closure loop (ORD-277 slice 1).
#
# One deterministic pass that runs the Davy Jones closure checks over the captain order
# inbox and the control plane, and turns every discrepancy into an evidence-cited CLOSURE
# PROPOSAL - never a mutation. It is the acting layer on top of the read-only order audit
# (ORD-260 slice S1, bin/fm-order.sh audit): the audit enumerates what is ACCOUNTED; this
# pass proposes what to DO about what is not, with a copy-paste one-line closing command
# per item, coalesced into ONE banner in the fm-triage-duty idiom.
#
# Usage:
#   fm-reconciler.sh [report]        Run the pass and print the coalesced proposal banner.
#   fm-reconciler.sh --json          The same pass as a machine-readable proposals object.
#   fm-reconciler.sh check           Bounded-cadence one-line wake for the watcher check lane.
#   fm-reconciler.sh install         Install the persistent state/reconciler.check.sh shim.
#
# THE FOUR CLOSURE CHECKS (each an evidence bar of its own):
#   order audit (S1)      the umbrella ACCOUNTED count, refreshed fresh this pass so the
#                         denominator is honest (bin/fm-order.sh audit).
#   completion fan-out    a non-terminal order every one of whose linked tasks the control
#     (order-complete)    plane reports COMPLETED - a closeout that skipped the fan-out
#                         chokepoint and left the order open. Proposes `complete`.
#   dead-linkage          a dispatched order whose linked task(s) VANISHED (control plane
#                         reports "task not found") or ended without completing. Proposes a
#                         re-triage (`clarify`), never a silent close.
#   expired holds         a `held` order whose machine-checkable review condition (an ISO
#                         date, an order:<id>:terminal event, or a task:<id>:terminal event)
#                         has now FIRED. Proposes a revisit (`triage`).
#
# NEVER MUTATES. This pass reads the inbox and the control-plane task heads and prints
# proposals. It writes nothing about any order. The one file it refreshes is the audit's
# own deterministic product (state/.order-audit-last.json, owned by bin/fm-order.sh audit),
# and the check-cadence marker (state/.reconciler-check-last); neither is a disposition.
#
# FC-002 POSITIVE-PROOF DISCIPLINE (Absence read as discharge). Nothing is ever proposed
# COMPLETE without positive proof from a fresh, authoritative snapshot that a linked task
# actually reached `completed`. When the control plane is unreachable, the completion and
# dead-linkage checks fail CLOSED: no completion is claimed, no vanish is asserted, and the
# banner says so explicitly so the ABSENCE of `order complete` proposals is never misread
# as "nothing is closeable". A stored id or a ledger link is a lead, not proof.
#
# BOUNDED and IDEMPOTENT. Control-plane reads are confined to the tasks actually referenced
# by a non-terminal order; the digest caps items per section. The pass mutates no order, so
# running it twice yields the same proposals - it is safe to invoke on any wake, from the
# check lane, or by hand.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-role-context-lib.sh
. "$SCRIPT_DIR/fm-role-context-lib.sh"
# shellcheck disable=SC1091 # Dynamic sibling path is resolved from BASH_SOURCE.
. "$SCRIPT_DIR/fm-order-lib.sh"
# fm-order-lib.sh sources fm-fleet-triage-lib.sh, so fm_triage_now / fm_triage_epoch /
# FM_TRIAGE_REVIEW_AGE_JQ are already in scope here.

MAX_ITEMS=${FM_RECONCILER_DIGEST_MAX_ITEMS:-12}
case "$MAX_ITEMS" in ''|*[!0-9]*) MAX_ITEMS=12 ;; esac
CHECK_INTERVAL=${FM_RECONCILER_CHECK_INTERVAL:-900}
case "$CHECK_INTERVAL" in ''|*[!0-9]*) CHECK_INTERVAL=900 ;; esac

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- argument parse -----------------------------------------------------------------
MODE=report
JSON=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=true; shift ;;
    report|check|install)
      MODE=$1; shift ;;
    -*) printf 'fm-reconciler: unknown flag: %s\n' "$1" >&2; exit 2 ;;
    *)  printf 'fm-reconciler: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# --- portable file age --------------------------------------------------------------
if stat -f %m . >/dev/null 2>&1; then
  _stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
age_of() {  # seconds since mtime, or a large number when missing
  local m
  m=$(_stat_mtime "$1") || { printf '999999'; return; }
  [ -n "$m" ] || { printf '999999'; return; }
  printf '%s' "$(( $(date +%s) - m ))"
}

# ------------------------------------------------------------------------------------
# install: write the watcher check shim, exactly the pattern of fm-nf-reconcile.sh install.
# ------------------------------------------------------------------------------------
if [ "$MODE" = install ]; then
  # install only writes the local check shim; the caller (session start) gates it on lock
  # ownership, so it is not role-gated here - exactly like fm-fleet-triage.sh install.
  mkdir -p "$STATE"
  shim="$STATE/reconciler.check.sh"
  body=$(cat <<EOF
#!/usr/bin/env bash
# Auto-generated by fm-reconciler.sh install.
# The watcher runs this each check cycle; bin/fm-reconciler.sh check is itself
# cooldown-guarded (FM_RECONCILER_CHECK_INTERVAL, default ${CHECK_INTERVAL}s), so the
# heavier reconciler pass runs at a bounded cadence and prints one wake line only when
# it has actionable closure proposals.
export FM_HOME=$(printf '%q' "$FM_HOME")
export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")
exec $(printf '%q' "$FM_ROOT/bin/fm-reconciler.sh") check
EOF
)
  if [ -f "$shim" ] && [ "$(cat "$shim" 2>/dev/null)" = "$body" ]; then
    chmod +x "$shim"
    printf 'up to date: %s\n' "$shim"
    exit 0
  fi
  printf '%s\n' "$body" > "$shim"
  chmod +x "$shim"
  printf 'installed: %s\n' "$shim"
  exit 0
fi

# ------------------------------------------------------------------------------------
# Role gate. report/--json/install are primary duties (the S1 audit they invoke is a
# primary-only verb). check runs inside the watcher, which is the primary's supervision,
# so a non-primary check exits silently rather than erroring the watcher's check lane.
# ------------------------------------------------------------------------------------
fm_role_context >/dev/null
ROLE=${FM_ROLE_RESULT:-unknown}
if [ "$ROLE" != primary ]; then
  if [ "$MODE" = check ]; then
    exit 0
  fi
  printf 'error: fm-reconciler.sh %s refused - role could not be proven primary (%s).\n' \
    "$MODE" "${FM_ROLE_REASON:-unknown}" >&2
  exit 2
fi

# ------------------------------------------------------------------------------------
# check: bounded cadence. Skip silently until the cooldown elapses; otherwise run the
# pass and emit one wake line iff there are actionable proposals.
# ------------------------------------------------------------------------------------
if [ "$MODE" = check ]; then
  mkdir -p "$STATE" 2>/dev/null || true
  marker="$STATE/.reconciler-check-last"
  if [ -e "$marker" ] && [ "$(age_of "$marker")" -lt "$CHECK_INTERVAL" ]; then
    exit 0
  fi
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-reconciler.XXXXXX") || {
  printf 'fm-reconciler: could not create scratch dir\n' >&2
  exit 1
}
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap below.
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

INBOX=$(fm_order_inbox_path "$FM_HOME")

# A missing inbox is unambiguous here: no order can be waiting on anything, so there is
# nothing to reconcile. Report all-clear rather than fail (this pass runs on every wake and
# from the watcher, including in homes that never took a captain order).
if [ ! -f "$INBOX" ]; then
  [ "$MODE" = check ] && { touch "$STATE/.reconciler-check-last" 2>/dev/null || true; exit 0; }
  if [ "$JSON" = true ]; then
    jq -cn --arg ts "$(fm_triage_now)" \
      '{schema:"fm-reconciler/v1", generated_at:$ts, inbox_present:false,
        control_plane:{available:false, tasks_checked:0},
        audit:{ran:false}, counts:{order_complete:0,dead_linkage:0,expired_hold:0,
        residual:0,actionable:0}, proposals:[], residual:[]}'
  else
    printf 'reconciler: all clear - no captain order inbox at this home, nothing to reconcile\n'
  fi
  exit 0
fi

# --- fold the inbox (authoritative current state per order) -------------------------
fm_order_fold "$INBOX" > "$SCRATCH/fold.json" 2> "$SCRATCH/fold.err" || {
  printf 'fm-reconciler: could not fold the captain order inbox: %s\n' \
    "$(tr '\n' ' ' < "$SCRATCH/fold.err" | cut -c1-200)" >&2
  exit 1
}

NOW=$(fm_triage_now)
NOW_EPOCH=$(fm_triage_epoch "$NOW" 2>/dev/null || printf 0)
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=0 ;; esac

# --- run the S1 order audit fresh (the umbrella check + a fresh authoritative snapshot) --
AUDIT_RAN=false
AUDIT_JSON='{}'
if AUDIT_OUT=$("$SCRIPT_DIR/fm-order.sh" audit --json 2>"$SCRATCH/audit.err"); then
  if printf '%s' "$AUDIT_OUT" | jq -e '.schema == "fm-order-audit/v1"' >/dev/null 2>&1; then
    AUDIT_RAN=true
    AUDIT_JSON=$AUDIT_OUT
  fi
fi

# --- gather the task ids a closure check must resolve, then read control-plane truth ----
# Only tasks referenced by a NON-TERMINAL order matter: its linked_task_ids (for completion
# / dead-linkage), or a task:<id>:terminal hold condition (for an expired hold). This bound
# is what keeps the pass cheap.
REFERENCED_TASKS=$(jq -r '
  def terminal($s): $s=="completed" or $s=="superseded" or $s=="rejected" or $s=="captain_parked";
  ([ (. | to_entries | map(.value))[]
     | select(terminal(.status // "received") | not)
     | ( (.linked_task_ids // [])[] ,
         ( (.review_after // "")
           | select(test("^task:[A-Za-z0-9._-]+:terminal$")) | split(":")[1] ) ) ])
  | map(select(. != null and . != "")) | unique | .[]' "$SCRATCH/fold.json" 2>/dev/null || true)

CP_AVAILABLE=false
CP_CHECKED=0
TASK_CLASS='{}'
if [ -n "$REFERENCED_TASKS" ]; then
  CP_CLI=$(fm_order_cp_cli "$FM_ROOT" || true)
  CP_DATA_DIR=$(fm_order_cp_data_dir "$STATE")
  if [ -n "$CP_CLI" ] && [ -d "$CP_DATA_DIR" ]; then
    # Availability probe: an initialized, reachable store answers "task not found" for a
    # sentinel id. "not initialized" or an import error is neither, and fails closed.
    CP_PROBE=$(node "$CP_CLI" task-head --data-dir "$CP_DATA_DIR" __fm_reconciler_probe__ 2>&1 || true)
    printf '%s' "$CP_PROBE" | grep -q 'task not found' && CP_AVAILABLE=true
  fi
  if [ "$CP_AVAILABLE" = true ]; then
    # Classify each task from a FRESH read (FC-002): the audit collapses everything terminal
    # into "not live"; a closure check must tell COMPLETED (done) from failed/archived
    # (gone) from vanished (missing), so we re-read here rather than trust the audit's bool.
    #   done    = completed                              -> proves an order's work landed
    #   gone    = failed|cancelled|anomaly|archived|cleaned  -> terminal, but NOT completed
    #   missing = task not found                         -> the linkage is dead (vanished)
    #   live    = any other status                       -> the order is legitimately open
    TASK_CLASS=$(
      for tid in $REFERENCED_TASKS; do
        head=$(node "$CP_CLI" task-head --data-dir "$CP_DATA_DIR" "$tid" 2>"$SCRATCH/th.err" || true)
        if printf '%s' "$head" | grep -q 'task not found'; then
          printf '%s\tmissing\n' "$tid"; continue
        fi
        st=$(printf '%s' "$head" | jq -r '.status // ""' 2>/dev/null || true)
        case "$st" in
          '') printf '%s\tunknown\n' "$tid" ;;
          completed) printf '%s\tdone\n' "$tid" ;;
          failed|cancelled|anomaly|archived|cleaned) printf '%s\tgone\n' "$tid" ;;
          *) printf '%s\tlive\n' "$tid" ;;
        esac
      done | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}'
    )
    CP_CHECKED=$(printf '%s' "$REFERENCED_TASKS" | grep -c . || true)
  fi
fi

# --- classify every non-terminal order into at most one proposal --------------------
# The four checks live in one jq program so the classification is a single, auditable pass.
# The shared review-age fragment is embedded so a date hold is evaluated exactly as the
# fleet-triage ladder and the order audit evaluate it - one definition of a review date.
# shellcheck disable=SC2016 # jq program; $-vars are jq variables.
PROPOSALS=$(jq -n \
  --arg now "$NOW" \
  --argjson now_epoch "$NOW_EPOCH" \
  --argjson cp_available "$CP_AVAILABLE" \
  --argjson task_class "$TASK_CLASS" \
  --slurpfile foldf "$SCRATCH/fold.json" \
  "$FM_TRIAGE_REVIEW_AGE_JQ"'
  def terminal($s): $s=="completed" or $s=="superseded" or $s=="rejected" or $s=="captain_parked";
  def title($o): (($o.short_title // $o.original_request // "") | gsub("[[:space:]]+"; " ") | .[0:80]);
  def clsOf($tid): ($task_class[$tid] // "unknown");

  # Evaluate one held order'"'"'s machine-checkable review condition. Returns a small object:
  #   {kind, fired, pending, condition}  - fired true only on POSITIVE proof it has come due.
  def hold_state($o):
    ($o.review_after // "") as $ra
    | if ($ra | test("^order:[A-Za-z0-9._-]+:terminal$")) then
        (($ra | split(":")[1]) as $ref
         | ($foldf[0][$ref].status // "missing") as $rs
         | {kind:"order-event", condition:$ra,
            fired: (terminal($rs)), pending: (terminal($rs) | not), verifiable:true})
      elif ($ra | test("^task:[A-Za-z0-9._-]+:terminal$")) then
        (($ra | split(":")[1]) as $tid
         | clsOf($tid) as $c
         | if $c == "live" then {kind:"task-event", condition:$ra, fired:false, pending:true, verifiable:true}
           elif ($c == "done" or $c == "gone" or $c == "missing")
             then {kind:"task-event", condition:$ra, fired:true, pending:false, verifiable:true}
           else {kind:"task-event", condition:$ra, fired:false, pending:false, verifiable:false} end)
      elif ($ra | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) then
        (review_age($ra; $now_epoch) as $age
         | if $age == null then {kind:"date", condition:$ra, fired:false, pending:false, verifiable:false}
           elif $age >= 0 then {kind:"date", condition:$ra, fired:true, pending:false, verifiable:true}
           else {kind:"date", condition:$ra, fired:false, pending:true, verifiable:true} end)
      else {kind:"invalid", condition:$ra, fired:false, pending:false, verifiable:false} end;

  # Classify a non-terminal, non-held order that has >=1 linked task, from control-plane truth.
  def linked_verdict($o):
    ($o.linked_task_ids // []) as $ts
    | ([ $ts[] | clsOf(.) ]) as $cs
    | if ($cs | any(. == "live")) then {class:"skip"}                    # legitimately open
      elif ($cp_available | not) then {class:"residual", reason:"linked task state unverifiable (control plane unavailable)"}
      elif ($cs | any(. == "unknown")) then {class:"residual", reason:"linked task state unverifiable (control plane returned no status)"}
      elif ($cs | all(. == "done")) then
        {class:"order-complete",
         detail:([ $ts[] | select(clsOf(.) == "done") | "task " + . + " completed (control-plane verified)" ] | join("; ")),
         evidence:[ $ts[] | select(clsOf(.) == "done") | "task:" + . + ":completed" ]}
      else
        {class:"dead-linkage",
         detail:([ $ts[] | . as $t | clsOf($t)
                   | if . == "missing" then "task " + $t + " not found (vanished)"
                     elif . == "gone" then "task " + $t + " terminal but not completed"
                     else "task " + $t + " " + . end ] | join("; ")),
         evidence:[ $ts[] | "task:" + . ]} end;

  ($foldf[0] // {}) | to_entries | map(.value)
  | [ .[]
      | . as $o
      | ($o.status // "received") as $s
      | select(terminal($s) | not)
      | if $s == "held" then
          (hold_state($o) as $h
           | if $h.fired then
               {class:"expired-hold", order_id:$o.order_id, status:$s, short_title:title($o),
                detail:("hold condition fired: " + $h.condition),
                evidence:[$h.condition],
                command:("bin/fm-order.sh triage " + $o.order_id)}
             elif ($h.pending | not) and ($h.verifiable | not) then
               {class:"residual", order_id:$o.order_id, status:$s, short_title:title($o),
                detail:(if $h.kind == "invalid"
                        then "held on a condition no script can read: " + $h.condition
                        else "held until " + $h.condition + ", which cannot be verified right now" end),
                evidence:[$h.condition], command:null}
             else empty end)                                             # a live/future hold is accounted
        elif (($o.linked_task_ids // []) | length) > 0 then
          (linked_verdict($o) as $v
           | if $v.class == "skip" then empty
             elif $v.class == "order-complete" then
               {class:"order-complete", order_id:$o.order_id, status:$s, short_title:title($o),
                detail:$v.detail, evidence:$v.evidence,
                command:("bin/fm-order.sh complete " + $o.order_id + " --link <evidence>")}
             elif $v.class == "dead-linkage" then
               {class:"dead-linkage", order_id:$o.order_id, status:$s, short_title:title($o),
                detail:$v.detail, evidence:$v.evidence,
                command:("bin/fm-order.sh clarify " + $o.order_id
                         + " --reason " + (($v.detail + "; re-triage or reject") | @sh))}
             else
               {class:"residual", order_id:$o.order_id, status:$s, short_title:title($o),
                detail:$v.reason, evidence:($o.linked_task_ids // []), command:null} end)
        elif $s == "dispatched" then
          # dispatched with no linked task at all: the deadest linkage of all - there is
          # nothing to point the order at. Surface it as dead-linkage needing re-triage.
          {class:"dead-linkage", order_id:$o.order_id, status:$s, short_title:title($o),
           detail:"dispatched with no linked task", evidence:[],
           command:("bin/fm-order.sh clarify " + $o.order_id
                    + " --reason " + ("dispatched with no linked work; re-triage or reject" | @sh))}
        else empty end ]                                                 # other statuses are the audit/triage domain
  | sort_by(.order_id)
' 2>"$SCRATCH/classify.err") || {
  printf 'fm-reconciler: classification failed: %s\n' \
    "$(tr '\n' ' ' < "$SCRATCH/classify.err" | cut -c1-200)" >&2
  exit 1
}

# --- assemble the result object -----------------------------------------------------
RESULT=$(printf '%s' "$PROPOSALS" | jq \
  --arg ts "$NOW" \
  --argjson cp_available "$CP_AVAILABLE" \
  --argjson cp_checked "$CP_CHECKED" \
  --argjson audit_ran "$AUDIT_RAN" \
  --argjson audit "$AUDIT_JSON" '
  . as $all
  | ($all | map(select(.class == "order-complete"))) as $oc
  | ($all | map(select(.class == "dead-linkage")))   as $dl
  | ($all | map(select(.class == "expired-hold")))   as $eh
  | ($all | map(select(.class == "residual")))       as $res
  | {schema:"fm-reconciler/v1",
     generated_at:$ts,
     inbox_present:true,
     control_plane:{available:$cp_available, tasks_checked:$cp_checked},
     audit:(if $audit_ran
            then {ran:true, non_terminal:($audit.non_terminal // 0),
                  accounted:($audit.accounted // 0), unaccounted:($audit.unaccounted // 0)}
            else {ran:false} end),
     counts:{order_complete:($oc|length), dead_linkage:($dl|length),
             expired_hold:($eh|length), residual:($res|length),
             actionable:(($oc|length)+($dl|length)+($eh|length))},
     proposals:($oc + $dl + $eh),
     residual:$res}')

ACTIONABLE=$(printf '%s' "$RESULT" | jq -r '.counts.actionable')
case "$ACTIONABLE" in ''|*[!0-9]*) ACTIONABLE=0 ;; esac

# ------------------------------------------------------------------------------------
# check mode: one terse wake line iff actionable, then stamp the cadence marker.
# ------------------------------------------------------------------------------------
if [ "$MODE" = check ]; then
  touch "$STATE/.reconciler-check-last" 2>/dev/null || true
  if [ "$ACTIONABLE" -gt 0 ]; then
    printf '%s' "$RESULT" | jq -r '
      "reconciler: " + (.counts.actionable|tostring) + " closure proposal(s) - "
      + (.counts.order_complete|tostring) + " order-complete, "
      + (.counts.dead_linkage|tostring) + " dead-linkage, "
      + (.counts.expired_hold|tostring) + " expired-hold"
      + " (run bin/fm-reconciler.sh for the proposals and their one-line closing commands)"'
  fi
  exit 0
fi

# ------------------------------------------------------------------------------------
# --json: the machine-readable object.
# ------------------------------------------------------------------------------------
if [ "$JSON" = true ]; then
  printf '%s' "$RESULT" | jq .
  exit 0
fi

# ------------------------------------------------------------------------------------
# report: the coalesced banner in the fm-triage-duty idiom.
# ------------------------------------------------------------------------------------
render_audit_line() {
  printf '%s' "$RESULT" | jq -r '
    if .audit.ran
    then "order audit (S1): " + (.audit.unaccounted|tostring) + " of "
         + (.audit.non_terminal|tostring) + " non-terminal order(s) unaccounted"
    else "order audit (S1): could not run this pass (see bin/fm-order.sh audit)" end'
}

render_section() {  # <class> <heading>
  printf '%s' "$RESULT" | jq -r --arg cls "$1" --arg heading "$2" --argjson max "$MAX_ITEMS" '
    ((.proposals + .residual) | map(select(.class == $cls))) as $items
    | if ($items | length) == 0 then empty
      else
        ($heading + " (" + ($items|length|tostring) + "):"),
        ( $items[0:$max][]
          | "  " + .order_id + " [" + .status + "]"
            + (if (.short_title // "") != "" then " - " + .short_title else "" end),
            "      " + .detail )
          + "",
        ( if ($items|length) > $max
          then "  ... and " + (($items|length) - $max | tostring) + " more"
          else empty end )
      end'
}

render_commands() {  # <class> <label>
  printf '%s' "$RESULT" | jq -r --arg cls "$1" --arg label "$2" --argjson max "$MAX_ITEMS" '
    (.proposals | map(select(.class == $cls))) as $items
    | $items[0:$max][] | "  " + $label + ": " + .command'
}

# The FC-002 caveat: whenever the control plane was unreachable, the completion and
# dead-linkage checks ran fail-closed, so the ABSENCE of those proposals is not proof that
# nothing is closeable. It prints in EVERY report where the control plane was down, whether
# or not this pass had any other actionable proposal, so a reader never mistakes a
# CP-blocked pass for a clean fleet. $1 is the line prefix ('' for plain, '●  ' for banner).
RESIDUAL_N=$(printf '%s' "$RESULT" | jq -r '.counts.residual')
case "$RESIDUAL_N" in ''|*[!0-9]*) RESIDUAL_N=0 ;; esac
render_cp_caveat() {  # <prefix>
  [ "$CP_AVAILABLE" != true ] || return 0
  printf '%scontrol plane UNAVAILABLE: the completion and dead-linkage checks ran fail-closed\n' "$1"
  printf '%s(FC-002: no order is proven complete, and no linkage proven dead, without it). The\n' "$1"
  printf '%sABSENCE of "order complete" proposals below does NOT mean nothing is closeable.\n' "$1"
}

if [ "$ACTIONABLE" -eq 0 ]; then
  {
    printf 'reconciler: all clear - no closure proposals. %s' "$(render_audit_line)"
    printf '\n'
    render_cp_caveat ''
    if [ "$RESIDUAL_N" -gt 0 ]; then
      printf '(%s order(s) could not be closure-checked this pass - see below.)\n' "$RESIDUAL_N"
      render_section residual 'NEEDS MANUAL TRIAGE (no mechanical close available)'
    fi
  }
  exit 0
fi

{
  printf '●%s\n' "$RULE"
  printf '●  RECONCILER - continuous closure loop (%s actionable proposal(s))\n' "$ACTIONABLE"
  printf '●  %s\n' "$(render_audit_line)"
  render_cp_caveat '●  '
  # Each section: the items, then their copy-paste closing commands.
  ORDER_COMPLETE_BODY=$(render_section order-complete 'ORDER COMPLETE - linked work landed, the order was never closed (fan-out missed)')
  if [ -n "$ORDER_COMPLETE_BODY" ]; then
    printf '●\n'
    printf '%s\n' "$ORDER_COMPLETE_BODY" | sed 's/^/●  /'
    render_commands order-complete close | sed 's/^/●/'
  fi
  DEAD_BODY=$(render_section dead-linkage 'DEAD LINKAGE - dispatched order whose task(s) vanished or ended without completing')
  if [ -n "$DEAD_BODY" ]; then
    printf '●\n'
    printf '%s\n' "$DEAD_BODY" | sed 's/^/●  /'
    render_commands dead-linkage revisit | sed 's/^/●/'
  fi
  HOLD_BODY=$(render_section expired-hold 'EXPIRED HOLD - a machine-checkable hold whose condition has fired')
  if [ -n "$HOLD_BODY" ]; then
    printf '●\n'
    printf '%s\n' "$HOLD_BODY" | sed 's/^/●  /'
    render_commands expired-hold revisit | sed 's/^/●/'
  fi
  RESIDUAL_BODY=$(render_section residual 'NEEDS MANUAL TRIAGE (no mechanical close available)')
  if [ -n "$RESIDUAL_BODY" ]; then
    printf '●\n'
    printf '%s\n' "$RESIDUAL_BODY" | sed 's/^/●  /'
  fi
  printf '●\n'
  printf '●  Proposals only - this pass never mutates. Each command above is yours to run; an\n'
  printf '●  order is closed only when you run it. Nothing is claimed complete without positive\n'
  printf '●  control-plane proof (FC-002). Re-run bin/fm-reconciler.sh any time - it is idempotent.\n'
  printf '●%s\n' "$RULE"
}
exit 0
