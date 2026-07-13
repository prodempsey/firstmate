#!/usr/bin/env bash
# Behavior tests for the additive Needs FirstMate local-state reconciler.
set -u

# shellcheck disable=SC1091 # Dynamic test-library path is resolved from BASH_SOURCE.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-nf-reconcile.sh"
ACK="$ROOT/bin/fm-nf-ack.sh"
TMP_ROOT=$(fm_test_tmproot fm-nf-reconcile)

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_task() {
  local home=$1 id=$2 status=$3 kind=${4:-ship}
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$home/worktrees/$id" \
    "project=demo" \
    "harness=codex" \
    "kind=$kind" \
    "mode=local-only" \
    "yolo=off"
  printf '%s\n' "$status" > "$home/state/$id.status"
}

run_reconcile() {
  local home=$1
  shift
  FM_HOME="$home" "$RECONCILE" "$@"
}

run_ack() {
  local home=$1
  shift
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/curl" <<'SH'
#!/usr/bin/env bash
body=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -d ]; then body=$2; shift 2; else shift; fi
done
if [ -n "$body" ]; then printf '%s\n' "$body" > "$FM_TEST_ATTENTION_FILE"; else cat "$FM_TEST_ATTENTION_FILE"; fi
SH
  chmod +x "$home/fakebin/curl"
  FM_TEST_ATTENTION_FILE="$home/attention.json" PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ACK" "$@"
}

test_unhandled_terminal_reemits_until_acked() {
  local home first_out second_out
  home=$(new_home reemits)
  write_task "$home" ready-a1 'done: ready in branch fm/ready-a1 @ abcdef1'

  first_out=$(run_reconcile "$home")
  assert_contains "$first_out" 'NEEDS FIRSTMATE: 1 unhandled - ready-a1' \
    "first check should surface the unhandled terminal task"
  second_out=$(run_reconcile "$home")
  assert_contains "$second_out" 'NEEDS FIRSTMATE: 1 unhandled - ready-a1' \
    "later check should re-surface an unchanged unacknowledged task"
  pass "unchanged unacknowledged terminal status re-emits"
}

test_reviewed_unchanged_remains_open() {
  local home out ledger_lines
  home=$(new_home acked)
  write_task "$home" ack-me-b2 'blocked: waiting for a credential'
  run_reconcile "$home" >/dev/null

  run_ack "$home" ack-me-b2 >/dev/null
  run_ack "$home" ack-me-b2 >/dev/null
  ledger_lines=$(wc -l < "$home/state/.nf-handled" | tr -d ' ')
  [ "$ledger_lines" -eq 1 ] || fail "idempotent ack should write one ledger row"
  out=$(run_reconcile "$home")
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled' "reviewed task must remain open"
  pass "reviewed unchanged card remains open"
}

test_changed_fingerprint_reemits() {
  local home out old_fingerprint new_fingerprint
  home=$(new_home changed)
  write_task "$home" change-c3 'needs-decision: choose A or B'
  run_reconcile "$home" >/dev/null
  run_ack "$home" change-c3 >/dev/null
  old_fingerprint=$(cut -f2 "$home/state/.nf-handled")

  printf '%s\n' 'failed: option A failed during validation' >> "$home/state/change-c3.status"
  out=$(run_reconcile "$home")
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled - change-c3' \
    "changed terminal signal should surface again"
  new_fingerprint=$(run_reconcile "$home" list | sed -n 's/^  fingerprint: //p')
  [ "$old_fingerprint" != "$new_fingerprint" ] || fail "changed signal should change fingerprint"
  pass "changed fingerprint re-emits"
}

test_local_state_without_board_data() {
  local home out
  home=$(new_home local-only)
  write_task "$home" local-d4 'done: local state is authoritative'
  out=$(FM_NF_BOARD_URL='http://127.0.0.1:1/unreachable' run_reconcile "$home" list)
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled' "local state should produce a list"
  assert_contains "$out" 'signal: done: local state is authoritative' \
    "list should expose the local terminal signal"
  assert_contains "$out" "meta: $home/state/local-d4.meta" "list should expose local triage paths"
  pass "local state works without board data"
}

test_install_is_idempotent() {
  local home shim first_sum second_sum first_mtime second_mtime out
  home=$(new_home install)
  write_task "$home" install-e5 'done: install test'
  run_reconcile "$home" install >/dev/null
  shim="$home/state/needs-firstmate.check.sh"
  assert_present "$shim" "install should create the watcher check shim"
  [ -x "$shim" ] || fail "installed watcher check shim should be executable"
  first_sum=$(cksum "$shim")
  first_mtime=$(stat -c %Y "$shim")
  sleep 1
  run_reconcile "$home" install >/dev/null
  second_sum=$(cksum "$shim")
  second_mtime=$(stat -c %Y "$shim")
  [ "$first_sum" = "$second_sum" ] || fail "reinstall should preserve shim content"
  [ "$first_mtime" = "$second_mtime" ] || fail "reinstall should not churn shim mtime"
  out=$("$shim")
  assert_contains "$out" 'NEEDS FIRSTMATE: 1 unhandled - install-e5' \
    "installed shim should execute the reconciler through the watcher contract"
  pass "install creates an idempotent check shim"
}

test_only_matching_local_terminal_tasks_are_listed() {
  local home out
  home=$(new_home filter)
  write_task "$home" working-f6 'working: still active'
  write_task "$home" secondmate-f7 'done: persistent supervisor idle' secondmate
  printf '%s\n' 'done: orphan status' > "$home/state/orphan-f8.status"
  out=$(run_reconcile "$home" list)
  [ "$out" = 'NEEDS FIRSTMATE: none' ] || fail "ineligible local signals should be excluded, got: $out"
  pass "reconciler requires matching task state and excludes secondmates"
}

test_attention_flags_call_api() {
  local home out
  home=$(new_home phase-two)
  write_task "$home" phase-g9 'done: waiting for future ownership support'
  out=$(run_ack "$home" --to-captain order-1 phase-g9)
  assert_contains "$out" 'still open' "to-captain should preserve open wording"
  [ "$(jq -r '.event + ":" + .open_item_id' "$home/attention.json")" = 'to_captain:order-1' ] || fail "to-captain API payload mismatch"
  out=$(run_ack "$home" --reworking successor-1 phase-g9)
  [ "$(jq -r '.event + ":" + .successor_id' "$home/attention.json")" = 'reworking:successor-1' ] || fail "reworking API payload mismatch"
  pass "attention ownership flags call and verify the API"
}

# The card is keyed by HOME NAME, so this command cannot address a card for a home it cannot
# name. A home that basenames into a garbage path segment produced a malformed URL, and the
# 404 that came back read as "the board rejected the write" rather than "firstmate built a
# bad URL" - an invisible failure in the ONE writer of the captain's attention column, which
# is how a captain decision gets dropped. It must fail loudly instead, and say where it was
# writing when it failed.
test_ack_refuses_a_home_it_cannot_name() {
  local home out status
  home=$(new_home ack-badhome)
  write_task "$home" phase-g9 'done: ready in branch fm/phase-g9'
  out=$(FM_HOME=relative/path "$ACK" phase-g9 2>&1); status=$?
  expect_code 2 "$status" "a relative FM_HOME must be refused, not turned into a malformed URL"
  assert_contains "$out" 'FM_HOME must be an absolute path' "the refusal must name the problem"
  out=$(FM_HOME=/ "$ACK" phase-g9 2>&1); status=$?
  expect_code 2 "$status" "a home with no derivable name must be refused"
  assert_contains "$out" 'cannot derive a board home name' "the refusal must name the problem"
  pass "fm-nf-ack: refuses loudly rather than emitting a malformed card URL"
}

test_ack_failure_names_the_url_it_tried() {
  local home out status
  home=$(new_home ack-failurl)
  write_task "$home" phase-g9 'done: ready in branch fm/phase-g9'
  mkdir -p "$home/failbin"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$home/failbin/curl"
  chmod +x "$home/failbin/curl"
  out=$(PATH="$home/failbin:$PATH" FM_HOME="$home" "$ACK" phase-g9 2>&1); status=$?
  expect_code 1 "$status" "an attention write that fails must fail the command"
  assert_contains "$out" "/api/card/$(basename "$home")/phase-g9/attention" \
    "a failed attention write must report the URL it tried, or a wrong home reads exactly like a down board"
  pass "fm-nf-ack: a failed attention write names the card URL it tried"
}

test_unhandled_terminal_reemits_until_acked
test_ack_refuses_a_home_it_cannot_name
test_ack_failure_names_the_url_it_tried
test_reviewed_unchanged_remains_open
test_changed_fingerprint_reemits
test_local_state_without_board_data
test_install_is_idempotent
test_only_matching_local_terminal_tasks_are_listed
test_attention_flags_call_api
