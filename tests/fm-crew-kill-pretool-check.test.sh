#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the crew-session broad-kill PreToolUse seatbelt
# (docs/crew-kill-guard.md), bin/fm-crew-kill-pretool-check.sh.
#
# Covers: the exact real incident commands and the recorded near-miss from
# data/cockpit-crash-triage-x1/report.md as deny regressions, the allowed
# scoped forms (sandbox path, tmux -L/-S socket), transport entry forms
# (stdin claude/codex/grok shapes and --command), fail-open behavior, the
# --claude output-shaping contract, the bin/fm-spawn.sh wiring into a Claude
# crewmate's generated .claude/settings.local.json, and the fm-brief.sh
# rule-7 brief-contract language.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-crew-kill-pretool-check.sh"

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-kill-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")
trap fm_test_cleanup EXIT

# --- direct --command classification: real incidents + near-miss ------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_CODES=()
MATRIX_COMMANDS=()

matrix_case() {  # <id> allow|deny [code] <command>
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  if [ "$2" = deny ]; then
    MATRIX_CODES+=("$3")
    MATRIX_COMMANDS+=("$4")
  else
    MATRIX_CODES+=("")
    MATRIX_COMMANDS+=("$3")
  fi
}

# Real incidents, data/cockpit-crash-triage-x1/report.md, bug-20260712002638-66d9ce63.
matrix_case I01 deny crew-broad-kill 'pkill -f "node server.js"'
matrix_case I02 deny crew-broad-kill 'pkill -9 -f "node.*server.js"'
matrix_case I03 deny crew-broad-kill 'pkill -9 -f "node server.js"'
matrix_case I04 deny crew-tmux-kill-server 'tmux kill-server'

# Other generic-pattern deny shapes.
matrix_case D01 deny crew-broad-kill 'killall -9 tmux'
matrix_case D02 deny crew-broad-kill 'pkill -f fleet-bridge'
matrix_case D03 deny crew-broad-kill 'pkill ttyd'
matrix_case D04 deny crew-broad-kill 'kill -9 $(pgrep -f "node server.js")'
matrix_case D05 deny crew-broad-kill 'pgrep -f fleet-bridge | xargs kill -9'
matrix_case D06 deny crew-broad-kill 'p=$(pgrep -f tmux); kill -9 $p'
matrix_case D07 deny crew-systemctl-fleet-bridge 'systemctl --user restart fleet-bridge'
matrix_case D08 deny crew-systemctl-fleet-bridge 'systemctl --user stop fleet-bridge'
matrix_case D09 deny crew-systemctl-fleet-bridge 'systemctl --user kill fleet-bridge'
matrix_case D10 deny crew-tmux-kill-server 'sudo tmux kill-server'

# Allowed: unrelated commands, plain PID kills, read-only pgrep.
matrix_case A01 allow 'ls -la'
matrix_case A02 allow 'kill 12345'
matrix_case A03 allow 'kill -9 12345'
matrix_case A04 allow 'kill $!'
matrix_case A05 allow "pgrep -fl 'node server.js' || true"
matrix_case A06 allow "echo 'pkill -f fleet-bridge'"
matrix_case A07 allow 'killall -9 my-own-fixture-binary'

# Allowed: -L/-S scoped tmux operations, including inside a pkill pattern.
matrix_case A08 allow 'tmux -L fmtest-abc123 kill-server'
matrix_case A09 allow 'tmux -S /tmp/fm-crew-pkill-guard-g1/fmtest.sock kill-server'
matrix_case A10 allow 'pkill -f "tmux -L fmtest-lab"'

# Allowed: pattern-kills scoped to a generic per-task tmp root or scratch marker.
matrix_case A11 allow 'pkill -f "/tmp/fm-some-other-task/gotmp/node server.js"'
matrix_case A12 allow 'pkill -f "$HOME/sandbox/fixture/node server.js"'
matrix_case A13 allow 'pkill -f "./scratchpad/fixture-tmux"'

run_matrix_entry() {
  local id=$1 expected=$2 code=$3 entry=$4 cmd=$5 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    cli)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e --arg code "$code" '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | startswith("[" + $code + "]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry reason code [$code] on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in claude grok cli; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "${MATRIX_CODES[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
    pass "matrix ${MATRIX_IDS[$i]}: ${MATRIX_EXPECTED[$i]} through claude/grok/cli entry forms"
  done
}

# --- --sandbox roots (fm-spawn.sh bakes in the crew's own worktree/tmp) ------

test_sandbox_flag_allows_own_paths() {
  local rc
  "$CHECK" --command 'pkill -f "/home/crew/worktrees/task-x9/gotmp/node server.js"' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "without --sandbox, a pattern outside any known scratch root must still deny, got exit $rc"

  "$CHECK" --command 'pkill -f "/home/crew/worktrees/task-x9/gotmp/node server.js"' \
    --sandbox /home/crew/worktrees/task-x9 >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a pattern naming a passed --sandbox root must allow, got exit $rc"

  "$CHECK" --command 'pkill -f "/home/crew/worktrees/task-x9/gotmp/node server.js"' \
    --sandbox /home/crew/worktrees/some-other-task >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "a --sandbox root that does not match the pattern must not allow it, got exit $rc"
  pass "--sandbox roots allow-list only the specific paths passed, not everything"
}

test_sandbox_equals_form() {
  "$CHECK" --command='pkill -f "/x/y/node server.js"' --sandbox=/x/y >/dev/null 2>&1 \
    || fail "--sandbox=<val> equals-form must parse and allow-list the same as --sandbox <val>"
  pass "--sandbox=<val> equals-form parses correctly"
}

# --- CLI parsing --------------------------------------------------------------

test_command_equals_form() {
  "$CHECK" --command='pkill -f "node server.js"' >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "--command=<val> form must parse the same as --command <val>"
  pass "--command=<val> equals-form parses correctly"
}

test_unknown_flag_errors() {
  "$CHECK" --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero, not silently allow"
  pass "unknown CLI flag is rejected"
}

# --- fail-open -----------------------------------------------------------------

test_failopen_empty_stdin() {
  printf '' | "$CHECK" >/dev/null 2>&1 || fail "empty stdin must fail open (exit 0)"
  pass "fail-open: empty stdin"
}

test_failopen_garbage_stdin() {
  printf 'not json at all {{{' | "$CHECK" >/dev/null 2>&1 || fail "unparseable stdin must fail open (exit 0)"
  pass "fail-open: unparseable JSON on stdin"
}

test_failopen_missing_jq() {
  local dir fakebin rc real tool
  dir=$(fm_test_tmproot fm-crew-kill-check)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for tool in bash grep sed tr; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" bash -c "printf '%s' '{\"tool_input\":{\"command\":\"pkill -f \\\"node server.js\\\"\"}}' | '$CHECK'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must fail open (exit 0) rather than crash-deny, got exit $rc"
  pass "fail-open: missing jq on stdin path"
}

test_unrelated_command_is_fast_allow() {
  printf '%s' '{"tool_input":{"command":"ls -la"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1 \
    || fail "an unrelated command must pass through allowed"
  pass "stdin: unrelated command is a fast allow"
}

# --- --claude output shaping ---------------------------------------------------

test_claude_mode_stdout_empty_on_deny() {
  local out err rc errfile
  errfile="$MATRIX_TMP/claude-stderr.$$"
  out=$("$CHECK" --claude --command 'pkill -f "node server.js"' 2>"$errfile")
  rc=$?
  err=$(cat "$errfile" 2>/dev/null)
  [ "$rc" -eq 2 ] || fail "--claude deny must still exit 2, got $rc"
  [ -z "$out" ] || fail "--claude deny must leave stdout EMPTY (Claude Code only honors a stderr-only deny), got: $out"
  printf '%s' "$err" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || fail "--claude deny must put hookSpecificOutput.permissionDecision=deny on stderr: $err"
  pass "--claude: stdout empty, stderr carries hookSpecificOutput deny JSON"
}

test_default_mode_stdout_has_grok_json_on_deny() {
  local out rc
  out=$("$CHECK" --command 'tmux kill-server' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "default deny must exit 2, got $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 \
    || fail "default (non-claude) deny must put Grok's decision JSON on stdout: $out"
  pass "default mode: stdout carries Grok-shaped decision JSON on deny"
}

test_allow_is_silent_both_modes() {
  local out1 out2
  out1=$("$CHECK" --command 'kill 12345' 2>&1)
  out2=$("$CHECK" --claude --command 'kill 12345' 2>&1)
  [ -z "$out1" ] || fail "default allow must be silent, got: $out1"
  [ -z "$out2" ] || fail "--claude allow must be silent, got: $out2"
  pass "allow is silent on both stdout and stderr in default and --claude mode"
}

# --- fm-spawn.sh wiring: the Claude crewmate hook actually invokes the guard -

# Renders the REAL claude*) case-arm heredoc from bin/fm-spawn.sh (extracted
# verbatim, not reimplemented) against fixture WT/TASK_TMP/TURNEND/FM_ROOT
# values, so a future edit that breaks the generated JSON or drops the guard
# invocation fails this test, not just a live spawn.
test_fm_spawn_claude_settings_wires_the_guard() {
  local spawn_src fixture_root repo wt task_tmp turnend fm_root arm_block helpers settings command
  spawn_src="$ROOT/bin/fm-spawn.sh"
  fixture_root=$(fm_test_tmproot fm-crew-kill-spawn-wiring)
  repo="$fixture_root/repo"
  wt="$fixture_root/worktree"
  task_tmp="$fixture_root/tasktmp"
  turnend="$fixture_root/state/some-id.turn-ended"
  fm_root="$ROOT"
  mkdir -p "$task_tmp" "$(dirname "$turnend")"
  # A real worktree, not a plain `git init`: exclude_path (extracted below)
  # resolves `git -C "$WT" rev-parse --git-path` differently for a linked
  # worktree (.git is a file, path resolves absolute) than for an ordinary
  # repo (.git is a directory, path resolves relative) - matching real WT
  # shape here is what makes this fixture faithful to an actual crewmate spawn.
  fm_git_worktree "$repo" "$wt" fm-crew-kill-fixture

  # Extract the REAL claude*) case arm and its two helper functions verbatim
  # from bin/fm-spawn.sh (never reimplemented), so a future edit that breaks
  # the generated JSON or drops the guard invocation fails this test.
  arm_block=$(awk '/^    claude\*\)$/{p=1} p{print} p && /^      ;;$/{exit}' "$spawn_src")
  [ -n "$arm_block" ] || fail "could not extract the claude*) case arm from $spawn_src (markers moved?)"
  printf '%s\n' "$arm_block" | grep -qF 'fm-crew-kill-pretool-check.sh' \
    || fail "extracted claude*) case arm no longer references fm-crew-kill-pretool-check.sh"
  helpers=$(awk '/^shell_quote\(\) \{$/{p=1} /^json_escape\(\) \{$/{p=1} /^exclude_path\(\) \{$/{p=1} p{print} p && /^}$/{p=0}' "$spawn_src")
  printf '%s\n' "$helpers" | grep -qF 'shell_quote()' || fail "could not extract shell_quote() from $spawn_src (markers moved?)"
  printf '%s\n' "$helpers" | grep -qF 'json_escape()' || fail "could not extract json_escape() from $spawn_src (markers moved?)"
  printf '%s\n' "$helpers" | grep -qF 'exclude_path()' || fail "could not extract exclude_path() from $spawn_src (markers moved?)"

  # The extraction above pulls just the arm (pattern, body, and its `;;`), not
  # a full case statement, so wrap it back in one to execute it: HARNESS=claude
  # selects this exact arm the same way bin/fm-spawn.sh's own case does.
  HARNESS=claude WT="$wt" TASK_TMP="$task_tmp" TURNEND="$turnend" FM_ROOT="$fm_root" \
    bash -c "$helpers
case \"\$HARNESS\" in
$arm_block
esac" || fail "extracted claude*) case arm failed to execute against fixture paths"

  settings="$wt/.claude/settings.local.json"
  [ -f "$settings" ] || fail "extracted claude*) case arm did not write $settings"
  jq -e . "$settings" >/dev/null 2>&1 || fail "generated settings.local.json is not valid JSON: $(cat "$settings")"

  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "generated settings.local.json has no PreToolUse hook command"
  assert_contains "$command" 'fm-crew-kill-pretool-check.sh' "generated PreToolUse hook must invoke the shared crew kill-guard checker"
  assert_contains "$command" '--claude' "generated PreToolUse hook must pass --claude so stdout stays empty on deny"
  assert_contains "$command" "--sandbox '$wt'" "generated PreToolUse hook must pass the crew's own worktree as a --sandbox root"
  assert_contains "$command" "--sandbox '$task_tmp'" "generated PreToolUse hook must pass the crew's own per-task tmp root as a --sandbox root"

  local matcher
  matcher=$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$settings")
  [ "$matcher" = "Bash" ] || fail "generated PreToolUse hook must matcher-scope to Bash, got: $matcher"

  local stop_command
  stop_command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  assert_contains "$stop_command" "$turnend" "generated settings.local.json must still carry the existing turn-end Stop hook alongside the new PreToolUse hook"

  pass "fm-spawn.sh: a Claude crewmate's settings.local.json wires the crew kill-guard with --claude and both --sandbox roots, alongside the existing Stop hook"
}

# --- fm-brief.sh rule-7 brief-contract language --------------------------------

test_fm_brief_rule_carries_kill_contract() {
  local dir out_scout out_ship
  dir=$(fm_test_tmproot fm-crew-kill-brief)
  mkdir -p "$dir/data" "$dir/state"

  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$dir/data" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-brief.sh" kill-brief-scout-t1 some-repo --scout >/dev/null \
    || fail "fm-brief.sh --scout scaffold failed"
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$dir/data" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-brief.sh" kill-brief-ship-t2 some-repo >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold failed"

  out_scout=$(cat "$dir/data/kill-brief-scout-t1/brief.md")
  out_ship=$(cat "$dir/data/kill-brief-ship-t2/brief.md")

  assert_contains "$out_scout" 'exact PID' "scout brief must require PID-exact kills of self-spawned processes"
  assert_contains "$out_scout" 'kill <pid>' "scout brief must require PID-exact kills of self-spawned processes"
  assert_contains "$out_scout" 'tmux kill-server' "scout brief must forbid a bare tmux kill-server"
  assert_contains "$out_scout" '$!' "scout brief must point at recording a spawned process's \$! for later PID-exact kill"

  assert_contains "$out_ship" 'exact PID' "ship brief must require PID-exact kills of self-spawned processes"
  assert_contains "$out_ship" 'kill <pid>' "ship brief must require PID-exact kills of self-spawned processes"
  assert_contains "$out_ship" 'tmux kill-server' "ship brief must forbid a bare tmux kill-server"
  assert_contains "$out_ship" '$!' "ship brief must point at recording a spawned process's \$! for later PID-exact kill"

  pass "fm-brief.sh: both scout and ship scaffolds carry the PID-exact-kill / socket-scoped-tmux-teardown rule"
}

# --- shellcheck (belt-and-suspenders; CI/CONTRIBUTING.md also runs this) -----

test_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$CHECK" >/dev/null 2>&1 || fail "bin/fm-crew-kill-pretool-check.sh is not shellcheck-clean"
  pass "bin/fm-crew-kill-pretool-check.sh is shellcheck-clean"
}

test_full_matrix
test_sandbox_flag_allows_own_paths
test_sandbox_equals_form
test_command_equals_form
test_unknown_flag_errors
test_failopen_empty_stdin
test_failopen_garbage_stdin
test_failopen_missing_jq
test_unrelated_command_is_fast_allow
test_claude_mode_stdout_empty_on_deny
test_default_mode_stdout_has_grok_json_on_deny
test_allow_is_silent_both_modes
test_fm_spawn_claude_settings_wires_the_guard
test_fm_brief_rule_carries_kill_contract
test_shellcheck_clean
