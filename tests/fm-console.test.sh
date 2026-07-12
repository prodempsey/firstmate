#!/usr/bin/env bash
# fm-console idempotency checks for live harness panes versus stale shell panes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSOLE="$ROOT/bin/fm-console.sh"
TMP_ROOT=$(fm_test_tmproot fm-console)

make_stubs() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session)
    exit 0
    ;;
  list-windows)
    printf '%s\n' "${FM_FAKE_WINDOW:-fm-console}"
    exit 0
    ;;
  display-message)
    printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}"
    exit 0
    ;;
  kill-window)
    printf 'kill-window %s\n' "$*" >> "$FM_TMUX_LOG"
    exit 0
    ;;
  new-window)
    printf 'new-window %s\n' "$*" >> "$FM_TMUX_LOG"
    exit 0
    ;;
  send-keys)
    printf 'send-keys %s\n' "$*" >> "$FM_TMUX_LOG"
    exit 0
    ;;
  select-window)
    printf 'select-window %s\n' "$*" >> "$FM_TMUX_LOG"
    exit 0
    ;;
esac
printf 'unexpected tmux command: %s\n' "$*" >&2
exit 1
SH
  chmod +x "$fb/tmux"
  cat > "$fb/uuidgen" <<'SH'
#!/usr/bin/env bash
printf '00000000-0000-4000-8000-000000000000\n'
SH
  chmod +x "$fb/uuidgen"
  fm_fake_exit0 "$fb" claude codex grok
  printf '%s\n' "$fb"
}

test_live_harness_window_is_left_untouched() {
  local dir fb home log out rc
  dir="$TMP_ROOT/live"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=claude \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  out=$(cat "$dir/out")

  expect_code 0 "$rc" "live harness console should no-op successfully"
  assert_contains "$out" "firstmate:fm-console (already running)" "live harness console should preserve the existing message"
  [ ! -s "$log" ] || fail "live harness console was disturbed"$'\n'"$(cat "$log")"
  pass "fm-console: live harness window is left untouched"
}

test_stale_shell_window_is_killed_and_relaunched() {
  local dir fb home log out rc got
  dir="$TMP_ROOT/stale"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  out=$(cat "$dir/out")
  got=$(cat "$log")

  expect_code 0 "$rc" "stale shell console should relaunch successfully"
  assert_contains "$got" "kill-window -t firstmate:fm-console" "stale shell window should be killed before relaunch"
  assert_contains "$got" "new-window -d -t firstmate -n fm-console -c $home" "stale shell window should be recreated"
  assert_contains "$got" "send-keys -t firstmate:fm-console -l claude" "stale shell relaunch should send the harness command"
  assert_contains "$out" "firstmate:fm-console (started, session 00000000-0000-4000-8000-000000000000)" "stale shell relaunch should report a fresh start"
  pass "fm-console: stale shell window is killed and relaunched"
}

test_settings_without_backups_selects_primary() {
  local dir fb home user_home log rc got config auth_target
  dir="$TMP_ROOT/no-backups-field"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  user_home="$dir/user-home"; mkdir -p "$user_home/.codex"
  printf '%s\n' '{"tokens":"test-only"}' > "$user_home/.codex/auth.json"
  log="$dir/tmux.log"; : > "$log"
  printf '%s\n' '{"fmModel":"gpt-primary-model","fmPersonality":"standard"}' \
    > "$home/state/cockpit-settings.json"

  PATH="$fb:$PATH" HOME="$user_home" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  got=$(cat "$log")
  config=$(cat "$home/state/codex-home/config.toml")
  auth_target=$(readlink "$home/state/codex-home/auth.json")

  expect_code 0 "$rc" "settings without fmModelBackups should remain valid"
  assert_contains "$got" "send-keys -t firstmate:fm-console -l CODEX_HOME=\"$home/state/codex-home\" codex --model gpt-primary-model" \
    "settings without fmModelBackups did not launch the configured primary"
  assert_contains "$config" 'model = "gpt-primary-model"' "isolated Codex config did not record the selected model"
  assert_contains "$config" 'model_reasoning_effort = "xhigh"' "isolated Codex config lost its reasoning policy"
  assert_contains "$config" "[projects.\"$home\"]" "isolated Codex config lost the FirstMate trust entry"
  [ "$auth_target" = "$user_home/.codex/auth.json" ] || \
    fail "isolated Codex home did not symlink the real credential store"
  pass "fm-console keeps the isolated Codex home when fmModelBackups is absent"
}

test_disabled_primary_provider_selects_grok_backup() {
  local dir fb home log out err rc got
  dir="$TMP_ROOT/grok-backup"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  log="$dir/tmux.log"; : > "$log"
  printf '%s\n' '{"fmModel":"gpt-5.6-sol","fmModelBackups":["grok-4.5","claude-sonnet-5"]}' \
    > "$home/state/cockpit-settings.json"
  printf '%s\n' '{"version":1,"providers":{"openai":{"disabled":true,"reason":"usage limit"}},"harnesses":{}}' \
    > "$home/state/provider-failover.json"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  out=$(cat "$dir/out")
  err=$(cat "$dir/err")
  got=$(cat "$log")

  expect_code 0 "$rc" "disabled primary provider should select a console backup"
  assert_contains "$err" "selected backup #1 'grok-4.5' (grok)" "console did not report the selected Grok backup"
  assert_contains "$got" "send-keys -t firstmate:fm-console -l grok --always-approve --model grok-4.5" \
    "gpt primary did not map to Codex and fall through to the Grok backup"
  assert_contains "$out" "firstmate:fm-console (started, grok)" "console did not report a Grok start"
  pass "fm-console maps gpt to Codex and selects the Grok backup when OpenAI is disabled"
}

test_backup_falls_through_to_claude_mapping() {
  local dir fb home log err rc got
  dir="$TMP_ROOT/claude-backup"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  log="$dir/tmux.log"; : > "$log"
  printf '%s\n' '{"fmModel":"gpt-5.6-sol","fmModelBackups":["grok-4.5","custom-console-model"]}' \
    > "$home/state/cockpit-settings.json"
  printf '%s\n' '{"version":1,"providers":{"openai":{"disabled":true},"xai":{"disabled":true}},"harnesses":{}}' \
    > "$home/state/provider-failover.json"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  err=$(cat "$dir/err")
  got=$(cat "$log")

  expect_code 0 "$rc" "console should fall through to a Claude-mapped backup"
  assert_contains "$err" "selected backup #2 'custom-console-model' (claude)" \
    "console did not map the non-gpt/non-grok backup to Claude"
  assert_contains "$got" "send-keys -t firstmate:fm-console -l claude --dangerously-skip-permissions --model custom-console-model" \
    "non-gpt/non-grok backup did not launch through Claude"
  pass "fm-console maps an otherwise-prefixed backup model to Claude"
}

test_all_unavailable_does_not_kill_live_console() {
  local dir fb home log out rc
  dir="$TMP_ROOT/live-all-disabled"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  log="$dir/tmux.log"; : > "$log"
  printf '%s\n' '{"fmModel":"gpt-5.6-sol","fmModelBackups":["grok-4.5"]}' \
    > "$home/state/cockpit-settings.json"
  printf '%s\n' '{"version":1,"providers":{"openai":{"disabled":true},"xai":{"disabled":true}},"harnesses":{}}' \
    > "$home/state/provider-failover.json"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=codex \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  out=$(cat "$dir/out")

  expect_code 0 "$rc" "live console should remain untouched even when new candidates are disabled"
  assert_contains "$out" "firstmate:fm-console (already running)" "live console should still no-op"
  [ ! -s "$log" ] || fail "all-disabled selection disturbed a live console"$'\n'"$(cat "$log")"
  pass "fm-console never kills a live healthy console to apply boot-time failover"
}

test_all_unavailable_fails_without_killing_stale_window() {
  local dir fb home log err rc
  dir="$TMP_ROOT/stale-all-disabled"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  log="$dir/tmux.log"; : > "$log"
  printf '%s\n' '{"fmModel":"gpt-5.6-sol","fmModelBackups":["grok-4.5"]}' \
    > "$home/state/cockpit-settings.json"
  printf '%s\n' '{"version":1,"providers":{"openai":{"disabled":true},"xai":{"disabled":true}},"harnesses":{}}' \
    > "$home/state/provider-failover.json"

  set +e
  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  err=$(cat "$dir/err")

  expect_code 1 "$rc" "all unavailable console candidates should fail"
  assert_contains "$err" "no available model candidate" "all-unavailable console failure was not clear"
  assert_not_contains "$(cat "$log")" "kill-window" "failed selection should not kill the existing stale window"
  pass "fm-console fails clearly before changing a window when every candidate is unavailable"
}

# --- handoff seed gating ----------------------------------------------------
# Regression cover for the stale-seed bug: a handoff brief left on disk made every
# later console start (a crash relaunch, a manual run) boot as if the captain had
# just requested a hand-off, replaying superseded state as current.

# handoff_home <dir> [request-age-seconds] - a home with a handoff brief on disk,
# plus a request token when an age is given (negative = requested before the brief).
handoff_home() {
  local dir=$1 age=${2:-} home now req_ms
  home="$dir/home"; mkdir -p "$home/state"
  printf '%s\n' 'FirstMate handoff - superseded state' > "$home/state/fm-handoff.md"
  if [ -n "$age" ]; then
    now=$(date +%s)
    req_ms=$(( (now - age) * 1000 ))
    printf '{"requestedAtMs":%s,"requestedAt":"stub"}\n' "$req_ms" \
      > "$home/state/fm-handoff.request.json"
  fi
  printf '%s\n' "$home"
}

test_stale_brief_without_request_is_not_seeded() {
  local dir fb home log got rc
  dir="$TMP_ROOT/stale-brief"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(handoff_home "$dir")
  touch -d '14 hours ago' "$home/state/fm-handoff.md" 2>/dev/null || true
  log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  got=$(cat "$log")

  expect_code 0 "$rc" "an ordinary console start should still launch"
  assert_not_contains "$got" "handoff brief" "a stale brief with no request must not be seeded"
  assert_not_contains "$got" "fm-handoff.md" "a stale brief with no request must not reach the boot prompt"
  assert_contains "$got" "Read AGENTS.md, data/captain.md, and data/projects.md now" \
    "an unseeded start should use the plain boot prompt"
  assert_present "$home/state/fm-handoff.md" "an unseeded start should leave the brief alone"
  assert_grep 'stale-brief-no-request' "$home/state/handoff/events.jsonl" \
    "the skipped seed should be recorded as lifecycle evidence"
  pass "fm-console: a stale handoff brief with no request is never seeded"
}

test_fresh_request_is_seeded_and_consumed() {
  local dir fb home log got rc id
  dir="$TMP_ROOT/fresh-request"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(handoff_home "$dir" 5)
  log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  got=$(cat "$log")

  expect_code 0 "$rc" "a requested hand-off should launch"
  assert_contains "$got" "A handoff brief from the outgoing FirstMate is at $home/state/fm-handoff.md" \
    "a fresh request should seed the boot prompt from the brief"
  assert_absent "$home/state/fm-handoff.request.json" \
    "a consumed request token must not survive the respawn it seeded"
  assert_grep '"event":"consumed"' "$home/state/handoff/events.jsonl" \
    "the consumed hand-off should be recorded as lifecycle evidence"
  id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$home/state/handoff/events.jsonl" | head -1)
  assert_present "$home/state/handoff/$id/request.json" "the request token should be archived under its id"
  assert_present "$home/state/handoff/$id/brief.md" "the seeded brief should be archived under its id"
  pass "fm-console: a fresh handoff request is seeded end to end and consumed"
}

test_consumed_request_is_not_replayed_by_a_relaunch() {
  local dir fb home log got rc
  dir="$TMP_ROOT/replay"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(handoff_home "$dir" 5)
  log="$dir/tmux.log"; : > "$log"

  # First start: the genuine hand-off respawn, which consumes the token.
  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out1" 2>"$dir/err1"
  # Second start: the crash relaunch that used to inherit the same brief again.
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out2" 2>"$dir/err2"; rc=$?
  got=$(cat "$log")

  expect_code 0 "$rc" "a relaunch after a completed hand-off should still launch"
  assert_not_contains "$got" "fm-handoff.md" "a consumed request must never seed a second console"
  assert_contains "$got" "Read AGENTS.md, data/captain.md, and data/projects.md now" \
    "the relaunch should use the plain boot prompt"
  pass "fm-console: a consumed handoff request is never replayed by a later start"
}

test_pending_request_with_older_brief_is_not_seeded() {
  local dir fb home log got rc
  dir="$TMP_ROOT/brief-older"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(handoff_home "$dir" 0)
  # Brief predates the request: the outgoing console has not written the new one yet.
  touch -d '2 hours ago' "$home/state/fm-handoff.md" 2>/dev/null || true
  log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  got=$(cat "$log")

  expect_code 0 "$rc" "a pending-not-ready hand-off should still launch"
  assert_not_contains "$got" "fm-handoff.md" "a brief older than the request must not be seeded"
  assert_present "$home/state/fm-handoff.request.json" \
    "a pending-not-ready request must stay claimable so the hand-off can finish"
  pass "fm-console: a request whose brief is older than it is not seeded"
}

test_explicit_seed_override_is_honored() {
  local dir fb home log got rc
  dir="$TMP_ROOT/explicit-seed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  printf '%s\n' 'explicit brief' > "$dir/other-brief.md"
  log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    FM_CONSOLE_SEED="$dir/other-brief.md" "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  got=$(cat "$log")

  expect_code 0 "$rc" "an explicit seed should launch"
  assert_contains "$got" "A handoff brief from the outgoing FirstMate is at $dir/other-brief.md" \
    "an explicit FM_CONSOLE_SEED should still seed the boot prompt"
  pass "fm-console: an explicit FM_CONSOLE_SEED override is honored"
}

test_explicit_missing_seed_forces_a_clean_boot() {
  local dir fb home log got rc
  dir="$TMP_ROOT/no-seed-path"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(handoff_home "$dir" 5)
  log="$dir/tmux.log"; : > "$log"

  # The cockpit points FM_CONSOLE_SEED at a path it never creates to force a clean boot.
  PATH="$fb:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=bash \
    FM_CONSOLE_SEED="$home/state/.fm-handoff-no-seed" "$CONSOLE" >"$dir/out" 2>"$dir/err"; rc=$?
  got=$(cat "$log")

  expect_code 0 "$rc" "the cockpit no-seed path should launch"
  assert_not_contains "$got" "handoff brief" "a non-existent explicit seed must force a clean boot"
  assert_present "$home/state/fm-handoff.request.json" \
    "a forced clean boot must not consume the pending request"
  pass "fm-console: a non-existent explicit seed forces a clean boot"
}

test_live_harness_window_is_left_untouched
test_stale_shell_window_is_killed_and_relaunched
test_settings_without_backups_selects_primary
test_disabled_primary_provider_selects_grok_backup
test_backup_falls_through_to_claude_mapping
test_all_unavailable_does_not_kill_live_console
test_all_unavailable_fails_without_killing_stale_window
test_stale_brief_without_request_is_not_seeded
test_fresh_request_is_seeded_and_consumed
test_consumed_request_is_not_replayed_by_a_relaunch
test_pending_request_with_older_brief_is_not_seeded
test_explicit_seed_override_is_honored
test_explicit_missing_seed_forces_a_clean_boot
