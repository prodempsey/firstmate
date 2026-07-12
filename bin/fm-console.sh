#!/usr/bin/env bash
# fm-console.sh - launch (idempotently) a dedicated FirstMate console session in
# a tmux window so the Fleet Bridge "FirstMate Console" can surface and command it.
# This is the operational coordinator the captain drives from the Helm command
# bar - distinct from any builder/CLI session.
#
# Usage: fm-console.sh        # no-op if already running; prints the window target
#        FM_CONSOLE_WINDOW / FM_CONSOLE_SESSION override the defaults.
# At boot/respawn, state/cockpit-settings.json may contain fmModelBackups[], an
# ordered model list tried after fmModel. Model prefixes map to engines exactly
# as before: gpt-* -> codex, grok-* -> grok, everything else -> claude. The
# first candidate with an installed harness command and enabled harness/provider
# circuits in state/provider-failover.json is launched. A live healthy console
# is never swapped mid-session.
#
# Handoff seeding is token-gated: the console inherits state/fm-handoff.md ONLY
# against a fresh, unconsumed handoff request token (state/fm-handoff.request.json,
# written by the cockpit hand-off flow). A brief lying on disk is NOT a hand-off,
# so a crash relaunch or a plain fm-console.sh start boots clean instead of
# replaying stale state as if it were current. docs/console-handoff.md owns the
# contract, the token format, and the lifecycle evidence log.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SESSION="${FM_CONSOLE_SESSION:-firstmate}"
WINDOW="${FM_CONSOLE_WINDOW:-fm-console}"
TARGET="$SESSION:$WINDOW"

HANDOFF_BRIEF="$FM_HOME/state/fm-handoff.md"
HANDOFF_REQUEST="$FM_HOME/state/fm-handoff.request.json"
HANDOFF_EVIDENCE="$FM_HOME/state/handoff"
HANDOFF_EVENTS="$HANDOFF_EVIDENCE/events.jsonl"

# shellcheck source=bin/fm-provider-failover.sh
. "$SCRIPT_DIR/fm-provider-failover.sh"

# Portable mtime. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`,
# and the `-f || -c` fallback form is unsafe (Linux `stat -f` is filesystem stat and
# prints a partial dump before failing). Detect the platform once, as fm-watch.sh does.
if [ "$(uname)" = Darwin ]; then
  console_stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  console_stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# handoff_event <event> <id> <reason> - append one lifecycle record. Best-effort:
# evidence must never be able to fail a console launch.
handoff_event() {
  mkdir -p "$HANDOFF_EVIDENCE" 2>/dev/null || return 0
  printf '{"event":"%s","id":"%s","at":"%s","atMs":%s,"reason":"%s","brief":"%s","request":"%s"}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(( $(date +%s) * 1000 ))" "$(json_escape "$3")" \
    "$(json_escape "$HANDOFF_BRIEF")" "$(json_escape "$HANDOFF_REQUEST")" \
    >> "$HANDOFF_EVENTS" 2>/dev/null || true
}

# Epoch-ms the pending request was made, on stdout; non-zero when there is no
# parseable pending request token. jq when available, a tolerant grep otherwise -
# jq is only a hard requirement for the settings file.
handoff_request_ms() {
  [ -f "$HANDOFF_REQUEST" ] || return 1
  ms=""
  if command -v jq >/dev/null 2>&1 && jq -e . "$HANDOFF_REQUEST" >/dev/null 2>&1; then
    ms=$(jq -r '.requestedAtMs // empty' "$HANDOFF_REQUEST")
  else
    ms=$(sed -n 's/.*"requestedAtMs"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
      "$HANDOFF_REQUEST" | head -1)
  fi
  case "$ms" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ms" -gt 0 ] || return 1
  printf '%s\n' "$ms"
}

# handoff_request_id <requested-at-ms> - the cockpit's own id when it records one,
# otherwise derived from the request timestamp so evidence is still correlatable.
handoff_request_id() {
  id=""
  if command -v jq >/dev/null 2>&1 && jq -e . "$HANDOFF_REQUEST" >/dev/null 2>&1; then
    id=$(jq -r '.id // empty' "$HANDOFF_REQUEST")
  fi
  case "$id" in ''|null) id="h-$1" ;; esac
  printf '%s\n' "$id"
}

tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION"

STALE_WINDOW=0
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  PANE_CMD="$(tmux display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)"
  case "$PANE_CMD" in
    claude|codex|opencode|pi|grok|node|python|python3)
      echo "$TARGET (already running)"
      exit 0
      ;;
    *)
      STALE_WINDOW=1
      ;;
  esac
fi

# The boot prompt (and its handoff seed) is resolved below, after model selection:
# claiming the handoff token must happen only once this launch is committed, so a
# failed model selection can never burn a genuine pending hand-off.

# FirstMate model, backup models, and personality from the cockpit Settings page
# (state/cockpit-settings.json, written by the Settings overlay / Helm model
# dropdown). They apply at session boot only - a live console session cannot
# hot-swap. Absent/empty/unset => today's defaults (no --model, no backups,
# standard voice).
SETTINGS="${FM_CONSOLE_SETTINGS:-$FM_HOME/state/cockpit-settings.json}"
FM_MODEL=""; FM_PERSONALITY=""; FM_MODEL_BACKUPS=()
if [ -f "$SETTINGS" ]; then
  command -v jq >/dev/null 2>&1 || { echo "fm-console: jq is required to read $SETTINGS" >&2; exit 1; }
  jq -e . "$SETTINGS" >/dev/null 2>&1 || { echo "fm-console: invalid JSON in $SETTINGS" >&2; exit 1; }
  if ! jq -e '(.fmModelBackups? // []) | type == "array" and all(.[]; type == "string")' "$SETTINGS" >/dev/null; then
    echo "fm-console: fmModelBackups in $SETTINGS must be an array of model strings" >&2
    exit 1
  fi
  FM_MODEL=$(jq -r '.fmModel // empty' "$SETTINGS")
  FM_PERSONALITY=$(jq -r '.fmPersonality // empty' "$SETTINGS")
  mapfile -t FM_MODEL_BACKUPS < <(jq -r '.fmModelBackups // [] | .[]' "$SETTINGS")
fi

engine_for_model() {
  case "$1" in
    gpt-*) echo codex ;;
    grok-*) echo grok ;;
    *) echo claude ;;
  esac
}

provider_for_engine() {
  case "$1" in
    codex) echo openai ;;
    grok) echo xai ;;
    claude) echo anthropic ;;
  esac
}

MODEL_CANDIDATES=("$FM_MODEL" ${FM_MODEL_BACKUPS[@]+"${FM_MODEL_BACKUPS[@]}"})
PRIMARY_MODEL=$FM_MODEL
SELECTED=0
SELECTED_INDEX=0
SKIP_REASONS=()
index=0
for candidate_model in "${MODEL_CANDIDATES[@]}"; do
  candidate_engine=$(engine_for_model "$candidate_model")
  candidate_provider=$(provider_for_engine "$candidate_engine")
  if unavailable=$(fm_failover_candidate_reason "$candidate_engine" "$candidate_provider"); then
    availability_rc=0
  else
    availability_rc=$?
  fi
  [ "$availability_rc" -ne 2 ] || { echo "fm-console: could not evaluate provider failover state" >&2; exit 1; }
  if [ "$availability_rc" -eq 1 ]; then
    FM_MODEL=$candidate_model
    ENGINE=$candidate_engine
    SELECTED_INDEX=$index
    SELECTED=1
    break
  fi
  SKIP_REASONS+=("${candidate_model:-(default claude)}: $unavailable")
  index=$((index + 1))
done
if [ "$SELECTED" -eq 0 ]; then
  reasons=$(IFS='; '; echo "${SKIP_REASONS[*]}")
  echo "fm-console: no available model candidate ($reasons)" >&2
  exit 1
fi
if [ "$SELECTED_INDEX" -gt 0 ]; then
  reasons=$(IFS='; '; echo "${SKIP_REASONS[*]}")
  echo "fm-console: primary model '${PRIMARY_MODEL:-(default claude)}' unavailable ($reasons); selected backup #$SELECTED_INDEX '$FM_MODEL' ($ENGINE)" >&2
fi

# Handoff seed resolution. Everything above this point can still refuse to launch;
# from here the console is committed, so this is where a pending request token may
# be claimed. Three paths:
#   explicit FM_CONSOLE_SEED - a deliberate caller override, seeded iff it exists
#                              (the cockpit points it at a non-existent path to
#                              force a clean boot mid-handoff).
#   pending fresh request    - the brief is at least as new as the request, so this
#                              IS the requested hand-off: claim the token and seed.
#   anything else            - NO seed, including a stale brief with no request.
#                              That default is the whole point: mere file existence
#                              used to make every crash relaunch look like a
#                              captain-requested hand-off.
SEED=""
if [ -n "${FM_CONSOLE_SEED:-}" ]; then
  if [ -f "$FM_CONSOLE_SEED" ]; then
    SEED="$FM_CONSOLE_SEED"
    handoff_event seeded override explicit-seed
  else
    handoff_event skipped override explicit-seed-absent
  fi
elif REQUEST_MS=$(handoff_request_ms); then
  REQUEST_ID=$(handoff_request_id "$REQUEST_MS")
  BRIEF_S=$(console_stat_mtime "$HANDOFF_BRIEF" || true)
  case "$BRIEF_S" in ''|*[!0-9]*) BRIEF_S="" ;; esac
  if [ -z "$BRIEF_S" ]; then
    # Token pending but no brief yet - the outgoing console has not written it.
    # Leave the token in place so the hand-off can still complete.
    handoff_event skipped "$REQUEST_ID" brief-missing
  elif [ "$(( BRIEF_S * 1000 + 999 ))" -lt "$REQUEST_MS" ]; then
    handoff_event skipped "$REQUEST_ID" brief-older-than-request
  else
    # Claim the token by renaming it. The rename is atomic and can succeed exactly
    # once, so a concurrent start, a later crash relaunch, or a manual run can never
    # re-seed from this request.
    mkdir -p "$HANDOFF_EVIDENCE/$REQUEST_ID" 2>/dev/null || true
    if mv "$HANDOFF_REQUEST" "$HANDOFF_EVIDENCE/$REQUEST_ID/request.json" 2>/dev/null; then
      cp "$HANDOFF_BRIEF" "$HANDOFF_EVIDENCE/$REQUEST_ID/brief.md" 2>/dev/null || true
      SEED="$HANDOFF_BRIEF"
      handoff_event consumed "$REQUEST_ID" request-claimed
    else
      handoff_event skipped "$REQUEST_ID" claim-lost
    fi
  fi
elif [ -f "$HANDOFF_BRIEF" ]; then
  handoff_event skipped none stale-brief-no-request
fi

# Boot prompt: become FirstMate, confirm readiness per AGENTS.md, then wait for
# captain directives sent from the cockpit command bar. No apostrophes (kept simple
# for the literal send-keys below).
if [ -n "$SEED" ]; then
  BOOT="You are FirstMate, the fleet coordinator, running as the FirstMate Console inside the cockpit Helm. A handoff brief from the outgoing FirstMate is at $SEED - READ IT FIRST to inherit every in-flight workstream, then read AGENTS.md, data/captain.md, and data/projects.md, confirm readiness per AGENTS.md WITHOUT making project changes, and wait for captain directives from the cockpit command bar."
else
  BOOT='You are FirstMate, the fleet coordinator, running as the FirstMate Console inside the Helm. Read AGENTS.md, data/captain.md, and data/projects.md now. Confirm readiness per AGENTS.md (project mode via bin/fm-project-mode.sh krakenloop, crew harness via bin/fm-harness.sh crew, and KrakenLoop status and HEAD), then report readiness WITHOUT making project changes, and wait for captain directives sent from the Helm command bar.'
fi

if [ "$STALE_WINDOW" -eq 1 ]; then
  tmux kill-window -t "$TARGET" 2>/dev/null || true
  tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION"
fi

if [ "$ENGINE" = claude ]; then
  # 1M-SAFETY: the Settings dropdown stores a plain model id (e.g. claude-opus-4-8),
  # but FirstMate runs on the 1M-context Opus variant. Passing the plain id to
  # --model would silently drop the context window to the standard size on respawn.
  # Map Opus selections to their [1m] variant so the console keeps 1M. Non-Opus
  # models (sonnet/haiku) have no 1M variant and pass through unchanged; an id that
  # already carries [1m] is left as-is.
  case "$FM_MODEL" in
    claude-opus-4-8) FM_MODEL="claude-opus-4-8[1m]" ;;
    claude-opus-4-7) FM_MODEL="claude-opus-4-7[1m]" ;;
    *)               : ;;  # already-[1m] / non-opus / unset => unchanged
  esac
fi
case "$FM_PERSONALITY" in
  terse)   BOOT="$BOOT Communicate tersely: short, direct answers, minimal preamble." ;;
  verbose) BOOT="$BOOT Communicate thoroughly: explain your reasoning and surface relevant context." ;;
  *)       : ;;  # standard / unset => no change
esac
MODEL_ARG=""
[ -n "$FM_MODEL" ] && MODEL_ARG="--model $FM_MODEL"

SID=
if [ "$ENGINE" = claude ]; then
  # A known session id makes this session's transcript findable, so the cockpit can
  # meter its context usage (tokens / % of window). Recorded for the cockpit to read.
  SID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  mkdir -p "$FM_HOME/state"
  printf '%s\n' "$SID" > "$FM_HOME/state/fm-console.session"
fi

tmux new-window -d -t "$SESSION" -n "$WINDOW" -c "$FM_HOME"
case "$ENGINE" in
  claude)
    tmux send-keys -t "$TARGET" -l "claude --dangerously-skip-permissions $MODEL_ARG --session-id \"$SID\" \"$BOOT\""
    ;;
  codex)
    # FirstMate-isolated Codex home: shield the console from the global
    # ~/.codex/config.toml, which may contain host-specific MCP and plugin
    # configuration that is unsuitable for this runtime. The curated config
    # carries no MCP servers, plugins, or marketplaces. Regenerate it on each
    # real launch; the existing-window path already returned above.
    CODEX_HOME_FM="$FM_HOME/state/codex-home"
    mkdir -p "$CODEX_HOME_FM"
    # Preserve login through the real credential store without copying secrets.
    if [ ! -e "$CODEX_HOME_FM/auth.json" ] && [ -f "$HOME/.codex/auth.json" ]; then
      ln -s "$HOME/.codex/auth.json" "$CODEX_HOME_FM/auth.json"
    fi
    cat > "$CODEX_HOME_FM/config.toml" <<TOML
model = "$FM_MODEL"
model_reasoning_effort = "xhigh"
approvals_reviewer = "user"
sandbox_mode = "danger-full-access"
service_tier = "priority"
personality = "pragmatic"

[projects."$FM_HOME"]
trust_level = "trusted"
TOML
    tmux send-keys -t "$TARGET" -l "CODEX_HOME=\"$CODEX_HOME_FM\" codex $MODEL_ARG --dangerously-bypass-approvals-and-sandbox \"$BOOT\""
    ;;
  grok)
    # Match bin/fm-spawn.sh launch_template for harness=grok: --always-approve
    # is the unattended equivalent of claude's --dangerously-skip-permissions.
    # No SID tracking (same as codex); MODEL_ARG is generic above.
    tmux send-keys -t "$TARGET" -l "grok --always-approve $MODEL_ARG \"$BOOT\""
    ;;
esac
tmux send-keys -t "$TARGET" Enter
# Make the fresh Console the active window of the base session so a (re)spawn
# never strands an attaching client on the stray default shell. The live Helm
# grouped view keeps its own current-window pointer - the respawn endpoint
# re-selects there too.
tmux select-window -t "$TARGET" 2>/dev/null || true
case "$ENGINE" in
  claude) echo "$TARGET (started, session $SID)" ;;
  codex)  echo "$TARGET (started, codex)" ;;
  grok)   echo "$TARGET (started, grok)" ;;
esac
