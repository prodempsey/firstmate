#!/usr/bin/env bash
# Behavior tests for the primary turn-end supervision guard (docs/turnend-guard.md).
#
# Two layers:
#   PREDICATE  - bin/fm-supervision-lib.sh, the shared beacon/status computation
#                used by fm-guard.sh and by the hook's banner details.
#   HOOK       - bin/fm-turnend-guard.sh, the shared primary hook predicate that
#                scopes in-flight work to the PRIMARY checkout only and requires
#                a live, identity-matched watcher lock plus a fresh beacon.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard)
fm_git_identity fmtest fmtest@example.invalid

REQUIRED_REASON='resume supervision with bin/fm-watch-arm.sh as its own Claude Code background task'

# --- PREDICATE: bin/fm-supervision-lib.sh -----------------------------------

test_predicate_healthy_no_inflight() {
  local state="$TMP_ROOT/pred-empty/state"
  mkdir -p "$state"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate reported unhealthy with zero in-flight tasks"
  fi
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "expected zero in-flight, got $FM_SUP_IN_FLIGHT"
  pass "fm_supervision_unhealthy: false with no state/*.meta at all"
}

test_predicate_unhealthy_no_beacon() {
  local state="$TMP_ROOT/pred-nobeat/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon never seen"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected 1 in-flight, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "beacon absent must not read as fresh"
  [ "$FM_SUP_BEACON_DESC" = never ] || fail "beacon description should be 'never', got $FM_SUP_BEACON_DESC"
  pass "fm_supervision_unhealthy: true with in-flight task and no beacon ever"
}

test_predicate_unhealthy_stale_beacon() {
  local state="$TMP_ROOT/pred-stale/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch -t 202001010000 "$state/.last-watcher-beat"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon far outside grace"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "an ancient beacon must not read as fresh"
  pass "fm_supervision_unhealthy: true with in-flight task and a beacon far outside the grace window"
}

test_predicate_healthy_fresh_beacon() {
  local state="$TMP_ROOT/pred-fresh/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate fired despite a fresh beacon"
  fi
  [ "$FM_SUP_WATCHER_FRESH" = true ] || fail "a beacon touched just now must read as fresh"
  pass "fm_supervision_unhealthy: false with in-flight task and a fresh beacon"
}

test_predicate_queue_pending_flag() {
  local state="$TMP_ROOT/pred-queue/state"
  mkdir -p "$state"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = false ] || fail "empty/absent wake queue must not read as pending"
  printf 'record\n' > "$state/.wake-queue"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = true ] || fail "a non-empty wake queue must read as pending"
  pass "fm_supervision_status: FM_SUP_QUEUE_PENDING tracks state/.wake-queue"
}

# --- HOOK: bin/fm-turnend-guard.sh ------------------------------------------
#
# Each scenario gets its own directory carrying a copy of the two guard scripts
# under bin/, so the hook (invoked by absolute path) resolves its own FM_ROOT to
# that scenario dir regardless of the test's cwd.

install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-turnend-guard-grok.sh"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  # The live needs_firstmate read: the attention lib and everything it sources.
  cp "$ROOT/bin/fm-nf-attention-lib.sh" "$dir/bin/fm-nf-attention-lib.sh"
  cp "$ROOT/bin/fm-nf-lib.sh" "$dir/bin/fm-nf-lib.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-backend.sh" "$dir/bin/fm-backend.sh"
  cp "$ROOT/bin/fm-fleet-triage-lib.sh" "$dir/bin/fm-fleet-triage-lib.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}

mark_codex_hook_root() {
  local dir=$1
  mkdir -p "$dir/.codex"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-turnend-guard.sh"}]}]}}\n' > "$dir/.codex/hooks.json"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the hook's scoping check requires to treat it as primary.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape as primary, plus the .fm-secondmate-home marker bin/fm-home-seed.sh
# writes at seed time (regardless of treehouse-lease or git-clone acquisition).
make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree` of a base repo - the shape bin/fm-spawn.sh
# always hands crewmate/scout tasks working on firstmate itself. git-dir and
# git-common-dir differ here, unlike a plain checkout.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-guard-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

run_hook() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

# --- HOOK: the second, independent block reason - finished work left unattended -----
#
# The guard's whole point is that it is the only thing in this system that can say no. For a
# long time it said no to exactly one thing (supervision off), so arming the watcher was a
# complete turn exit however much finished crew work was piled up - and the primary took that
# exit, holding 61 ownerless items and five unlanded branches. These cases pin the second
# reason: a non-empty needs_firstmate lane blocks too.
#
# The lane is read LIVE from state/<id>.meta plus state/<id>.status and the triage ledger
# through fm_nf_unattended_ids (bin/fm-nf-attention-lib.sh), never from the duty pass's
# volatile cache, so the fixtures here are real task state plus real ledger rows - the same
# level-triggered inputs bin/fm-nf-reconcile.sh reads.

# A live terminal signal: a task meta plus a status whose last line carries a terminal verb.
write_nf_signal() {  # <dir> <id> [status-line]
  printf 'window=fm-%s\n' "$2" > "$1/state/$2.meta"
  printf '%s\n' "${3:-done: ready in branch fm/$2}" > "$1/state/$2.status"
}

# A recorded triage disposition for one live signal, bound to its current evidence version
# exactly as bin/fm-fleet-triage-record.sh binds it, appended straight to the ledger.
record_nf_outcome() {  # <dir> <id> <outcome> <link> <reason> <review-after>
  local dir=$1 id=$2 outcome=$3 link=$4 reason=$5 review_after=$6 ev
  mkdir -p "$dir/data"
  ev=$(bash -c '. "$1/bin/fm-nf-attention-lib.sh"
    fp=$(fm_nf_current_fingerprint "$1/state" "$2") || exit 1
    fm_nf_attention_evidence_version "$2" "$fp"' _ "$dir" "$id") \
    || fail "could not compute evidence version for $id"
  jq -nc --arg id "needs_firstmate:$id" --arg o "$outcome" --arg l "$link" \
    --arg r "$reason" --arg ra "$review_after" --arg ev "$ev" \
    '{item_id: $id, event: "outcome", outcome_type: $o, evidence_version: $ev}
     + (if $l != "" then {outcome_link: $l} else {} end)
     + (if $r != "" then {outcome_reason: $r} else {} end)
     + (if $ra != "" then {review_after: $ra} else {} end)' \
    >> "$dir/data/fleet-triage.jsonl"
}

last_guard_log() {  # <dir>
  tail -n 1 "$1/state/.turnend-guard.log" 2>/dev/null
}

# A primary with healthy supervision: one task in flight, a live identity-matched watcher
# lock, and a fresh beacon. Anything this guard says from here is about the WORK, not the
# watcher. Prints the watcher pid; the caller must kill it.
start_healthy_watcher() {  # <dir>
  local dir=$1 pid identity
  : > "$dir/state/task1.meta"
  # stdout MUST be closed off: this helper runs inside a command substitution, and a
  # background job holding that pipe open makes $(...) wait out the whole sleep - which
  # would hand the caller a pid that is already dead, i.e. exactly the unhealthy watcher
  # these cases exist to rule out.
  sleep 60 >/dev/null 2>&1 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf '%s\n' "$pid"
}

stop_watcher() {  # <pid>
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# The acceptance case, and the one the incident is about: supervision is perfectly healthy,
# and the turn still must not end, because finished crew work is sitting unattended. The
# block message must name the items and say plainly that re-arming the watcher does not
# satisfy the condition.
test_hook_blocks_on_unattended_finished_work() {
  local dir pid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-block")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-a1 'done: ready in branch fm/ship-a1'
  write_nf_signal "$dir" probe-b2 'needs-decision: two rollout options'
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "hook must block when finished crew work is unattended, even with supervision healthy"
  assert_contains "$out" "TURN WOULD END WITH FINISHED WORK UNATTENDED" "block banner must name the unattended work"
  assert_contains "$out" "2 crew signal(s)" "block banner must say how much work is unattended"
  assert_contains "$out" "ship-a1" "block banner must list the unattended item ids"
  assert_contains "$out" "probe-b2" "block banner must list the unattended item ids"
  assert_contains "$out" "RE-ARMING THE WATCHER DOES NOT SATISFY THIS CONDITION" "block banner must say the watcher is not the exit"
  assert_not_contains "$out" "SUPERVISION IS OFF" "a healthy watcher must not be reported as down"
  local log
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = blocked ] || fail "decision log must record the block: $log"
  [ "$(printf '%s' "$log" | jq -r '.reason')" = unattended-needs-firstmate ] || fail "decision log must record the block reason: $log"
  [ "$(printf '%s' "$log" | jq -r '.needs_firstmate')" = 2 ] || fail "decision log must record the lane count: $log"
  printf '%s' "$log" | jq -r '.nf_items' | grep -q 'ship-a1' || fail "decision log must carry the item digest: $log"
  [ "$(printf '%s' "$log" | jq -r '.loop_protection')" = false ] || fail "decision log must record loop protection state: $log"
  pass "fm-turnend-guard: blocks on live unattended terminal signals despite a live, fresh watcher"
}

# THE CAPTAIN'S RULING, pinned: the predicate reads reality at the moment of the turn-end
# evaluation, never the duty pass's cached summary. A stale cache in either direction - one
# claiming work while the fleet is clear, or one claiming clear while work sits unattended -
# must change nothing.
test_hook_reads_live_state_not_the_duty_cache() {
  local dir pid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-nocache")
  pid=$(start_healthy_watcher "$dir")
  # Stale cache says work; live state is clear -> the turn must end.
  printf '{"ok":true,"needs_firstmate":7}\n' > "$dir/state/.triage-duty-last.json"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "a stale cache claiming work must not block a clear fleet"
  [ -z "$out" ] || fail "hook trusted a stale cache over live state: $out"
  # Stale cache says clear; live state has an unattended signal -> the turn must not end.
  printf '{"ok":true,"needs_firstmate":0}\n' > "$dir/state/.triage-duty-last.json"
  write_nf_signal "$dir" fresh-c3
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "a stale cache claiming clear must not hide live unattended work"
  assert_contains "$out" "fresh-c3" "the live read must surface the item the cache missed"
  pass "fm-turnend-guard: level-triggered from live task state; the duty cache is not consulted"
}

# The healthy path must stay completely silent: a new alarm that fires on a clear fleet is a
# new alarm nobody reads. A working task is not a terminal signal, and a secondmate's
# terminal-looking status is not crew work either (fm_nf_current_fingerprint excludes it).
test_hook_silent_when_lane_is_clear() {
  local dir pid out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-clear")
  pid=$(start_healthy_watcher "$dir")
  printf 'window=fm-busy-d4\n' > "$dir/state/busy-d4.meta"
  printf 'working: implementing the parser\n' > "$dir/state/busy-d4.status"
  printf 'window=fm-sm-ops\nkind=secondmate\n' > "$dir/state/sm-ops.meta"
  printf 'done: routed answer via status\n' > "$dir/state/sm-ops.status"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "hook must stay silent with no unattended terminal signal and a live watcher"
  [ -z "$out" ] || fail "hook produced output on the healthy path: $out"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed ] || fail "permitted turn ends must be on the record too: $log"
  pass "fm-turnend-guard: silent with a clear lane and a live watcher, and the permit is logged"
}

# A recorded disposition that still holds discharges the block; one that no longer holds
# (an expired hold, or a legacy hold whose review date no clock can read) does not. This is
# the anti-gaming half of the gate: `hold` must never be a permanent mute button again.
test_hook_disposition_and_hold_expiry() {
  local dir pid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-dispo")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" landed-e5
  record_nf_outcome "$dir" landed-e5 resolved local-main-abc1234 '' ''
  write_nf_signal "$dir" parked-f6 'blocked: waiting on vendor'
  record_nf_outcome "$dir" parked-f6 held '' 'vendor ticket open' 2999-01-01
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "a resolved item and a live future-dated hold must not block"
  [ -z "$out" ] || fail "hook blocked on dispositioned work: $out"
  write_nf_signal "$dir" stale-g7
  record_nf_outcome "$dir" stale-g7 held '' 'parked long ago' 2020-01-01
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "an expired hold must return its item to the blocking set"
  assert_contains "$out" "stale-g7" "the expired hold's item must be named"
  record_nf_outcome "$dir" stale-g7 held '' 'muted forever' 'next bug-triage pass or captain returns'
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "a legacy hold whose review date no clock can read must not mute its item"
  assert_contains "$out" "stale-g7" "the unreviewable hold's item must be named"
  pass "fm-turnend-guard: dispositions discharge the block; expired and unreviewable holds do not"
}

test_hook_blocks_on_both_reasons_at_once() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-both")
  write_nf_signal "$dir" task1
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when supervision is off AND work is unattended"
  assert_contains "$out" "TURN WOULD END BLIND" "the watcher alarm must still fire"
  assert_contains "$out" "TURN WOULD END WITH FINISHED WORK UNATTENDED" "the unattended-work alarm must fire alongside it"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.reason')" = 'watcher-down+unattended-needs-firstmate' ] \
    || fail "decision log must record both block reasons: $log"
  pass "fm-turnend-guard: the two block reasons are independent and both report"
}

# FAIL OPEN. A guard on the live supervision path that can wedge the primary is worse than
# the bug it catches: any failure to read the live state must permit the turn to end,
# silently, exactly as the guard behaved before this lane existed.
test_hook_fails_open_when_live_read_is_unavailable() {
  local dir pid out status
  # The attention lib is missing outright (a partial checkout).
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-nolib")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" hidden-h8
  rm "$dir/bin/fm-nf-attention-lib.sh"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "a missing attention lib must fail open, not wedge the primary"
  [ -z "$out" ] || fail "hook produced output with the attention lib missing: $out"
  # The attention lib is present but broken (a syntax error mid-upgrade).
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-brokenlib")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" hidden-i9
  printf 'if [\n' > "$dir/bin/fm-nf-attention-lib.sh"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "a broken attention lib must fail open, not wedge the primary"
  [ -z "$out" ] || fail "hook produced output with a broken attention lib: $out"
  pass "fm-turnend-guard: a missing or broken live-read library fails open"
}

# The other direction is NOT open: a corrupt ledger must not hide work. The fold skips
# malformed rows, so an item whose only "disposition" is a garbage line stays unattended.
test_hook_malformed_ledger_rows_do_not_hide_work() {
  local dir pid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-badledger")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" open-j1
  mkdir -p "$dir/data"
  printf '{not json at all\nplain text row\n' > "$dir/data/fleet-triage.jsonl"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "malformed ledger rows must fail SAFE for the work: the item stays blocking"
  assert_contains "$out" "open-j1" "the item hidden behind ledger garbage must be named"
  pass "fm-turnend-guard: ledger corruption cannot silently discharge the block"
}

# Away mode: the away daemon owns supervision and escalation while state/.afk exists; a
# turn-end block would fight the daemon's own batching loop.
test_hook_triage_block_is_off_while_away() {
  local dir pid out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-afk")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" waiting-k2
  : > "$dir/state/.afk"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "hook must not block on triage state while away mode owns supervision"
  [ -z "$out" ] || fail "hook produced triage output while away: $out"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.nf_gate')" = afk ] || fail "the stand-down must be honest in the log: $log"
  pass "fm-turnend-guard: the unattended-work block stands down in away mode (the daemon owns supervision there)"
}

# FM_TRIAGE_DUTY=off is the captain-sanctioned kill switch for the whole fleet-triage duty;
# the gate is part of the duty, so the switch stands it down too - the operator escape
# hatch if the gate itself ever misbehaves.
test_hook_triage_block_is_off_when_duty_is_disabled() {
  local dir home pid out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-dutyoff")
  home=$(cd "$dir" && pwd)
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" waiting-l3
  out=$(printf '{"stop_hook_active":false}' \
    | CLAUDECODE=1 FM_HOME="$home" FM_TRIAGE_DUTY=off bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "FM_TRIAGE_DUTY=off must disable the duty's block, not just its banner"
  [ -z "$out" ] || fail "hook produced triage output with the duty kill switch engaged: $out"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.nf_gate')" = duty-off ] || fail "the stand-down must be honest in the log: $log"
  pass "fm-turnend-guard: the duty kill switch also disables the unattended-work block"
}

# The loop guard bounds the new reason exactly as it bounds the old one: at most one forced
# continuation per turn, never an un-endable session. But a stop permitted only because of
# loop protection, with work still unattended, is exactly the event the acceptance metric
# counts - so it must be on the record, not invisible.
test_hook_loop_guard_bounds_the_triage_block() {
  local dir pid out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-loopguard")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" still-open-m4
  out=$(run_hook "$dir" true); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "stop_hook_active=true must allow the stop even with work unattended"
  [ -z "$out" ] || fail "hook produced output on the loop-guarded retry: $out"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed ] || fail "the loop-guarded permit must be logged: $log"
  [ "$(printf '%s' "$log" | jq -r '.loop_protection')" = true ] || fail "the log must say loop protection permitted it: $log"
  [ "$(printf '%s' "$log" | jq -r '.needs_firstmate')" = 1 ] || fail "the log must still count the unattended work: $log"
  pass "fm-turnend-guard: the unattended-work block never fires twice in one turn, and the permit is on the record"
}

test_hook_silent_when_no_work_in_flight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must exit 0 with no in-flight work"
  [ -z "$out" ] || fail "hook produced output with no in-flight work: $out"
  pass "fm-turnend-guard: silent no-op with nothing in flight"
}

test_hook_blocks_when_fresh_beacon_has_no_live_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fresh-no-lock")
  : > "$dir/state/task1.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when a fresh beacon has no live watcher lock"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks when a fresh beacon has no live watcher lock"
}

test_hook_blocks_when_dead_lock_has_fresh_beacon() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-dead-lock-fresh")
  dead=$(nonexistent_pid)
  : > "$dir/state/task1.meta"
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when the watcher lock pid is dead despite a fresh beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a dead watcher lock even when the beacon is fresh"
}

test_hook_silent_with_live_lock_and_fresh_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-fresh")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must exit 0 with a live identity-matched watcher lock and fresh beacon"
  [ -z "$out" ] || fail "hook produced output despite a live fresh watcher lock: $out"
  pass "fm-turnend-guard: silent no-op with a live watcher lock and fresh beacon"
}

test_hook_blocks_with_live_lock_and_stale_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-stale")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "hook must block when a live watcher lock has an ancient beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a live watcher lock with an ancient beacon"
}

test_hook_blocks_when_unhealthy_in_primary() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-block")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block (exit 2) when in-flight work has no live watcher"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks with the exact required reason in the primary when unhealthy"
}

test_hook_blocks_from_fm_home_state() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home")
  home="$TMP_ROOT/hook-fm-home-op"
  mkdir -p "$home/state"
  : > "$home/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must inspect the active FM_HOME state dir"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks from active FM_HOME state, not only repo-root state"
}

test_hook_x_mode_reason_sources_cadence() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-x-mode")
  home=$(cd "$dir" && pwd)
  mkdir -p "$dir/config"
  : > "$dir/config/x-mode.env"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when in-flight X-mode work has no live watcher"
  assert_contains "$out" "source '$home/config/x-mode.env' first" "block reason must source the effective X-mode cadence"
  pass "fm-turnend-guard: X-mode repair reason sources the cadence config"
}

test_hook_ignores_repo_state_when_fm_home_set() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home-ignore-root")
  home="$TMP_ROOT/hook-fm-home-quiet"
  mkdir -p "$home/state"
  : > "$dir/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must ignore repo-root state when FM_HOME selects another state dir"
  [ -z "$out" ] || fail "hook produced output from stale repo-root state despite FM_HOME: $out"
  pass "fm-turnend-guard: ignores stale repo-root state when FM_HOME is set"
}

test_hook_uses_state_override() {
  local dir home state out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-state-override")
  home="$TMP_ROOT/hook-state-override-home"
  state="$TMP_ROOT/hook-state-override-active"
  mkdir -p "$home/state" "$state"
  : > "$state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must let FM_STATE_OVERRIDE win over FM_HOME/state"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: uses FM_STATE_OVERRIDE ahead of FM_HOME/state"
}

test_hook_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "hook must allow the stop when stop_hook_active is already true"
  [ -z "$out" ] || fail "hook produced output on the loop-guarded retry: $out"
  pass "fm-turnend-guard: stop_hook_active=true always allows the stop (never blocks twice in one turn)"
}

test_hook_silent_in_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must never block inside a secondmate home"
  [ -z "$out" ] || fail "hook produced output inside a secondmate home: $out"
  pass "fm-turnend-guard: inert in a secondmate home (.fm-secondmate-home marker present) even when unhealthy"
}

test_hook_silent_in_crewmate_worktree() {
  local base dir out status
  base="$TMP_ROOT/hook-crew-base"
  dir="$TMP_ROOT/hook-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must never block inside a crewmate task worktree"
  [ -z "$out" ] || fail "hook produced output inside a crewmate task worktree: $out"
  pass "fm-turnend-guard: inert in a crewmate/scout task worktree (linked git worktree) even when unhealthy"
}

test_hook_silent_without_jq() {
  local dir out status fakebin tool tool_path
  dir=$(make_primary_dir "$TMP_ROOT/hook-nojq")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/hook-nojq-fake")
  for tool in bash sh git cat printf date uname stat mkdir dirname; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '{"stop_hook_active":false}' | PATH="$fakebin" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "hook must fail open (exit 0) when jq is unavailable"
  [ -z "$out" ] || fail "hook produced output without jq: $out"
  pass "fm-turnend-guard: fails open (never blocks) when jq is missing"
}

test_hook_silent_without_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nostdin")
  : > "$dir/state/task1.meta"
  out=$(bash "$dir/bin/fm-turnend-guard.sh" < /dev/null 2>&1); status=$?
  expect_code 0 "$status" "hook must exit 0 on empty/absent stdin"
  [ -z "$out" ] || fail "hook produced output on empty stdin: $out"
  pass "fm-turnend-guard: silent no-op on empty stdin"
}

test_hook_runs_fast() {
  local dir start elapsed_s
  dir=$(make_primary_dir "$TMP_ROOT/hook-timing")
  : > "$dir/state/task1.meta"
  start=$SECONDS
  run_hook "$dir" false >/dev/null
  elapsed_s=$((SECONDS - start))
  [ "$elapsed_s" -lt 3 ] || fail "hook took ${elapsed_s}s, expected well under a second (generous 3s CI margin)"
  pass "fm-turnend-guard: runs well under the generous timing margin (${elapsed_s}s)"
}

test_grok_adapter_forces_one_resume_when_unhealthy() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-block")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-fakebin")
  log="$TMP_ROOT/grok-adapter-call.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
{
  printf 'active=%s\n' "\${GROK_TURNEND_GUARD_ACTIVE:-}"
  printf 'home=%s\n' "\${GROK_HOME:-}"
  printf 'args:'
  for arg in "\$@"; do
    printf ' <%s>' "\$arg"
  done
  printf '\n'
} >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must fail open after queuing a forced resume"
  [ -z "$out" ] || fail "grok adapter printed output: $out"
  assert_contains "$(cat "$log")" 'active=1' "grok adapter must mark its forced resume as loop-guarded"
  assert_contains "$(cat "$log")" '<--resume>' "grok adapter must resume the current session"
  assert_contains "$(cat "$log")" '<session-test>' "grok adapter must pass the hook session id"
  assert_not_contains "$(cat "$log")" '<--permission-mode>' "grok adapter must not add a stronger permission mode"
  assert_not_contains "$(cat "$log")" '<bypassPermissions>' "grok adapter must not bypass permissions on forced resume"
  assert_contains "$(cat "$log")" 'TURN WOULD END BLIND' "grok adapter must carry the guard reason into the forced resume"
  pass "fm-turnend-guard-grok: forces one same-session resume when the shared predicate blocks"
}

test_grok_adapter_loop_guard_skips_resume() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-loop")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-loop-fakebin")
  log="$TMP_ROOT/grok-adapter-loop-call.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" GROK_TURNEND_GUARD_ACTIVE=1 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must allow its own forced resume turn to end"
  [ -z "$out" ] || fail "grok adapter printed output while loop-guarded: $out"
  [ ! -e "$log" ] || fail "grok adapter spawned another resume while loop-guarded: $(cat "$log")"
  pass "fm-turnend-guard-grok: loop guard prevents a nested resume loop"
}

test_settings_hook_uses_claude_project_dir() {
  local settings command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .claude/settings.json"
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "Stop hook must resolve via CLAUDE_PROJECT_DIR, not a cwd-relative path"
  assert_contains "$command" 'fm-turnend-guard.sh' "Stop hook must still invoke fm-turnend-guard.sh"
  case "$command" in
    bin/fm-turnend-guard.sh|./bin/fm-turnend-guard.sh)
      fail "Stop hook must not use a bare relative path (cwd-dependent): $command"
      ;;
  esac
  pass ".claude/settings.json: Stop hook uses CLAUDE_PROJECT_DIR-anchored command"
}

test_codex_hook_invokes_shared_guard() {
  local settings command
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  assert_contains "$command" 'pwd -P' "codex hook must anchor from the hook process working directory"
  assert_contains "$command" '.codex/hooks.json' "codex hook must verify the hook-loaded firstmate root"
  assert_contains "$command" 'fm-turnend-guard.sh' "codex hook must invoke the shared guard"
  assert_not_contains "$command" '.cwd' "codex hook must not use payload cwd to select the guard executable"
  pass ".codex/hooks.json: Stop hook invokes the shared primary guard"
}

test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root() {
  local settings command dir expected_root outside payload out status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-hook-root")
  mark_codex_hook_root "$dir"
  expected_root=$(cd "$dir" && pwd -P)
  outside="$TMP_ROOT/codex-hook-outside"
  mkdir -p "$outside"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'guard=%s\n' "$0"
cat
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  payload=$(jq -cn --arg cwd "$outside" '{cwd:$cwd,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | (cd "$dir" && bash -c "$command") 2>&1); status=$?
  expect_code 0 "$status" "codex hook must execute successfully when payload cwd is outside the firstmate root"
  assert_contains "$out" "guard=$expected_root/bin/fm-turnend-guard.sh" "codex hook must use the hook process root"
  assert_contains "$out" "$payload" "codex hook must pass the original payload to the guard"
  pass ".codex/hooks.json: Stop hook uses hook process root when payload cwd is outside"
}

test_codex_hook_ignores_nested_git_root_guard() {
  local settings command dir nested subdir expected_root payload out status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-hook-outer")
  mark_codex_hook_root "$dir"
  expected_root=$(cd "$dir" && pwd -P)
  nested="$dir/projects/other"
  mkdir -p "$nested"
  git init -q "$nested"
  git -C "$nested" commit -q --allow-empty -m init
  mkdir -p "$nested/bin" "$nested/.codex"
  : > "$nested/AGENTS.md"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-turnend-guard.sh"}]}]}}\n' > "$nested/.codex/hooks.json"
  cat > "$nested/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'nested guard executed\n'
exit 99
EOF
  chmod +x "$nested/bin/fm-turnend-guard.sh"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'guard=%s\n' "$0"
cat
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  subdir="$nested/deep/path"
  mkdir -p "$subdir"
  payload=$(jq -cn --arg cwd "$subdir" '{cwd:$cwd,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | (cd "$dir" && bash -c "$command") 2>&1); status=$?
  expect_code 0 "$status" "codex hook must not execute a nested project guard"
  assert_contains "$out" "guard=$expected_root/bin/fm-turnend-guard.sh" "codex hook must keep using the outer firstmate guard"
  assert_not_contains "$out" "nested guard executed" "codex hook must not execute nested project code"
  pass ".codex/hooks.json: Stop hook ignores nested git root guard scripts"
}

test_opencode_plugin_forces_followup() {
  local plugin content
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  [ -f "$plugin" ] || fail "tracked OpenCode primary plugin is missing"
  content=$(cat "$plugin")
  assert_contains "$content" 'session.idle' "OpenCode plugin must run on session.idle"
  assert_contains "$content" 'fm-turnend-guard.sh' "OpenCode plugin must invoke the shared guard"
  assert_contains "$content" 'promptAsync' "OpenCode plugin must force a follow-up turn"
  assert_contains "$content" 'skipNextIdle' "OpenCode plugin must carry a loop guard"
  assert_contains "$content" 'worktree' "OpenCode plugin must anchor the guard from the git worktree path"
  pass ".opencode primary plugin: session.idle forces one follow-up through the shared guard"
}

test_opencode_plugin_anchors_guard_to_worktree() {
  local plugin parent worktree_dir wrong_dir out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  [ -f "$plugin" ] || fail "tracked OpenCode primary plugin is missing"
  parent="$TMP_ROOT/opencode-plugin-parent"
  git init -q "$parent"
  worktree_dir="$parent/nested/opencode-plugin-worktree"
  wrong_dir="$TMP_ROOT/opencode-plugin-cwd/subdir"
  mkdir -p "$worktree_dir/bin" "$wrong_dir"
  cat > "$worktree_dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard-fired\n' >&2
exit 2
EOF
  chmod +x "$worktree_dir/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$plugin" DIRECTORY="$wrong_dir" WORKTREE="$worktree_dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.DIRECTORY,
  worktree: process.env.WORKTREE,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!promptBody.includes("guard-fired")) {
  console.error(`missing prompt body: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must run the guard from worktree even when directory is elsewhere"
  [ -z "$out" ] || fail "OpenCode plugin worktree-root test printed output: $out"
  pass ".opencode primary plugin: guard path is anchored to worktree, not directory"
}

test_pi_extension_forces_followup() {
  local ext content
  ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  [ -f "$ext" ] || fail "tracked pi primary extension is missing"
  content=$(cat "$ext")
  assert_contains "$content" 'agent_settled' "pi extension must run after one logical agent run settles"
  assert_contains "$content" 'fm-turnend-guard.sh' "pi extension must invoke the shared guard"
  assert_contains "$content" 'sendUserMessage' "pi extension must force a follow-up turn"
  assert_contains "$content" 'deliverAs: "followUp"' "pi extension must queue the follow-up safely"
  assert_contains "$content" 'guardFollowupActive' "pi extension must carry a logical-run loop guard"
  assert_not_contains "$content" 'skipNextTurnEnd' "pi extension kept the internal-turn loop guard"
  assert_contains "$content" 'session-start operating block' "pi extension must use harness-neutral repair wording"
  assert_contains "$content" '.pi-turnend-extension-loaded' "pi extension must write its loaded marker for session-start diagnostics"
  assert_contains "$content" 'lockOwnership' "pi extension loaded marker must respect the session lock"
  assert_contains "$content" 'const command = String((event.input as { command?: unknown })?.command ?? "")' "pi extension changed bash command extraction for the PreToolUse contract"
  assert_contains "$content" 'runPretoolCheck(command)' "pi extension changed the PreToolUse checker invocation"
  assert_contains "$content" 'return { block: true, reason:' "pi extension changed the checker exit-2 block result"
  assert_not_contains "$content" 'Run bin/fm-watch-arm.sh as a background task' "pi extension must not hardcode the old watcher-arm instruction"
  pass ".pi primary extension: agent_settled forces one follow-up through the shared guard"
}

test_pi_extension_injects_once_per_logical_agent_run() {
  local repo home ext log out status
  repo="$TMP_ROOT/pi-logical-run-root"
  home="$TMP_ROOT/pi-logical-run-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  log="$TMP_ROOT/pi-logical-run-guard.log"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'logical-run guard fired\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_GUARD_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts += 1;
    if (!message.includes("TURN WOULD END BLIND")) throw new Error(`unexpected prompt: ${message}`);
    if (options?.deliverAs !== "followUp") throw new Error("guard prompt was not a follow-up");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (handlers.has("turn_end")) throw new Error("guard still treats internal Pi turns as logical runs");
const settled = handlers.get("agent_settled");
if (!settled) throw new Error("agent_settled handler was not registered");

await settled({ type: "agent_settled" }, {});
if (prompts !== 1) throw new Error(`no-tool run injected ${prompts} follow-ups`);

for (let i = 0; i < 3; i += 1) {
  await handlers.get("turn_end")?.({ type: "turn_end", turnIndex: i }, {});
}
await settled({ type: "agent_settled" }, {});
if (prompts !== 2) throw new Error(`multi-tool run produced ${prompts - 1} follow-ups`);

const guardRuns = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (guardRuns !== 2) throw new Error(`guard predicate ran ${guardRuns} times for two logical runs`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must inject once for no-tool and multi-tool logical runs"
  [ -z "$out" ] || fail "Pi logical-run guard test printed output: $out"
  pass ".pi primary extension: no-tool and multi-tool runs each inject exactly one guard follow-up"
}

test_pi_extension_retries_after_followup_delivery_failure() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-delivery-failure-root"
  home="$TMP_ROOT/pi-delivery-failure-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'delivery failure guard\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let attempts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    attempts += 1;
    if (attempts === 1) throw new Error("synthetic delivery failure");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");
await settled({ type: "agent_settled" }, {});
await settled({ type: "agent_settled" }, {});
if (attempts !== 2) throw new Error(`expected delivery retry, saw ${attempts} attempts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard latch must reset after follow-up delivery failure"
  [ -z "$out" ] || fail "Pi delivery-failure guard test printed output: $out"
  pass ".pi primary extension: delivery failure resets the logical-run latch"
}

test_grok_hook_invokes_adapter() {
  local settings command
  settings="$ROOT/.grok/hooks/fm-primary-turnend-guard.json"
  [ -f "$settings" ] || fail "tracked grok primary hook config is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from grok primary hook config"
  assert_contains "$command" 'GROK_WORKSPACE_ROOT' "grok hook must anchor from GROK_WORKSPACE_ROOT"
  assert_contains "$command" 'fm-turnend-guard-grok.sh' "grok hook must invoke the adapter"
  pass ".grok primary hook: Stop hook invokes the grok adapter"
}

test_predicate_healthy_no_inflight
test_predicate_unhealthy_no_beacon
test_predicate_unhealthy_stale_beacon
test_predicate_healthy_fresh_beacon
test_predicate_queue_pending_flag
test_hook_silent_when_no_work_in_flight
test_hook_blocks_on_unattended_finished_work
test_hook_reads_live_state_not_the_duty_cache
test_hook_silent_when_lane_is_clear
test_hook_disposition_and_hold_expiry
test_hook_blocks_on_both_reasons_at_once
test_hook_fails_open_when_live_read_is_unavailable
test_hook_malformed_ledger_rows_do_not_hide_work
test_hook_triage_block_is_off_while_away
test_hook_triage_block_is_off_when_duty_is_disabled
test_hook_loop_guard_bounds_the_triage_block
test_hook_blocks_when_fresh_beacon_has_no_live_lock
test_hook_blocks_when_dead_lock_has_fresh_beacon
test_hook_silent_with_live_lock_and_fresh_beacon
test_hook_blocks_with_live_lock_and_stale_beacon
test_hook_blocks_when_unhealthy_in_primary
test_hook_blocks_from_fm_home_state
test_hook_x_mode_reason_sources_cadence
test_hook_ignores_repo_state_when_fm_home_set
test_hook_uses_state_override
test_hook_loop_guard_allows_retry
test_hook_silent_in_secondmate_home
test_hook_silent_in_crewmate_worktree
test_hook_silent_without_jq
test_hook_silent_without_stdin
test_hook_runs_fast
test_grok_adapter_forces_one_resume_when_unhealthy
test_grok_adapter_loop_guard_skips_resume
test_settings_hook_uses_claude_project_dir
test_codex_hook_invokes_shared_guard
test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root
test_codex_hook_ignores_nested_git_root_guard
test_opencode_plugin_forces_followup
test_opencode_plugin_anchors_guard_to_worktree
test_pi_extension_forces_followup
test_pi_extension_injects_once_per_logical_agent_run
test_pi_extension_retries_after_followup_delivery_failure
test_grok_hook_invokes_adapter
