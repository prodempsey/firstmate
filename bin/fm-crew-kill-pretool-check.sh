#!/usr/bin/env bash
# Crew-session PreToolUse seatbelt against broad kill patterns.
#
# Root cause (bug-20260712002638-66d9ce63, data/cockpit-crash-triage-x1/report.md
# on the fleet-bridge firstmate home): every recent live-cockpit crash was a
# crewmate's own test/verification cleanup running an unscoped process kill that
# also matched the LIVE fleet-bridge cockpit server or the REAL tmux server, e.g.
# `pkill -f "node server.js"` or bare `tmux kill-server` (no -L socket). This
# script denies that class of command before it runs.
#
# It is the crew-session sibling of bin/fm-arm-pretool-check.sh: same PreToolUse
# transport shape (stdin JSON extraction, --command, --claude), same exit/output
# contract, same fail-open posture on malformed transport. It does not reuse that
# script's Node command-position classifier: the threat here is a crewmate's own
# accidental broad kill during cleanup, not adversarial obfuscation, so a direct
# substring/pattern classification in bash is proportionate and keeps this file
# self-contained and shellcheck-clean without inventing a second policy owner.
# See docs/crew-kill-guard.md for the full deny/allow contract and the evidence
# pointer.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-crew-kill-pretool-check.sh [--claude]
#   bin/fm-crew-kill-pretool-check.sh --command '<cmd>' [--sandbox <path>]... [--claude]
#
# --sandbox <path> (repeatable) names a root this crew is known to own (its
# worktree, its per-task tmp root). A kill pattern that references one of these
# paths, or the generic /tmp/fm- per-task tmp prefix, or a path containing
# "sandbox" or "scratchpad", is allow-listed even if it also mentions a banned
# name below - it is scoped to the crew's own sandbox, not the live cockpit.
#
# Exit/output contract (same as bin/fm-arm-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped deny
#          object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or a
#               command with no kill-shaped verb at all.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
SANDBOX_PATTERNS=()

usage() {
  cat <<'EOF'
Usage: fm-crew-kill-pretool-check.sh [--command <cmd>] [--sandbox <path>]... [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Exits 0 to allow and 2 to deny.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
Malformed transport fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --sandbox)
      [ "$#" -gt 1 ] || { echo "error: --sandbox requires a value" >&2; exit 2; }
      SANDBOX_PATTERNS+=("$2")
      shift 2
      ;;
    --sandbox=*)
      SANDBOX_PATTERNS+=("${1#--sandbox=}")
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  [ -n "$CMD" ] || exit 0
fi

[ -n "$CMD" ] || exit 0

# A pure `echo`/`printf` of a literal string is data, not an executed kill -
# the same "quoted text is data" principle bin/fm-arm-pretool-check.sh's
# classifier documents. Excluded from this fast allow: anything chained after
# it (so a smuggled real kill after `;`/`&&`/`||`/`|`/a newline is still
# classified) and any command substitution or backtick (so an actually-
# executed kill cannot hide inside the printed argument).
# shellcheck disable=SC2016  # literal '$(' / '`' needles, not expansions
if [[ "$CMD" =~ ^[[:space:]]*(echo|printf)[[:space:]] ]] \
   && [[ "$CMD" != *';'* && "$CMD" != *'&&'* && "$CMD" != *'||'* && "$CMD" != *'|'* && "$CMD" != *$'\n'* ]] \
   && [[ "$CMD" != *'$('* && "$CMD" != *'`'* ]]; then
  exit 0
fi

# Fast allow: nothing in the command is even shaped like a kill, a broad
# process-name kill tool, or a live-unit service action, so there is nothing
# for this classifier to weigh in on. A bare `kill <pid>` with no pgrep in
# sight also fast-allows here: this classifier only ever denies a pgrep-fed
# kill, never a plain PID kill.
LOWER=${CMD,,}
case "$LOWER" in
  *pkill*|*killall*|*kill-server*|*systemctl*) ;;
  *pgrep*kill*|*kill*pgrep*) ;;
  *) exit 0 ;;
esac

# scoped_to_sandbox: true when the raw command text names a path this crew is
# known to own (an explicit --sandbox root, the generic per-task tmp prefix
# every crew uses, or a path carrying an obvious scratch marker).
scoped_to_sandbox() {
  local pattern
  for pattern in "${SANDBOX_PATTERNS[@]:-}" /tmp/fm- sandbox scratchpad; do
    [ -n "$pattern" ] || continue
    case "$CMD" in
      *"$pattern"*) return 0 ;;
    esac
  done
  return 1
}

# tmux_socket_scoped: true when the command carries an explicit tmux -L or -S
# socket argument, which names a non-default socket rather than the shared
# default tmux server the captain's console and every crew pane run on.
tmux_socket_scoped() {
  [[ "$CMD" =~ -L[[:space:]]+[^[:space:]] || "$CMD" =~ -S[[:space:]]+[^[:space:]] ]]
}

deny() {
  local code=$1 reason=$2 detail escaped
  detail="[$code] $reason"
  escaped=$(printf '%s' "$detail" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

SAFE_ALT="kill only the exact PID of a process you spawned yourself (kill <pid> on a recorded \$!), and scope any tmux teardown to your own socket (tmux -L <your-test-socket> kill-server)."

# Each check below is independent (not mutually exclusive): a single command
# can in principle trip more than one rule, and every rule must still see the
# full command rather than only the first keyword that happened to match.

# 1. Bare `tmux kill-server` with no explicit socket: this destroys the REAL
#    tmux server hosting the captain's console and every crew pane.
if [[ "$LOWER" == *tmux*kill-server* ]] && ! tmux_socket_scoped; then
  deny crew-tmux-kill-server "bare tmux kill-server has no explicit socket and would destroy the real tmux server hosting the captain's console and every crew pane. $SAFE_ALT"
fi

# 2. systemctl --user (restart|stop|kill) fleet-bridge: crew sessions never
#    manage the live cockpit unit.
if [[ "$LOWER" == *systemctl* && "$LOWER" == *--user* && "$LOWER" == *fleet-bridge* \
   && "$LOWER" =~ (^|[^a-z0-9_])(restart|stop|kill)([^a-z0-9_]|$) ]]; then
  deny crew-systemctl-fleet-bridge "crew sessions never restart, stop, or kill the live fleet-bridge unit. $SAFE_ALT"
fi

# 3. pkill/killall with an unscoped/generic pattern targeting the live cockpit
#    server or the shared tmux server.
if [[ "$LOWER" == *pkill* || "$LOWER" == *killall* ]] \
   && [[ "$LOWER" =~ server\.js|fleet-bridge|ttyd|tmux ]] \
   && ! scoped_to_sandbox && ! tmux_socket_scoped; then
  deny crew-broad-kill "this pattern-kill is unscoped and could match the live cockpit server or the real tmux server, not just a process you spawned. $SAFE_ALT"
fi

# 4. kill -9 fed from a pgrep -f of such a pattern (command substitution,
#    backticks, or piped into xargs kill), in either byte order.
if [[ "$LOWER" == *pgrep*kill* || "$LOWER" == *kill*pgrep* ]] \
   && [[ "$LOWER" =~ server\.js|fleet-bridge|ttyd|tmux ]] \
   && ! scoped_to_sandbox && ! tmux_socket_scoped; then
  deny crew-broad-kill "this kill is fed from a pgrep -f pattern that is unscoped and could match the live cockpit server or the real tmux server, not just a process you spawned. $SAFE_ALT"
fi

exit 0
