#!/usr/bin/env bash
# Write closure evidence through Fleet Bridge's server-independent visibility CLI.
#
# Teardown refuses when this script fails, so the close step is idempotent and
# self-healing against the two ways a durable TaskRecord can be out of step with a
# task that is genuinely finished:
#
#   unknown task   - the task predates the visibility CLI, or was never recorded.
#                    Record it first from state/<id>.meta (kind, home), then close.
#   terminal task  - the record was already closed out of band. That is SUCCESS when
#                    the terminal record carries valid closure evidence, because the
#                    durable trail the teardown gate protects already exists;
#                    `visibility audit` is the arbiter of "valid".
#
# The gate itself is unchanged. Any other close failure - including a terminal record
# whose closure evidence is missing or invalid, and an audit that cannot be read - still
# fails closed, so volatile task state is never destroyed without a durable trail.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

visibility_cli() {
  local candidate
  if [ -n "${FM_VISIBILITY_CLI:-}" ]; then
    printf '%s\n' "$FM_VISIBILITY_CLI"
    return
  fi
  for candidate in \
    /home/prode/fleet/.fb-redesign/bin/visibility.mjs \
    /home/prode/fleet/fleet-bridge/bin/visibility.mjs \
    "$FM_HOME/projects/fleet-bridge/bin/visibility.mjs" \
    "$FM_ROOT/projects/fleet-bridge/bin/visibility.mjs"; do
    [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return; }
  done
  return 1
}

meta_value() {
  local key=$1 file=$2 line
  [ -f "$file" ] || return 0
  line=$(grep -m1 "^${key}=" "$file" 2>/dev/null) || return 0
  printf '%s\n' "${line#*=}"
}

# The CLI's default home comes from fleet-bridge's own config, so record and close must
# agree on one explicit home; otherwise a backfilled record can land in a different home
# than the close reads. A secondmate task's meta names its home; everything else is here.
home_name() {
  local home
  home=$(meta_value home "$META")
  [ -n "$home" ] || home=$FM_HOME
  basename "$home"
}

close_task() { node "$CLI" "${CLOSE_ARGS[@]}"; }

# True when `visibility audit` reports no invalid closeout for this task, i.e. the
# already-terminal record does carry valid closure evidence. An audit that is missing or
# unparseable is a false, so an unusable audit fails closed instead of waving teardown
# through on an unverified record.
terminal_record_has_valid_evidence() {
  local audit
  audit=$(node "$CLI" audit --json 2>/dev/null) || true
  [ -n "$audit" ] || return 1
  FM_AUDIT_TASK_ID="$ID" node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      let audit;
      try { audit = JSON.parse(raw); } catch { process.exit(1); }
      if (!Array.isArray(audit.diagnostics)) process.exit(1);
      const id = process.env.FM_AUDIT_TASK_ID;
      const invalid = audit.diagnostics.some((d) => d && d.type === "invalid_closeout"
        && String(d.recordId || "").split(":").pop() === id);
      process.exit(invalid ? 1 : 0);
    });
  ' <<<"$audit"
}

[ "$#" -ge 6 ] || { echo "usage: fm-task-events.sh <id> <disposition> <outcome> <branch> <mode> <sha-or-report>" >&2; exit 2; }
ID=$1 DISPOSITION=$2 OUTCOME=$3 BRANCH=$4 MODE=$5 EVIDENCE=$6
CLI=$(visibility_cli) || { echo "blocked: fleet-bridge visibility CLI not found" >&2; exit 1; }

META="$STATE/$ID.meta"
KIND=$(meta_value kind "$META")
[ -n "$KIND" ] || KIND=ship
HOME_NAME=$(home_name)

CLOSE_ARGS=(close "$ID" --disposition "$DISPOSITION" --outcome "$OUTCOME" --branch "$BRANCH" --mode "$MODE" --home "$HOME_NAME")
if [ "$MODE" = scout-report ]; then CLOSE_ARGS+=(--report "$EVIDENCE"); else CLOSE_ARGS+=(--sha "$EVIDENCE"); fi

if out=$(close_task 2>&1); then
  printf '%s\n' "$out"
  exit 0
fi

case $out in
  *"unknown task"*)
    # Nothing durable to close yet, so backfill the record. `record` accepts only a
    # non-terminal status, and in_progress is the truth at teardown time: the task ran,
    # and the close below is what ends it.
    if ! node "$CLI" record "$ID" "$ID" --kind "$KIND" --status in_progress --home "$HOME_NAME" >/dev/null 2>&1; then
      printf '%s\n' "$out" >&2
      echo "blocked: no TaskRecord for $HOME_NAME/$ID and recording one failed" >&2
      exit 1
    fi
    if out=$(close_task 2>&1); then
      printf '%s\n' "$out"
      exit 0
    fi
    ;;
  *"terminal task cannot accept"*)
    if terminal_record_has_valid_evidence; then
      echo "already closed: $HOME_NAME/$ID has a terminal TaskRecord with valid closure evidence" >&2
      exit 0
    fi
    printf '%s\n' "$out" >&2
    echo "blocked: terminal TaskRecord for $HOME_NAME/$ID lacks valid closure evidence" >&2
    exit 1
    ;;
esac

printf '%s\n' "$out" >&2
exit 1
