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

# Hermeticity: the guard and its libs resolve the home/state/data/root/config it
# reads from these override vars (bin/fm-turnend-guard.sh:71-75), so a shell that
# already exports any of them - e.g. a crewmate session pointing FM_ROOT_OVERRIDE
# at the live runtime home - would leak that home into every test's resolution and
# corrupt caller-identity assertions like `.fm_root == $home`. Each test sets its
# own FM_HOME per case; clear the ambient overrides once here so nothing else
# survives from the launching environment.
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
  FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE 2>/dev/null || true

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

# Review-r5 F-1: FM_SUPERVISION_TEST_MODE is fail-closed at the shared
# supervision-library boundary. Outside a provably test-owned home it must
# never mint a synthetic identity - and it must not silently degrade to the
# production lock path either, so the anomaly surfaces as red supervision.
test_predicate_ambient_test_mode_requires_test_owned_home() {
  local home owned out
  home=$(mktemp -d) || fail "mktemp failed"
  FM_TEST_CLEANUP_DIRS+=("$home")
  mkdir -p "$home/state"
  # shellcheck disable=SC2016  # $1/$2 expand in the inner bash -c process, not here.
  out=$(FM_SUPERVISION_TEST_MODE=1 bash -c '. "$1/bin/fm-supervision-lib.sh"
    if ident=$(fm_supervision_detect_primary_identity "$2/state" "$2" codex); then
      printf "detected=%s\n" "$ident"
    else
      printf "refused\n"
    fi' _ "$ROOT" "$home")
  assert_contains "$out" "refused" "ambient test mode outside a test-owned home minted an identity"
  printf '%s\n' "$$" > "$home/state/.lock"
  # shellcheck disable=SC2016  # $1/$2 expand in the inner bash -c process, not here.
  out=$(FM_SUPERVISION_TEST_MODE=1 bash -c '. "$1/bin/fm-supervision-lib.sh"
    if ident=$(fm_supervision_detect_primary_identity "$2/state" "$2" codex); then
      printf "detected=%s\n" "$ident"
    else
      printf "refused\n"
    fi' _ "$ROOT" "$home")
  assert_contains "$out" "refused" "ambient test mode with a live lock must fail closed, not silently degrade"
  owned="$TMP_ROOT/pred-testmode-owned"
  mkdir -p "$owned/state"
  # shellcheck disable=SC2016  # $1/$2 expand in the inner bash -c process, not here.
  out=$(FM_SUPERVISION_TEST_MODE=1 bash -c '. "$1/bin/fm-supervision-lib.sh"
    if ident=$(fm_supervision_detect_primary_identity "$2/state" "$2" codex); then
      printf "detected=%s\n" "$ident"
    else
      printf "refused\n"
    fi' _ "$ROOT" "$owned")
  assert_contains "$out" "detected=test:codex:" "a proven test-owned fixture identity stopped resolving"
  rm -rf "$home"
  pass "fm_supervision_detect_primary_identity: FM_SUPERVISION_TEST_MODE fails closed outside test-owned homes"
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
  cp "$ROOT/bin/fm-codex-systemd-scheduler.sh" "$dir/bin/fm-codex-systemd-scheduler.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  # The live needs_firstmate read: the attention lib and everything it sources, plus the
  # ack command the paper-disposition cases exercise.
  cp "$ROOT/bin/fm-nf-attention-lib.sh" "$dir/bin/fm-nf-attention-lib.sh"
  cp "$ROOT/bin/fm-nf-lib.sh" "$dir/bin/fm-nf-lib.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-backend.sh" "$dir/bin/fm-backend.sh"
  cp "$ROOT/bin/fm-fleet-triage-lib.sh" "$dir/bin/fm-fleet-triage-lib.sh"
  cp "$ROOT/bin/fm-nf-ack.sh" "$dir/bin/fm-nf-ack.sh"
  cp "$ROOT/bin/fm-turnend-metrics.sh" "$dir/bin/fm-turnend-metrics.sh"
  chmod +x "$dir/bin/fm-nf-ack.sh" "$dir/bin/fm-turnend-metrics.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh" "$dir/bin/fm-codex-systemd-scheduler.sh"
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

# A secondmate home's OWN child crew/scout worktree: a genuine linked git
# worktree of the secondmate home, so git-dir != git-common-dir exactly as for a
# main-home child worktree. A child worktree never carries the gitignored
# .fm-secondmate-home marker, so the marker force-include never fires for it and
# it stays exempt through the linked-worktree git-dir test.
make_secondmate_child_worktree_dir() {
  local home=$1 dir=$2
  git -C "$home" worktree add --quiet -b fm/turnend-secondmate-child "$dir"
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A treehouse-leased secondmate HOME: a genuine linked `git worktree` (git-dir !=
# git-common-dir, exactly like a default treehouse-leased home) that DOES carry a
# valid .fm-secondmate-home marker. This is the production topology the plain
# git-init secondmate fixture cannot represent; the guard must force-INCLUDE it
# as a guarded primary via the marker, not exempt it as a linked worktree.
make_secondmate_linked_home_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-secondmate-linked-home
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf 'sm-linked-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

run_hook() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

run_hook_codex() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$dir/fake-systemd" FM_SUPERVISION_HARNESS=codex FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

run_hook_codex_production_identity_override() {
  local dir=$1 stop_active=$2 identity=$3 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | FM_CODEX_SYSTEMD_FAKE_DIR="$dir/fake-systemd" FM_CODEX_PRIMARY_IDENTITY="$identity" FM_SUPERVISION_HARNESS=codex FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
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

write_codex_schedule() {  # <dir> <start-offset> <cadence> <lateness> [result] [owner-override]
  local dir=$1 start_offset=$2 cadence=$3 lateness=$4 result=${5:-quiet} owner_override=${6:-}
  local now start end home fake
  home=$(cd "$dir" && pwd)
  fake="$dir/fake-systemd"
  now=$(date +%s)
  start=$((now + start_offset))
  end=$((start + 1))
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$fake" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_persist_primary_harness "$2/state" "$2" codex' \
    _ "$dir" "$home" || fail "could not persist Codex harness for $dir"
  if [ -n "$owner_override" ]; then
    FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$fake" FM_CODEX_PRIMARY_IDENTITY="$owner_override" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_codex_checkpoint_prepare "$2/state" "$2" "$3" "$6" || exit 1; fm_codex_checkpoint_finish "$2/state" "$2" "$3" "$4" "$5" "$6" "$7" "$FM_CODEX_CHECKPOINT_GENERATION"' \
      _ "$dir" "$home" "$start" "$end" "$result" "$cadence" "$lateness" \
      || fail "could not write Codex schedule for $dir"
  else
    FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$fake" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_codex_checkpoint_prepare "$2/state" "$2" "$3" "$6" || exit 1; fm_codex_checkpoint_finish "$2/state" "$2" "$3" "$4" "$5" "$6" "$7" "$FM_CODEX_CHECKPOINT_GENERATION"' \
      _ "$dir" "$home" "$start" "$end" "$result" "$cadence" "$lateness" \
      || fail "could not write Codex schedule for $dir"
  fi
}

rewrite_codex_schedule() {  # <dir> <jq-filter>
  local dir=$1 filter=$2 file payload hash
  file="$dir/state/.codex-watch-checkpoint.next.json"
  payload=$(jq -cS "del(.integrity) | $filter" "$file") || fail "could not rewrite schedule payload with $filter"
  hash=$(printf '%s\n' "$payload" | sha256sum | awk '{print $1}')
  printf '%s\n' "$payload" | jq -cS --arg integrity "sha256:$hash" '. + {integrity:$integrity}' > "$file.tmp" \
    || fail "could not rebuild schedule integrity"
  mv -f "$file.tmp" "$file"
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
  [ "$(printf '%s' "$log" | jq -r '.decision')" = blocked_needs_firstmate ] || fail "decision log must record the block: $log"
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
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_needs_firstmate_empty ] || fail "a genuinely-empty lane must be recorded as allowed_needs_firstmate_empty: $log"
  pass "fm-turnend-guard: silent with a clear lane and a live watcher, and the permit is logged as allowed_needs_firstmate_empty"
}

# Only a GENUINE terminal disposition - resolved or rejected, with lineage, against current
# evidence - discharges the gate (ORD-059 section 2). Everything else is paper.
test_hook_genuine_terminal_dispositions_discharge() {
  local dir pid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-genuine")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" landed-e5
  record_nf_outcome "$dir" landed-e5 resolved local-main-abc1234 '' ''
  write_nf_signal "$dir" nonbug-e6
  record_nf_outcome "$dir" nonbug-e6 rejected '' 'not a real defect' ''
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "resolved and rejected items must not block"
  [ -z "$out" ] || fail "hook blocked on genuinely dispositioned work: $out"
  pass "fm-turnend-guard: resolved and rejected dispositions with lineage discharge the gate"
}

# THE PAPER-EXIT CASES (ORD-059 section 2): an unresolved terminal task stays in the
# predicate after every paper move - an ack receipt, a re-armed watcher, a claim, a hold
# (valid, expired, or unreadable), successor_created, captain_batch, and a cached triage
# summary claiming clear. This is the anti-gaming core of the gate: the incident it exists
# for was eight holds recorded in 137 seconds, a 181-to-1 successor fan-out, and a
# captain_batch row that vanished a captain decision (bug-20260713154240-10d127e0 - the
# card fix belongs to captain-batch-drop-b6; this proves the GUARD is not fooled either way).
test_hook_paper_dispositions_do_not_discharge() {
  local dir pid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-paper")
  # A healthy watcher IS the re-armed state: the lock is live and identity-matched and the
  # beacon is fresh, exactly what bin/fm-watch-arm.sh leaves behind. Arming again changes
  # nothing this guard reads.
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" open-p1

  # fm-nf-ack.sh: a review receipt (and its board write) is information, never discharge.
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
url= body=
while [ "$#" -gt 0 ]; do
  case $1 in
    -d) body=$2; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [ -n "$body" ]; then
  printf '%s\t%s\n' "$url" "$body" >> "$FM_TEST_BOARD_LOG"
else
  awk -F '\t' -v url="$url" '$1 == url {last = $2} END {print (last == "" ? "{}" : last)}' \
    "$FM_TEST_BOARD_LOG" 2>/dev/null || printf '{}\n'
fi
SH
  chmod +x "$dir/fakebin/curl"
  FM_TEST_BOARD_LOG="$dir/board.log" PATH="$dir/fakebin:$PATH" FM_HOME="$(cd "$dir" && pwd)" \
    FM_BRIDGE_URL='http://board.test' "$dir/bin/fm-nf-ack.sh" open-p1 >/dev/null 2>&1 \
    || fail "fm-nf-ack.sh should succeed against the board stub"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "an ack receipt must not discharge the gate"
  assert_contains "$out" "open-p1" "the acked item must still be named"

  # A FirstMate narrative acknowledgment: saying it was handled changes no state at all,
  # so a re-evaluation with nothing else done must still block.
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "a narrative acknowledgment (no state change) must not discharge the gate"

  # A triage surface: first-sight stamping re-opens items; it never closes one.
  mkdir -p "$dir/data"
  jq -nc '{item_id: "needs_firstmate:open-p1", event: "surface",
           first_seen_at: "2026-07-13T00:00:00Z"}' >> "$dir/data/fleet-triage.jsonl"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "a surface must not discharge the gate"

  # A triage claim: ownership is not disposition.
  jq -nc '{item_id: "needs_firstmate:open-p1", event: "claim", owner: "firstmate",
           claimed_at: "2026-07-13T00:00:00Z"}' >> "$dir/data/fleet-triage.jsonl"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "a claim must not discharge the gate"

  # A hold, in all three shapes: valid future date, expired date, unreadable legacy date.
  # A valid hold parks the BOARD CARD; it never parks this gate.
  record_nf_outcome "$dir" open-p1 held '' 'valid dated hold' 2999-01-01
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "a valid future-dated hold must not discharge the gate"
  assert_contains "$out" "open-p1" "the held item must still be named"
  record_nf_outcome "$dir" open-p1 held '' 'parked long ago' 2020-01-01
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "an expired hold must not discharge the gate"
  record_nf_outcome "$dir" open-p1 held '' 'muted forever' 'next bug-triage pass or captain returns'
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "a legacy hold whose review date no clock can read must not discharge the gate"

  # successor_created, with a successor that genuinely exists as a live task.
  printf 'window=fm-succ-x1\n' > "$dir/state/succ-x1.meta"
  record_nf_outcome "$dir" open-p1 successor_created succ-x1 '' ''
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "successor_created must not discharge the gate"

  # captain_batch: handing a decision to the captain transfers it, it does not end it. The
  # guard must keep blocking whether or not the card fix (captain-batch-drop-b6) has landed.
  record_nf_outcome "$dir" open-p1 captain_batch batch-2026-07-13 '' ''
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "captain_batch must not discharge the gate"
  assert_contains "$out" "open-p1" "the captain-batched item must still be named and visible"

  # A cached triage summary claiming clear: the cache is not consulted at all.
  printf '{"ok":true,"needs_firstmate":0,"actionable":0}\n' > "$dir/state/.triage-duty-last.json"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "a cached clear summary must not discharge the gate"
  assert_contains "$out" "open-p1" "the item must still be named despite the cache"
  pass "fm-turnend-guard: ack, re-arm, claim, holds, successor_created, captain_batch, and the cache all fail to discharge the gate"
}

# A GENUINE captain decision (ORD-060 section 2): once verifiably transferred to the
# captain's still-visible Needs You column - fm-nf-ack.sh --to-captain, whose receipt is
# written only AFTER the Bridge reads the card back and binds the current fingerprint - the
# primary stops re-blocking on work it cannot decide. A bare captain_batch ledger row is
# not that transfer, and a fresh terminal signal re-opens the gate no matter what was
# acknowledged before, so the decision can never disappear through acknowledgment.
test_hook_verified_captain_transfer_discharges_without_hiding_the_decision() {
  local dir home pid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-captain")
  home=$(cd "$dir" && pwd)
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" decide-q2 'needs-decision: rollout strategy'
  record_nf_outcome "$dir" decide-q2 captain_batch batch-2026-07-13 '' ''
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "an unconfirmed captain_batch must keep blocking"
  assert_contains "$out" "decide-q2" "the unconfirmed captain-batched item must be named"
  # The verified hand-off: ack --to-captain against the board stub writes the receipt only
  # after read-back.
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
url= body=
while [ "$#" -gt 0 ]; do
  case $1 in
    -d) body=$2; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [ -n "$body" ]; then
  printf '%s\t%s\n' "$url" "$body" >> "$FM_TEST_BOARD_LOG"
else
  awk -F '\t' -v url="$url" '$1 == url {last = $2} END {print (last == "" ? "{}" : last)}' \
    "$FM_TEST_BOARD_LOG" 2>/dev/null || printf '{}\n'
fi
SH
  chmod +x "$dir/fakebin/curl"
  FM_TEST_BOARD_LOG="$dir/board.log" PATH="$dir/fakebin:$PATH" FM_HOME="$home" \
    FM_BRIDGE_URL='http://board.test' "$dir/bin/fm-nf-ack.sh" --to-captain 'needs_firstmate:decide-q2' decide-q2 \
    >/dev/null 2>&1 || fail "fm-nf-ack.sh --to-captain should succeed against the board stub"
  grep -q "decide-q2" "$dir/state/.nf-to-captain" || fail "the verified hand-off must leave its receipt"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "a board-confirmed captain transfer must stop re-blocking the primary"
  [ -z "$out" ] || fail "hook produced output after a verified captain transfer: $out"
  # The decision cannot disappear through acknowledgment: a fresh terminal signal mints a
  # new fingerprint the old receipt does not cover.
  printf '%s\n' 'needs-decision: rollout strategy, revised options' >> "$dir/state/decide-q2.status"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "a fresh terminal signal must re-open the gate past the stale receipt"
  assert_contains "$out" "decide-q2" "the re-opened decision must be named"
  pass "fm-turnend-guard: a verified captain transfer discharges the gate; a bare row or stale receipt does not"
}

# When the turn ends under loop protection with nothing discharged, the limitation is not
# silent: one durable check wake is queued (deduped) so the unresolved items front the next
# primary turn through the normal wake-drain path.
test_hook_no_progress_permit_queues_a_durable_wake() {
  local dir pid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-wakequeue")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" still-open-r3
  run_hook "$dir" false >/dev/null 2>&1
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "the loop-guarded stop is still permitted"
  grep -q "	check	turnend-guard	" "$dir/state/.wake-queue" 2>/dev/null \
    || fail "a no-progress permit must queue a durable turnend-guard check wake"
  grep -q "still-open-r3" "$dir/state/.wake-queue" || fail "the queued wake must name the unresolved work"
  # Deduped: a second identical stand-down does not stack a second record.
  run_hook "$dir" false >/dev/null 2>&1
  out=$(run_hook "$dir" true); status=$?
  stop_watcher "$pid"
  [ "$(grep -c "	check	turnend-guard	" "$dir/state/.wake-queue")" -eq 1 ] \
    || fail "pending turnend-guard wakes must not stack: $(cat "$dir/state/.wake-queue")"
  pass "fm-turnend-guard: a no-progress loop permit queues one durable check wake for the next turn"
}

# The anti-evasion metrics (ORD-060 section 8): the reporter folds the decision log and
# the live lane so a paper-disposition escape pattern is countable, and a permit granted
# with work outstanding can never hide inside the compliant counters.
test_metrics_report_counts_outcomes() {
  local dir home pid out
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-metrics")
  home=$(cd "$dir" && pwd)
  pid=$(start_healthy_watcher "$dir")
  run_hook "$dir" false >/dev/null 2>&1          # allowed_needs_firstmate_empty
  write_nf_signal "$dir" evade-s4
  run_hook "$dir" false >/dev/null 2>&1          # blocked_needs_firstmate
  run_hook "$dir" true >/dev/null 2>&1           # allowed_loop_protection_without_progress
  record_nf_outcome "$dir" evade-s4 held '' 'parked on paper' 2999-01-01
  run_hook "$dir" false >/dev/null 2>&1          # blocked again: paper does not discharge
  out=$(FM_HOME="$home" bash "$dir/bin/fm-turnend-metrics.sh" --json)
  stop_watcher "$pid"
  [ "$(printf '%s' "$out" | jq -r '.cumulative.allowed_needs_firstmate_empty')" -ge 1 ] \
    || fail "metrics must count the clean permit: $out"
  [ "$(printf '%s' "$out" | jq -r '.cumulative.blocked_needs_firstmate')" -eq 2 ] \
    || fail "metrics must count both blocks: $out"
  [ "$(printf '%s' "$out" | jq -r '.cumulative.allowed_loop_protection_without_progress')" -eq 1 ] \
    || fail "metrics must count the no-progress permit: $out"
  [ "$(printf '%s' "$out" | jq -r '.cumulative.permits_with_unattended_work')" -eq 1 ] \
    || fail "a permit with work outstanding must be counted against the gate: $out"
  [ "$(printf '%s' "$out" | jq -r '.live.unattended')" -eq 1 ] \
    || fail "metrics must report the live unattended count: $out"
  [ "$(printf '%s' "$out" | jq -r '.live.paper_parked')" -eq 1 ] \
    || fail "a held item whose signal remains is the paper-parked evasion signature: $out"
  printf '%s' "$out" | jq -r '.live.paper_parked_ids' | grep -q 'evade-s4' \
    || fail "the paper-parked item must be named: $out"
  pass "fm-turnend-metrics: outcome counters, unattended-permit count, and the paper-parked signature all report"
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

# FAIL OPEN, BUT NEVER SILENTLY (ORD-059 section 3). A guard on the live supervision path
# that can wedge the primary is worse than the bug it catches, so any failure to read the
# live state must permit the turn to end - but a failed inspection is NOT an ordinary
# empty-lane permit: it is loud, it is logged as guard_error naming the failed component,
# and it raises one deduped durable bug signal, because a silently dead gate looks exactly
# like a healthy one.
test_hook_guard_error_fails_open_loudly() {
  local dir home pid out status log coalesce
  # The attention lib is missing outright (a partial checkout).
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-nolib")
  home=$(cd "$dir" && pwd)
  coalesce="$dir/coalesce"
  mkdir -p "$dir/stubbin"
  printf '#!/usr/bin/env bash\necho "$@" >> "%s/bug-calls.log"\n' "$home" > "$dir/stubbin/bugstub"
  chmod +x "$dir/stubbin/bugstub"
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" hidden-h8
  rm "$dir/bin/fm-nf-attention-lib.sh"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" \
    FM_FLEET_TRIAGE_BUG_CLI="$home/stubbin/bugstub" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "a missing attention lib must fail open, not wedge the primary"
  assert_contains "$out" "TURN-END GUARD ERROR" "a failed inspection must be loud, never a silent permit"
  assert_contains "$out" "fm-nf-attention-lib.sh missing" "the failed component must be named"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_guard_error ] || fail "a failed inspection must log guard_error, not an allowed permit: $log"
  [ "$(printf '%s' "$log" | jq -r '.nf_error')" = 'fm-nf-attention-lib.sh missing' ] || fail "the log must record the failed component: $log"
  # The durable signal fires once, not once per turn end.
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" \
    FM_FLEET_TRIAGE_BUG_CLI="$home/stubbin/bugstub" bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  [ "$(grep -c 'turn-end guard' "$home/bug-calls.log")" -eq 1 ] \
    || fail "the durable bug signal must be deduped per component, got: $(cat "$home/bug-calls.log")"
  stop_watcher "$pid"
  # The attention lib is present but broken (a syntax error mid-upgrade). Bug filing disabled
  # (FM_FLEET_TRIAGE_BUG_CLI=off) so the test never touches the live captain ledger - this
  # path used to file a real bug through the host's `bug` on PATH.
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-brokenlib")
  home=$(cd "$dir" && pwd)
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" hidden-i9
  printf 'if [\n' > "$dir/bin/fm-nf-attention-lib.sh"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_FLEET_TRIAGE_BUG_CLI=off bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "a broken attention lib must fail open, not wedge the primary"
  assert_contains "$out" "fm-nf-attention-lib.sh failed to source" "the broken component must be named"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_guard_error ] || fail "a broken lib must log guard_error: $log"
  pass "fm-turnend-guard: read failures fail open with a loud banner, a guard_error record, and one deduped bug signal"
}

# --- ORD-231: the original sourcing-failure mode, reproduced hermetically ------
# The 61 open, still-firing duplicate guard-error bugs came from `fm-nf-attention-lib.sh
# failed to source` (data/turnend-failopen-x6/report.md): a TRANSIENT source failure under
# concurrent Stop-hook fan-in, per-$STATE dedup that could not stop cross-home duplicates,
# and no caller identity to trace it. These cases pin the fix. All are sandboxed: a stub bug
# CLI, a per-test coalesce dir, and a fixture attention lib - the live runtime is never
# touched.

# Install a stub attention lib whose source FAILS the first N times it is sourced and then
# succeeds, using a persisted counter, to model the transient failure exactly.
install_transient_nf_lib() {  # <dir> <fail-through-attempt-count>
  local dir=$1 fail_upto=$2
  cat > "$dir/bin/fm-nf-attention-lib.sh" <<EOF
_gc="\${FM_TEST_SRCCOUNT:-/dev/null}"
_gn=0; [ -f "\$_gc" ] && _gn=\$(cat "\$_gc" 2>/dev/null || echo 0)
_gn=\$((_gn + 1)); echo "\$_gn" > "\$_gc" 2>/dev/null || true
if [ "\$_gn" -le $fail_upto ]; then return 1; fi
fm_nf_unattended_ids() { return 0; }
EOF
}

install_always_failing_nf_lib() {  # <dir>
  printf 'return 1\n' > "$1/bin/fm-nf-attention-lib.sh"
}

install_bug_stub() {  # <dir> <log-path>
  local dir=$1 log=$2
  mkdir -p "$dir/stubbin"
  # shellcheck disable=SC2016  # $*, $$, $RANDOM are literal in the generated stub; they expand when it runs.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\necho "bug-stub-id-$$-$RANDOM"\n' "$log" > "$dir/stubbin/bugstub"
  chmod +x "$dir/stubbin/bugstub"
  printf '%s\n' "$dir/stubbin/bugstub"
}

# A single transient source failure must be ABSORBED by the bounded retry, not reported as a
# guard_error and not filed as a bug. This is the exact condition the incident was made of.
test_hook_source_failure_is_absorbed_by_retry() {
  local dir home pid out status log stub coalesce
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-transient")
  home=$(cd "$dir" && pwd)
  coalesce="$dir/coalesce"
  stub=$(install_bug_stub "$dir" "$home/bug-calls.log")
  install_transient_nf_lib "$dir" 1
  pid=$(start_healthy_watcher "$dir")
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_TEST_SRCCOUNT="$dir/state/.srccount" FM_GUARD_ERROR_COALESCE_DIR="$coalesce" \
    FM_FLEET_TRIAGE_BUG_CLI="$stub" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "a transient source failure that clears on retry must permit the turn"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_needs_firstmate_empty ] \
    || fail "the retry must absorb the transient failure, not declare guard_error: $log"
  [ "$(printf '%s' "$log" | jq -r '.nf_error')" = '' ] || fail "an absorbed transient failure must leave nf_error empty: $log"
  assert_not_contains "$out" "TURN-END GUARD ERROR" "an absorbed transient failure must not emit a guard-error banner"
  [ ! -s "$home/bug-calls.log" ] || fail "an absorbed transient failure must not file a bug: $(cat "$home/bug-calls.log")"
  [ "$(cat "$dir/state/.srccount" 2>/dev/null)" = 2 ] || fail "the source must have been retried exactly once (count=2), got $(cat "$dir/state/.srccount" 2>/dev/null)"
  pass "fm-turnend-guard: a single transient source failure is absorbed by the bounded retry"
}

# A PERSISTENT source failure still fails open loudly as guard_error - the retry never mutes
# a real outage - and the record now carries CALLER IDENTITY so it is traceable.
test_hook_persistent_source_failure_reports_with_caller_identity() {
  local dir home pid out status log stub coalesce bugtext
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-persistent")
  home=$(cd "$dir" && pwd)
  coalesce="$dir/coalesce"
  stub=$(install_bug_stub "$dir" "$home/bug-calls.log")
  install_always_failing_nf_lib "$dir"
  pid=$(start_healthy_watcher "$dir")
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" \
    FM_FLEET_TRIAGE_BUG_CLI="$stub" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "a persistent source failure must still fail open, not wedge the primary"
  assert_contains "$out" "TURN-END GUARD ERROR" "a persistent source failure must stay loud"
  assert_contains "$out" "fm-nf-attention-lib.sh failed to source" "the failed component must be named"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_guard_error ] || fail "a persistent source failure must log guard_error: $log"
  # Caller identity is now on the record - the traceability gap ORD-231 was about.
  [ "$(printf '%s' "$log" | jq -r '.fm_root')" = "$home" ] || fail "the guard_error record must carry fm_root: $log"
  [ "$(printf '%s' "$log" | jq -r '.state_dir')" = "$home/state" ] || fail "the guard_error record must carry the state dir: $log"
  [ "$(printf '%s' "$log" | jq -r '.cwd')" != '' ] || fail "the guard_error record must carry cwd: $log"
  [ "$(printf '%s' "$log" | jq -r '.hook_source')" != '' ] || fail "the guard_error record must carry the hook source: $log"
  [ "$(printf '%s' "$log" | jq -r '.pid')" != '' ] || fail "the guard_error record must carry the pid: $log"
  # The filed bug text carries the same identity so a ledger row is traceable on its own.
  bugtext=$(cat "$home/bug-calls.log")
  case "$bugtext" in
    *"Caller: fm_root=$home"*) : ;;
    *) fail "the filed bug must embed caller identity, got: $bugtext" ;;
  esac
  pass "fm-turnend-guard: a persistent source failure fails open as guard_error and carries caller identity"
}

# THE COALESCING FIX: two DIFFERENT homes hitting the identical failure must file exactly ONE
# captain bug between them (fleet-wide dedup keyed on the failure fingerprint), where the old
# per-$STATE marker filed one per home - the mechanism behind ~58 duplicate rows.
test_hook_guard_error_bug_is_coalesced_fleet_wide() {
  local base coalesce buglog stub1 stub2 h1 h2 pid1 pid2
  base="$TMP_ROOT/hook-nf-coalesce"
  mkdir -p "$base"
  coalesce="$base/coalesce"
  buglog="$base/bug-calls.log"
  h1=$(make_primary_dir "$base/home1")
  h2=$(make_primary_dir "$base/home2")
  install_always_failing_nf_lib "$h1"
  install_always_failing_nf_lib "$h2"
  stub1=$(install_bug_stub "$h1" "$buglog")
  stub2=$(install_bug_stub "$h2" "$buglog")
  pid1=$(start_healthy_watcher "$h1")
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$(cd "$h1" && pwd)" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_FLEET_TRIAGE_BUG_CLI="$stub1" \
    bash "$h1/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  stop_watcher "$pid1"
  pid2=$(start_healthy_watcher "$h2")
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$(cd "$h2" && pwd)" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_FLEET_TRIAGE_BUG_CLI="$stub2" \
    bash "$h2/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  stop_watcher "$pid2"
  [ "$(grep -c 'turn-end guard' "$buglog" 2>/dev/null)" -eq 1 ] \
    || fail "the same failure across two homes must file exactly one bug, got: $(cat "$buglog" 2>/dev/null)"
  # The shared record counted both occurrences even though only one bug was filed.
  [ "$(grep '^count=' "$coalesce"/*.record 2>/dev/null | head -1 | cut -d= -f2)" = 2 ] \
    || fail "the shared coalescing record must count both occurrences: $(cat "$coalesce"/*.record 2>/dev/null)"
  pass "fm-turnend-guard: identical guard errors across homes coalesce into one fleet-wide bug"
}

# The dedup must NOT be forever: once the window elapses, a genuinely-new recurrence surfaces
# a fresh bug. With a zero-length window every occurrence re-files.
test_hook_guard_error_bug_refiles_after_window() {
  local dir home pid stub coalesce
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-window")
  home=$(cd "$dir" && pwd)
  coalesce="$dir/coalesce"
  stub=$(install_bug_stub "$dir" "$home/bug-calls.log")
  install_always_failing_nf_lib "$dir"
  pid=$(start_healthy_watcher "$dir")
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_GUARD_ERROR_COALESCE_WINDOW=0 \
    FM_FLEET_TRIAGE_BUG_CLI="$stub" bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_GUARD_ERROR_COALESCE_WINDOW=0 \
    FM_FLEET_TRIAGE_BUG_CLI="$stub" bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  stop_watcher "$pid"
  [ "$(grep -c 'turn-end guard' "$home/bug-calls.log" 2>/dev/null)" -eq 2 ] \
    || fail "a zero-length window must re-file on every occurrence, got: $(cat "$home/bug-calls.log" 2>/dev/null)"
  pass "fm-turnend-guard: coalescing expires with the window so a real recurrence is never muted forever"
}

# FAIL-CLOSED linked-worktree exclusion: a crewmate/scout worktree must stay inert even when
# `git` itself fails (the transient git failure that let crew worktrees run the primary sweep
# and fail open - data/turnend-failopen-x6/report.md section 6.5). The .git-file signal is
# git-binary-independent, so a broken git no longer opens the gate.
test_hook_linked_worktree_excluded_when_git_is_broken() {
  local base dir home pid out status gitfake
  base="$TMP_ROOT/hook-failclosed-base"
  dir="$TMP_ROOT/hook-failclosed-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  home=$(cd "$dir" && pwd)
  [ -f "$dir/.git" ] || fail "fixture precondition: a linked worktree's .git must be a regular file"
  gitfake="$TMP_ROOT/hook-failclosed-gitfake"
  mkdir -p "$gitfake"
  printf '#!/bin/sh\nexit 1\n' > "$gitfake/git"
  chmod +x "$gitfake/git"
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-w1 'done: ready in branch fm/ship-w1'
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    PATH="$gitfake:$PATH" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "a linked worktree must stay inert even when git fails, never fail open into the primary path"
  [ -z "$out" ] || fail "a linked worktree with a broken git produced output: $out"
  [ ! -e "$dir/state/.turnend-guard.log" ] || fail "an excluded linked worktree must never write the decision log"
  pass "fm-turnend-guard: the linked-worktree exclusion is fail-closed - a broken git no longer opens the gate"
}

# --- ORD-231 round 3 (qa-g2-q4) --------------------------------------------------

# FINDING 1: the PRODUCTION topology. A crewmate's Stop hook is loaded from its own linked
# worktree, but the crew session inherits FM_ROOT_OVERRIDE pointed at the non-git runtime
# home. The exclusion must key on the HOOK CHECKOUT (where the script lives), NOT the
# overridden operational root - otherwise it inspects the runtime's absent .git, skips the
# exemption, and reruns the primary sweep in the crew worktree, reopening the exact fail-open
# path that produced the 58 bugs. The round-2 tests unset FM_ROOT_OVERRIDE globally, so only
# this case exercises the real inherited-override shape.
test_hook_exclusion_survives_production_fm_root_override() {
  local base dir home runtime pid out status bugcli buglog coalesce
  base="$TMP_ROOT/hook-override-base"
  dir="$TMP_ROOT/hook-override-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  home=$(cd "$dir" && pwd)
  [ -f "$dir/.git" ] || fail "fixture precondition: a linked worktree's .git must be a regular file"
  # A separate, primary-shaped, NON-GIT runtime home - exactly what FM_ROOT_OVERRIDE points at
  # in the fleet. Give it in-flight work so that if the exclusion FOLLOWED the override, it
  # would evaluate this home (find the absent .git, skip the exemption) and act (block on the
  # unattended task with no watcher), writing a decision log here.
  runtime="$TMP_ROOT/hook-override-runtime"
  mkdir -p "$runtime/bin" "$runtime/state"
  : > "$runtime/AGENTS.md"
  : > "$runtime/state/task1.meta"
  write_nf_signal "$runtime" ship-o1 'done: ready in branch fm/ship-o1'
  [ -e "$runtime/.git" ] && fail "fixture precondition: the runtime must be non-git"
  buglog="$TMP_ROOT/hook-override-buglog"
  coalesce="$TMP_ROOT/hook-override-coalesce"
  bugcli=$(install_bug_stub "$dir" "$buglog")
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 \
    FM_ROOT_OVERRIDE="$runtime" FM_HOME="$runtime" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_FLEET_TRIAGE_BUG_CLI="$bugcli" \
    bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "a crew worktree carrying a production FM_ROOT_OVERRIDE must stay inert, never fail open"
  [ -z "$out" ] || fail "the overridden crew worktree produced output: $out"
  [ ! -e "$dir/state/.turnend-guard.log" ] || fail "the crew worktree must not write a decision log"
  [ ! -e "$runtime/state/.turnend-guard.log" ] || fail "the exclusion must not evaluate the overridden runtime at all"
  [ ! -s "$buglog" ] || fail "an excluded crew worktree must file no bug: $(cat "$buglog" 2>/dev/null)"
  pass "fm-turnend-guard: the linked-worktree exclusion keys on the hook checkout, so a production FM_ROOT_OVERRIDE cannot reopen the fail-open path"
}

# FINDING 4: a valid PRIMARY created with a separate git dir (git init --separate-git-dir) has
# a .git FILE too, but it is a main checkout - its gitfile targets its own git dir, not a
# .../worktrees/ path, and git-dir equals git-common-dir. The exclusion must guard it, not
# silently exempt it as if every .git file meant a linked worktree.
test_hook_separate_git_dir_primary_is_guarded() {
  local dir home sepgit pid out status
  dir="$TMP_ROOT/hook-sepgitdir"
  sepgit="$TMP_ROOT/hook-sepgitdir-gitdir"
  mkdir -p "$dir/state"
  git init -q --separate-git-dir="$sepgit" "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  home=$(cd "$dir" && pwd)
  [ -f "$dir/.git" ] || fail "fixture precondition: a separate-git-dir checkout's .git must be a file"
  case "$(cat "$dir/.git" 2>/dev/null)" in
    *"/worktrees/"*) fail "fixture precondition: a separate-git-dir gitfile must not reference /worktrees/" ;;
  esac
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-s1 'done: ready in branch fm/ship-s1'
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "a separate-git-dir PRIMARY must be guarded, not silently exempted as a worktree"
  assert_contains "$out" "ship-s1" "the guarded separate-git-dir primary must name its unattended work"
  [ -e "$dir/state/.turnend-guard.log" ] || fail "a guarded primary must write its decision log"
  pass "fm-turnend-guard: a separate-git-dir primary (a .git FILE that is NOT a worktree) is guarded, not exempted"
}

# FINDING 2: an ABANDONED coalescing lock (left by a hook killed mid-section) must not mute the
# durable signal forever. A stale lock - a dead holder pid or one aged past the stale window -
# is reclaimed, so the occurrence is still recorded and the bug still fires.
test_hook_guard_error_stale_lock_is_reclaimed() {
  local dir home pid stub coalesce slug lock
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-stalelock")
  home=$(cd "$dir" && pwd)
  coalesce="$dir/coalesce"
  stub=$(install_bug_stub "$dir" "$home/bug-calls.log")
  install_always_failing_nf_lib "$dir"
  slug=$(printf '%s' 'fm-nf-attention-lib.sh failed to source' | tr -c 'a-zA-Z0-9' '-')
  # Pre-plant an abandoned lock: a dead holder pid and an ancient epoch, exactly what a hook
  # killed after acquiring the lock leaves behind.
  lock="$coalesce/$slug.lock"
  mkdir -p "$lock"
  printf '%s\n' "$(nonexistent_pid)" > "$lock/pid"
  printf '1\n' > "$lock/epoch"
  pid=$(start_healthy_watcher "$dir")
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_FLEET_TRIAGE_BUG_CLI="$stub" \
    bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  stop_watcher "$pid"
  [ -s "$coalesce/$slug.occurrences" ] || fail "the occurrence must be recorded despite the abandoned lock"
  [ "$(grep -c 'turn-end guard' "$home/bug-calls.log" 2>/dev/null)" -eq 1 ] \
    || fail "the abandoned lock must be reclaimed so the durable bug still fires, got: $(cat "$home/bug-calls.log" 2>/dev/null)"
  [ -f "$coalesce/$slug.record" ] || fail "the shared record must be written after reclaiming the stale lock"
  pass "fm-turnend-guard: an abandoned coalescing lock is reclaimed, so the durable signal is never muted forever"
}

# FINDING 2 / the captain's requirement: coalescing suppresses only duplicate FILINGS, never the
# occurrence itself. A second occurrence in the same window files no new bug, but it MUST still
# surface in the aggregated visible record - the occurrences log and the count.
test_hook_coalesced_occurrence_still_surfaces() {
  local dir home pid stub coalesce slug
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-occrec")
  home=$(cd "$dir" && pwd)
  coalesce="$dir/coalesce"
  stub=$(install_bug_stub "$dir" "$home/bug-calls.log")
  install_always_failing_nf_lib "$dir"
  slug=$(printf '%s' 'fm-nf-attention-lib.sh failed to source' | tr -c 'a-zA-Z0-9' '-')
  pid=$(start_healthy_watcher "$dir")
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_FLEET_TRIAGE_BUG_CLI="$stub" \
    bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_FLEET_TRIAGE_BUG_CLI="$stub" \
    bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  stop_watcher "$pid"
  [ "$(grep -c 'turn-end guard' "$home/bug-calls.log" 2>/dev/null)" -eq 1 ] \
    || fail "the second in-window occurrence must NOT file a new bug: $(cat "$home/bug-calls.log" 2>/dev/null)"
  [ "$(wc -l < "$coalesce/$slug.occurrences" 2>/dev/null | tr -d ' ')" -eq 2 ] \
    || fail "both occurrences must be recorded in the aggregated occurrences log"
  [ "$(grep '^count=' "$coalesce/$slug.record" 2>/dev/null | cut -d= -f2)" = 2 ] \
    || fail "the aggregated record count must include the coalesced occurrence: $(cat "$coalesce/$slug.record" 2>/dev/null)"
  pass "fm-turnend-guard: a coalesced occurrence still surfaces in the aggregated visible record (never silently muted)"
}

# FINDING 3: a FAILED bug filing must not advance the coalescing window as if a bug were filed.
# The window advances only on a confirmed success; a failed CLI leaves the signal eligible for
# a bounded retry (FM_GUARD_ERROR_BUG_RETRY) on the next occurrence.
test_hook_guard_error_failed_filing_stays_eligible() {
  local dir home pid coalesce slug faillog cli
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-clifail")
  home=$(cd "$dir" && pwd)
  coalesce="$dir/coalesce"
  slug=$(printf '%s' 'fm-nf-attention-lib.sh failed to source' | tr -c 'a-zA-Z0-9' '-')
  install_always_failing_nf_lib "$dir"
  # A bug CLI that records each attempt then FAILS.
  faillog="$home/bug-attempts.log"
  mkdir -p "$dir/stubbin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$faillog" > "$dir/stubbin/bugfail"
  chmod +x "$dir/stubbin/bugfail"
  cli="$dir/stubbin/bugfail"
  pid=$(start_healthy_watcher "$dir")
  # Two occurrences with a zero retry backoff so the second is immediately eligible to retry.
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_GUARD_ERROR_BUG_RETRY=0 \
    FM_FLEET_TRIAGE_BUG_CLI="$cli" bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" \
    FM_GUARD_ERROR_COALESCE_DIR="$coalesce" FM_GUARD_ERROR_BUG_RETRY=0 \
    FM_FLEET_TRIAGE_BUG_CLI="$cli" bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  stop_watcher "$pid"
  [ "$(grep -c . "$faillog" 2>/dev/null)" -eq 2 ] \
    || fail "a failed filing must stay eligible: both occurrences must attempt the CLI, got: $(cat "$faillog" 2>/dev/null)"
  [ "$(grep '^last_bug_epoch=' "$coalesce/$slug.record" 2>/dev/null | cut -d= -f2)" = 0 ] \
    || fail "a failed filing must NOT advance last_bug_epoch: $(cat "$coalesce/$slug.record" 2>/dev/null)"
  pass "fm-turnend-guard: a failed bug filing keeps the signal eligible (the window advances only on a confirmed success)"
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
# turn-end block would fight the daemon's own batching loop. But the stand-down is
# level-triggered, not consuming (ORD-059 section 5): the work is still swept and logged
# while away, and the first evaluation after the flag clears blocks on it again.
test_hook_afk_stands_down_without_losing_work() {
  local dir pid out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-afk")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" waiting-k2
  : > "$dir/state/.afk"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must not block on triage state while away mode owns supervision"
  [ -z "$out" ] || fail "hook produced triage output while away: $out"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_afk_owner ] || fail "the away permit is a stand-down, never a compliant permit: $log"
  [ "$(printf '%s' "$log" | jq -r '.nf_gate')" = afk ] || fail "the stand-down must be honest in the log: $log"
  printf '%s' "$log" | jq -r '.nf_items' | grep -q 'waiting-k2' || fail "the stood-down work must still be on the record: $log"
  # AFK exit: the very next evaluation re-blocks on the same untouched work.
  rm "$dir/state/.afk"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "the first evaluation after away mode ends must re-block on untouched work"
  assert_contains "$out" "waiting-k2" "no work may be lost across an away stretch"
  pass "fm-turnend-guard: away mode stands down without losing work, and afk exit re-evaluates immediately"
}

# FM_TRIAGE_DUTY=off is the captain-sanctioned kill switch for the whole fleet-triage duty;
# the gate is part of the duty, so the switch stands it down too - but an escape hatch in
# use must be LOUD and logged as a stand-down, never a silent normal path (ORD-059
# section 5).
test_hook_duty_kill_switch_is_loud_and_logged() {
  local dir home pid out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-dutyoff")
  home=$(cd "$dir" && pwd)
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" waiting-l3
  out=$(printf '{"stop_hook_active":false}' \
    | CLAUDECODE=1 FM_HOME="$home" FM_TRIAGE_DUTY=off bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "FM_TRIAGE_DUTY=off must disable the duty's block"
  assert_contains "$out" "KILL SWITCH ENGAGED" "the kill switch in use must be loud, never silent"
  assert_contains "$out" "waiting-l3" "the kill-switch banner must name the work it is suppressing"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_duty_disabled ] || fail "the kill-switch permit is a stand-down, never a compliant permit: $log"
  [ "$(printf '%s' "$log" | jq -r '.nf_gate')" = duty-off ] || fail "the stand-down must be honest in the log: $log"
  pass "fm-turnend-guard: the duty kill switch stands the gate down loudly and is logged as allowed_duty_disabled"
}

# THE ORD-059 SECTION 1 CASE: block, resume, handle NOTHING, stop again. The loop guard
# must still permit the second stop (never a wedged session), but the record must say
# allowed_loop_protection_without_progress - an enforcement stand-down - never a compliant permit. The
# acceptance metric cannot be satisfied by recursion protection.
test_hook_unchanged_second_stop_is_a_stand_down_not_a_permit() {
  local dir pid out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-loopguard")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" still-open-m4
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "the first stop attempt must block"
  # The model resumed and handled nothing: the unattended id set is unchanged.
  out=$(run_hook "$dir" true); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "stop_hook_active=true must still permit the stop (never an un-endable session)"
  [ -z "$out" ] || fail "hook produced output on the loop-guarded retry: $out"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_loop_protection_without_progress ] \
    || fail "an unchanged second stop must be recorded as allowed_loop_protection_without_progress, got: $log"
  [ "$(printf '%s' "$log" | jq -r '.loop_protection')" = true ] || fail "the log must say loop protection was active: $log"
  [ "$(printf '%s' "$log" | jq -r '.needs_firstmate')" = 1 ] || fail "the log must still count the unattended work: $log"
  case "$(printf '%s' "$log" | jq -r '.decision')" in
    allowed_needs_firstmate_empty|allowed_after_valid_progress)
      fail "an unchanged second stop must never read as a compliant permit: $log" ;;
  esac
  pass "fm-turnend-guard: an unchanged second stop is recorded as a loop-protection stand-down, not a compliant permit"
}

# The compliant loop-guarded permit: the blocked id set actually shrank before the second
# stop attempt, because work was genuinely discharged.
test_hook_second_stop_after_real_progress_is_allowed_after_valid_progress() {
  local dir pid out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-nf-progress")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-n5
  write_nf_signal "$dir" ship-n6
  run_hook "$dir" false >/dev/null 2>&1
  # ship-n5 lands and is torn down; ship-n6 is still unattended.
  rm "$dir/state/ship-n5.meta" "$dir/state/ship-n5.status"
  out=$(run_hook "$dir" true); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "the loop-guarded stop after real progress must be permitted"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_after_valid_progress ] \
    || fail "a shrunken blocked set must be recorded as allowed_after_valid_progress: $log"
  [ "$(printf '%s' "$log" | jq -r '.needs_firstmate')" = 1 ] || fail "the remaining work must still be counted: $log"
  pass "fm-turnend-guard: a second stop after the blocked set shrank is recorded as allowed_after_valid_progress"
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

test_hook_codex_accepts_valid_checkpoint_schedule() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-scheduled")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 quiet
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 0 "$status" "Codex hook must accept a valid future next-checkpoint schedule"
  [ -z "$out" ] || fail "Codex hook produced output with valid scheduled supervision: $out"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.watcher')" = healthy-checkpoint-scheduled ] \
    || fail "Codex scheduled permit did not log healthy-checkpoint-scheduled: $log"
  [ "$(printf '%s' "$log" | jq -r '.supervision_harness')" = codex ] \
    || fail "Codex scheduled permit did not log the codex harness: $log"
  pass "fm-turnend-guard: Codex accepts a durable future next-checkpoint schedule"
}

test_hook_codex_rejects_no_watcher_and_no_schedule() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-noschedule")
  : > "$dir/state/task1.meta"
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block with no watcher and no durable schedule"
  assert_contains "$out" "TURN WOULD END BLIND" "Codex no-schedule block must report supervision continuity"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-no-supervision ] \
    || fail "Codex no-schedule block did not log unhealthy-no-supervision: $log"
  pass "fm-turnend-guard: Codex rejects no watcher and no durable schedule"
}

test_hook_codex_rejects_overdue_checkpoint_schedule() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-overdue")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -120 1 0 quiet
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block on an overdue next-checkpoint schedule"
  assert_contains "$out" "unhealthy-checkpoint-overdue" "Codex overdue block must name the overdue health state"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-checkpoint-overdue ] \
    || fail "Codex overdue block did not log unhealthy-checkpoint-overdue: $log"
  pass "fm-turnend-guard: Codex rejects overdue next-checkpoint schedules"
}

test_hook_codex_rejects_malformed_checkpoint_schedule() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-malformed")
  : > "$dir/state/task1.meta"
  printf '{not-json\n' > "$dir/state/.codex-watch-checkpoint.next.json"
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block on a malformed next-checkpoint schedule"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_reason')" = malformed-schedule ] \
    || fail "Codex malformed schedule reason was not logged: $log"
  pass "fm-turnend-guard: Codex rejects malformed next-checkpoint schedules"
}

test_hook_codex_rejects_owner_mismatch_schedule() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-owner-mismatch")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 quiet other-primary
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block when the schedule owner does not match this primary"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-owner-mismatch ] \
    || fail "Codex owner mismatch did not log unhealthy-owner-mismatch: $log"
  pass "fm-turnend-guard: Codex rejects schedule ownership mismatches"
}

test_hook_codex_rejects_duplicate_checkpoint_schedules() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-duplicate-schedule")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 quiet
  cp "$dir/state/.codex-watch-checkpoint.next.json" "$dir/state/.codex-watch-checkpoint.next.extra.json"
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block on duplicate active schedule ownership"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-duplicate-owner ] \
    || fail "Codex duplicate schedule did not log unhealthy-duplicate-owner: $log"
  pass "fm-turnend-guard: Codex rejects duplicate active checkpoint schedules"
}

test_hook_codex_rejects_disabled_scheduler() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-disabled-scheduler")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 quiet
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$dir/fake-systemd" "$dir/bin/fm-codex-systemd-scheduler.sh" disable --home "$dir" --state "$dir/state" \
    || fail "fake scheduler disable failed"
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block when scheduler registration is disabled"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-no-supervision ] \
    || fail "Codex disabled scheduler did not log unhealthy-no-supervision: $log"
  assert_contains "$(printf '%s' "$log" | jq -r '.supervision_reason')" "timer-not-registered" \
    "Codex disabled scheduler reason was not logged"
  pass "fm-turnend-guard: Codex rejects a disabled managed scheduler"
}

test_hook_codex_rejects_bad_generation_and_excessive_lateness() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-bad-fields")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 quiet
  rewrite_codex_schedule "$dir" '.generation = 0'
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block on zero schedule generation"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_reason')" = bad-generation ] \
    || fail "Codex bad generation reason was not logged: $log"
  rm -f "$dir/state/.codex-watch-checkpoint.next.json" "$dir"/fake-systemd/timers/*.json
  write_codex_schedule "$dir" -1 60 60 quiet
  rewrite_codex_schedule "$dir" '.max_lateness_seconds = 999999'
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block on excessive self-declared lateness"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_reason')" = bad-lateness ] \
    || fail "Codex bad lateness reason was not logged: $log"
  pass "fm-turnend-guard: Codex rejects bad schedule generation and excessive lateness"
}

test_hook_codex_production_identity_override_cannot_make_wrong_owner_healthy() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-prod-identity-override")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 quiet forged-primary
  out=$(run_hook_codex_production_identity_override "$dir" false forged-primary); status=$?
  expect_code 2 "$status" "production Codex health must ignore FM_CODEX_PRIMARY_IDENTITY override"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-owner-mismatch ] \
    || fail "Codex production identity override did not fail as owner mismatch: $log"
  pass "fm-turnend-guard: production Codex health does not accept ambient primary identity override"
}

# forge_codex_supervision_files <dir> <identity>: the review-r2 attack fixture -
# a hand-written durable harness record, schedule (checksum recomputed), and fake
# scheduler registration, with NO process backing the claimed identity. Metadata
# is computed via a gated test-mode call; the attack itself runs in production.
forge_codex_supervision_files() {
  local dir=$1 identity=$2 home meta payload hash now uid
  home=$(cd "$dir" && pwd)
  now=$(date +%s)
  uid=$(id -u)
  meta=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$dir/fake-systemd" \
    "$dir/bin/fm-codex-systemd-scheduler.sh" unit-metadata --home "$home" --state "$home/state") \
    || fail "could not compute unit metadata for forged fixture"
  jq -cnS --arg identity "$identity" --arg home "$home" --argjson uid "$uid" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{version:1,harness:"codex",primary_identity:$identity,fm_home:$home,uid:$uid,recorded_at:$ts}' \
    > "$dir/state/.primary-harness.json" || fail "could not forge primary harness record"
  payload=$(jq -cnS --argjson scheduler "$meta" --arg identity "$identity" \
    --arg home "$home" --arg state "$home/state" --argjson now "$now" \
    '{version:1,harness:"codex",owner:("codex:" + $identity),primary_identity:$identity,
      fm_home:$home,state_dir:$state,previous_checkpoint_start:($now - 2),
      previous_checkpoint_end:($now - 1),previous_result:"quiet",
      next_checkpoint_due:($now + 60),cadence_seconds:60,max_lateness_seconds:60,
      generation:1,lease_id:"forged-lease",mechanism:"codex-bounded-checkpoint",
      scheduling_mechanism:"systemd-user-timer",scheduler:$scheduler}') || fail "could not forge schedule payload"
  hash=$(printf '%s\n' "$payload" | sha256sum | awk '{print $1}')
  printf '%s\n' "$payload" | jq -cS --arg integrity "sha256:$hash" '. + {integrity:$integrity}' \
    > "$dir/state/.codex-watch-checkpoint.next.json" || fail "could not forge schedule record"
  mkdir -p "$dir/fake-systemd/timers"
  jq -cnS --argjson scheduler "$meta" --arg home "$home" --arg state "$home/state" --argjson now "$now" \
    '{registered:true,lease_id:"forged-lease",generation:1,cadence_seconds:60,
      next_checkpoint_due:($now + 60),previous_result:"quiet",fm_home:$home,
      state_dir:$state,harness:"codex",metadata:$scheduler}' \
    > "$dir/fake-systemd/timers/$(printf '%s' "$meta" | jq -r '.unit_name').json" \
    || fail "could not forge fake registration"
}

# The review-r2 F-2 reproduction as a permanent regression: three hand-written
# files, zero processes, no lock, no test mode - the forged owner must never
# make scheduled Codex supervision healthy.
test_hook_codex_forged_state_files_cannot_own_schedule() {
  local dir home out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-forged-files")
  home=$(cd "$dir" && pwd)
  : > "$dir/state/task1.meta"
  forge_codex_supervision_files "$dir" 'pid:999999:totally-made-up'
  out=$(printf '{"stop_hook_active":false}' | FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "forged durable identity files must not make Codex scheduled supervision healthy"
  assert_contains "$out" "TURN WOULD END BLIND" "forged schedule must be reported as missing supervision continuity"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-owner-mismatch ] \
    || fail "forged owner did not fail as owner mismatch: $log"
  [ "$(printf '%s' "$log" | jq -r '.supervision_harness')" = codex ] \
    || fail "forged fixture should still resolve the codex branch to prove the block: $log"
  pass "fm-turnend-guard: hand-written state files with no live primary never prove Codex scheduled health"
}

# The review-r2 F-1 reproduction as a permanent regression: a LIVE primary with a
# genuinely owned schedule, evaluated in production with the ambient fake-dir
# override exported. The adapter must fail closed instead of reading the fake
# registration, so the turn is blocked even though every durable file agrees.
test_hook_codex_production_ambient_fake_dir_cannot_fake_health() {
  local dir home out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-ambient-fake-dir")
  home=$(cd "$dir" && pwd)
  : > "$dir/state/task1.meta"
  printf '%s\n' "$$" > "$dir/state/.lock"
  write_codex_schedule "$dir" -1 60 60 quiet
  out=$(printf '{"stop_hook_active":false}' | FM_CODEX_SYSTEMD_FAKE_DIR="$dir/fake-systemd" FM_HOME="$home" \
    bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "ambient FM_CODEX_SYSTEMD_FAKE_DIR must not substitute a file for the real scheduler query"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" != healthy-checkpoint-scheduled ] \
    || fail "ambient fake dir produced healthy scheduled supervision: $log"
  assert_contains "$(printf '%s' "$log" | jq -r '.supervision_reason')" "test-override-without-test-mode" \
    "the block must name the ungated test override"
  pass "fm-turnend-guard: production Codex health fails closed on an ambient fake-scheduler override"
}

# The review-r5 F-1 reproduction as a permanent regression: a NON-test-owned
# home (no .fm-test-owner ancestor, like any production home), hand-forged
# durable records claiming a synthetic test identity, no session lock, and
# ambient FM_SUPERVISION_TEST_MODE=1 plus a fake-scheduler override - exactly
# the hermetic probe the r5 review used to turn health green. The shared
# supervision boundary must fail the identity resolution closed, so the guard
# blocks. Metadata is forged by hand because the adapter itself refuses its
# test seams for a non-test-owned home.
test_hook_codex_ambient_test_mode_outside_test_owned_home_is_never_green() {
  local dir home out status log meta payload hash uid now
  dir=$(mktemp -d) || fail "mktemp failed"
  FM_TEST_CLEANUP_DIRS+=("$dir")
  make_primary_dir "$dir" >/dev/null
  home=$(cd "$dir" && pwd)
  : > "$dir/state/task1.meta"
  uid=$(id -u)
  now=$(date +%s)
  jq -cnS --arg home "$home" --argjson uid "$uid" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{version:1,harness:"codex",primary_identity:("test:codex:" + $home),fm_home:$home,uid:$uid,recorded_at:$ts}' \
    > "$dir/state/.primary-harness.json" || fail "could not write forged harness record"
  meta=$(jq -cnS --arg home "$home" --arg state "$home/state" --argjson uid "$uid" \
    '{adapter:"systemd-user-timer",unit_name:"fm-codex-checkpoint-feedfacefeedface",
      service_name:"fm-codex-checkpoint-feedfacefeedface.service",
      timer_name:"fm-codex-checkpoint-feedfacefeedface.timer",
      unit_dir:($home + "/fake-systemd/units"),
      service_path:($home + "/fake-systemd/units/fm-codex-checkpoint-feedfacefeedface.service"),
      timer_path:($home + "/fake-systemd/units/fm-codex-checkpoint-feedfacefeedface.timer"),
      exec_path:($home + "/bin/fm-watch-checkpoint.sh"),fm_home:$home,state_dir:$state,uid:$uid}') \
    || fail "could not forge scheduler metadata"
  payload=$(jq -cnS --argjson scheduler "$meta" --arg home "$home" --arg state "$home/state" --argjson now "$now" \
    '{version:1,harness:"codex",owner:("codex:test:codex:" + $home),primary_identity:("test:codex:" + $home),
      fm_home:$home,state_dir:$state,previous_checkpoint_start:($now - 2),previous_checkpoint_end:($now - 1),
      previous_result:"quiet",next_checkpoint_due:($now + 60),cadence_seconds:60,max_lateness_seconds:60,
      generation:1,lease_id:"ambient-lease",mechanism:"codex-bounded-checkpoint",
      scheduling_mechanism:"systemd-user-timer",scheduler:$scheduler}') || fail "could not forge schedule payload"
  hash=$(printf '%s\n' "$payload" | sha256sum | awk '{print $1}')
  printf '%s\n' "$payload" | jq -cS --arg integrity "sha256:$hash" '. + {integrity:$integrity}' \
    > "$dir/state/.codex-watch-checkpoint.next.json" || fail "could not write forged schedule"
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "ambient test mode outside a test-owned home must never prove Codex scheduled health"
  assert_contains "$out" "TURN WOULD END BLIND" "the ambient test-mode attack must be reported as missing supervision continuity"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-owner-mismatch ] \
    || fail "ambient test-mode attack did not fail as owner mismatch: $log"
  rm -rf "$dir"
  pass "fm-turnend-guard: R5 ambient FM_SUPERVISION_TEST_MODE with no live primary is never green"
}

# Scheduled Codex health is bound to the LIVE primary: the same schedule is
# healthy while the session lock holder that owns it is alive, and unhealthy the
# moment the lock names a dead or different session.
test_hook_codex_schedule_bound_to_live_primary() {
  local dir out status log dead
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-live-binding")
  : > "$dir/state/task1.meta"
  printf '%s\n' "$$" > "$dir/state/.lock"
  write_codex_schedule "$dir" -1 60 60 quiet
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 0 "$status" "a schedule owned by the live locked primary must be healthy"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.watcher')" = healthy-checkpoint-scheduled ] \
    || fail "live-owner schedule did not log healthy-checkpoint-scheduled: $log"
  dead=$(nonexistent_pid)
  printf '%s\n' "$dead" > "$dir/state/.lock"
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "the same schedule must turn unhealthy once its owning session is gone"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-owner-mismatch ] \
    || fail "dead-session schedule did not fail as owner mismatch: $log"
  pass "fm-turnend-guard: Codex scheduled health is bound to the live verified primary, not to file content"
}

test_hook_codex_failed_checkpoint_is_not_green() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-failed")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 failed
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block after a failed checkpoint with no recovery schedule"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-last-checkpoint-failed ] \
    || fail "Codex failed checkpoint did not log unhealthy-last-checkpoint-failed: $log"
  pass "fm-turnend-guard: failed Codex checkpoint does not leave supervision falsely green"
}

test_hook_codex_normal_bounded_exit_is_not_a_crash() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-normal-exit")
  : > "$dir/state/task1.meta"
  touch "$dir/state/.last-watcher-beat"
  write_codex_schedule "$dir" -1 60 60 quiet
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 0 "$status" "Codex hook must treat normal bounded checkpoint exit as healthy when schedule is valid"
  [ -z "$out" ] || fail "normal bounded checkpoint exit was reported as a crash: $out"
  pass "fm-turnend-guard: normal bounded Codex checkpoint exit is healthy by schedule, not a watcher crash"
}

test_hook_codex_rejects_schedule_without_scheduler_registration() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-no-systemd")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 quiet
  rm -f "$dir"/fake-systemd/timers/*.json
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "Codex hook must block when the durable record has no scheduler registration"
  assert_contains "$out" "TURN WOULD END BLIND" "missing scheduler registration must report supervision continuity failure"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.supervision_health')" = unhealthy-no-supervision ] \
    || fail "Codex missing scheduler registration did not log unhealthy-no-supervision: $log"
  assert_contains "$(printf '%s' "$log" | jq -r '.supervision_reason')" "timer-not-registered" \
    "Codex missing scheduler registration reason was not logged"
  pass "fm-turnend-guard: Codex rejects timestamp-only schedule continuity without managed scheduler registration"
}

test_hook_codex_unattended_gate_still_blocks_with_healthy_schedule() {
  local dir out status log
  dir=$(make_primary_dir "$TMP_ROOT/hook-codex-nf-with-schedule")
  : > "$dir/state/task1.meta"
  write_codex_schedule "$dir" -1 60 60 quiet
  write_nf_signal "$dir" codex-done-a1 'done: ready in branch fm/codex-done-a1'
  out=$(run_hook_codex "$dir" false); status=$?
  expect_code 2 "$status" "unattended finished work must still block even when Codex schedule continuity is healthy"
  assert_contains "$out" "TURN WOULD END WITH FINISHED WORK UNATTENDED" "unattended-work gate did not fire"
  assert_not_contains "$out" "TURN WOULD END BLIND" "healthy Codex schedule must not be reported as supervision blind"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.reason')" = unattended-needs-firstmate ] \
    || fail "Codex unattended block should name only unattended work: $log"
  pass "fm-turnend-guard: unattended terminal work gate remains independent of scheduled Codex supervision"
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

# A secondmate's OWN home runs a primary firstmate session and must be guarded
# exactly like the main primary. This was the guard's proven blind spot: the
# .fm-secondmate-home marker used to early-exit here, so an overnight secondmate
# could end a turn with an unsupervised child and sit blind. Removing that marker
# check makes the guard fire, mirroring the cd-guard.
test_hook_blocks_in_secondmate_own_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must guard a secondmate's own home like the main primary when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks a blind turn end in a secondmate's own home (.fm-secondmate-home no longer excludes it)"
}

# Idle-by-default: an empty-queue secondmate has no in-flight meta, so the guard
# exits at the in-flight gate - never forcing a busy continuation loop.
test_hook_silent_in_idle_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must stay silent in an idle, empty-queue secondmate home"
  [ -z "$out" ] || fail "idle secondmate home produced guard output: $out"
  pass "fm-turnend-guard: idle-by-default - silent in a secondmate home with nothing in flight"
}

# The stop_hook_active loop guard bounds the secondmate to one forced
# continuation per turn, exactly as it does for the main primary - no wedged,
# un-endable session.
test_hook_secondmate_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "hook must allow the stop in a secondmate home when stop_hook_active is already true"
  [ -z "$out" ] || fail "secondmate loop-guarded retry produced output: $out"
  pass "fm-turnend-guard: stop_hook_active=true allows the stop in a secondmate home (never blocks twice in one turn)"
}

# The guard's half of the deferred-death recovery loop in a secondmate home,
# proven deterministically without a live model or any daemon: silent while the
# watcher is live (the secondmate ends its turn and relies on the background
# re-invoke), then blocks to force the re-arm once the watcher has exited and a
# second child event lands. The live half - that Claude Code autonomously
# re-invokes the model when the background watcher exits (Mechanism A) - is a
# harness property recorded empirically in docs/turnend-guard.md; it needs a live
# session and cannot be a hermetic CI assertion.
test_hook_secondmate_reinvoke_recovery_loop() {
  local dir pid identity out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-reinvoke")
  : > "$dir/state/child1.meta"
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
  expect_code 0 "$status" "secondmate turn must end silently while its watcher is live (Stop #1)"
  [ -z "$out" ] || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "guard nagged a healthy secondmate at Stop #1: $out"
  }
  # The watcher exits on the wake (its normal lifecycle) and a SECOND child event
  # lands. On the re-invoked recovery turn the secondmate must re-arm; if it did
  # not, the guard blocks that turn's end and forces the re-arm (Stop #2).
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir/state/.watch.lock"
  : > "$dir/state/child2.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "secondmate recovery turn must not end blind after the watcher exits (Stop #2)"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: secondmate deferred-death recovery - silent while watched, forces re-arm once the watcher exits"
}

# The marker force-include must guard only the secondmate's OWN home, never its
# children: a secondmate's linked crew/scout worktree carries no marker, so it
# stays exempt by the same git-dir/git-common-dir test that exempts the main
# home's children.
test_hook_silent_in_secondmate_child_worktree() {
  local home dir out status
  home=$(make_secondmate_dir "$TMP_ROOT/hook-sm-child-home")
  dir="$TMP_ROOT/hook-sm-child-wt"
  make_secondmate_child_worktree_dir "$home" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must stay exempt in a secondmate's own child crew/scout worktree"
  [ -z "$out" ] || fail "hook produced output inside a secondmate's child worktree: $out"
  pass "fm-turnend-guard: inert in a secondmate's own child worktree (linked git worktree) even when unhealthy"
}

# THE regression the plain git-init fixtures masked: a treehouse-leased secondmate
# home is a genuine LINKED worktree (git-dir != git-common-dir), which the
# remove-only form wrongly exempted. With the marker force-include, its own
# primary session is GUARDED. The test asserts the fixture really is a linked
# worktree so it can never silently regress back into a plain-checkout shape.
test_hook_blocks_in_treehouse_leased_secondmate_home() {
  local base dir gd gcd out status
  base="$TMP_ROOT/hook-sm-leased-base"
  dir="$TMP_ROOT/hook-sm-leased-home"
  make_secondmate_linked_home_dir "$base" "$dir" >/dev/null
  gd=$(git -C "$dir" rev-parse --git-dir)
  gcd=$(git -C "$dir" rev-parse --git-common-dir)
  [ "$gd" != "$gcd" ] || fail "leased-home fixture must be a linked worktree (git-dir != git-common-dir), got equal: $gd"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must GUARD a treehouse-leased (linked) secondmate home via its marker when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks a blind turn end in a treehouse-leased LINKED secondmate home (marker force-include)"
}

# Anti-spoof: a linked worktree with an INVALID (empty) marker must NOT be
# force-included. Marker validation rejects it, so it falls through to the
# linked-worktree exemption and stays exempt - a stray/empty marker file can
# never spoof a child worktree into being guarded.
test_hook_exempts_linked_worktree_with_stray_marker() {
  local base dir out status
  base="$TMP_ROOT/hook-stray-marker-base"
  dir="$TMP_ROOT/hook-stray-marker-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "an empty/invalid marker must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "stray empty marker wrongly force-included a linked worktree: $out"
  pass "fm-turnend-guard: an invalid (empty) marker cannot spoof inclusion; linked worktree stays exempt"
}

# Anti-spoof under any locale: a NON-ASCII marker id must be REJECTED by the
# ASCII-only (C-collation) allowlist, so it can never force-include a linked
# worktree even where the ambient locale's collation would treat it as a letter.
# Rejection -> git-dir exemption -> the linked worktree stays exempt.
test_hook_exempts_linked_worktree_with_non_ascii_marker() {
  local base dir out status
  base="$TMP_ROOT/hook-nonascii-marker-base"
  dir="$TMP_ROOT/hook-nonascii-marker-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  printf 'caf\xc3\xa9\n' > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "a non-ASCII marker id must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "non-ASCII marker wrongly force-included a linked worktree: $out"
  pass "fm-turnend-guard: a non-ASCII marker cannot spoof inclusion; linked worktree stays exempt"
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

# THE DEPLOYED SHAPE, and the case whose absence let the gate ship dead
# (bug-20260714023716-7c5e1bfb). Every fixture above is a git repo, because the template
# is one. The home the gate is actually INSTALLED in is not: a rebaselined runtime home
# is a plain directory tree with bin/ as an ordinary directory and no .git anywhere. The
# old scoping opened with `git rev-parse --git-dir || exit 0`, so there - and only there -
# the guard exited before evaluating anything, logged nothing, and could never block,
# while this suite stayed green over a git fixture. A green suite over a mechanism that
# cannot fire where it is deployed is not evidence. This test runs the guard in the
# deployed shape.
make_nongit_primary_dir() {  # <dir> - a rebaselined runtime home: NO .git, ever
  local dir=$1
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  [ -e "$dir/.git" ] && fail "the non-git fixture must not contain a .git: $dir"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 \
    && fail "the non-git fixture must not resolve as a git checkout: $dir"
  printf '%s\n' "$dir"
}

test_hook_blocks_on_unattended_work_in_a_nongit_primary_home() {
  local dir pid out status log
  dir=$(make_nongit_primary_dir "$TMP_ROOT/hook-nongit-block")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-n1 'done: ready in branch fm/ship-n1'
  write_nf_signal "$dir" probe-n2 'needs-decision: two rollout options'
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "hook must block unattended work in a NON-GIT primary home - the shape it is actually deployed in"
  assert_contains "$out" "TURN WOULD END WITH FINISHED WORK UNATTENDED" "the non-git primary must get the same block banner"
  assert_contains "$out" "ship-n1" "the block banner must name the unattended items in a non-git home"
  assert_contains "$out" "probe-n2" "the block banner must name the unattended items in a non-git home"
  log=$(last_guard_log "$dir")
  [ -n "$log" ] || fail "a non-git primary must still write the decision log (state/.turnend-guard.log was never created)"
  [ "$(printf '%s' "$log" | jq -r '.decision')" = blocked_needs_firstmate ] || fail "non-git primary must record blocked_needs_firstmate: $log"
  [ "$(printf '%s' "$log" | jq -r '.needs_firstmate')" = 2 ] || fail "non-git primary must record the lane count: $log"
  pass "fm-turnend-guard: blocks on unattended work in a non-git (rebaselined) primary home, and logs the decision"
}

# The other half of the deployed shape: a non-git primary with a clear lane still permits
# and still records the permit, so "non-git" never means "unevaluated".
test_hook_permits_and_logs_in_a_clear_nongit_primary_home() {
  local dir pid out status log
  dir=$(make_nongit_primary_dir "$TMP_ROOT/hook-nongit-clear")
  pid=$(start_healthy_watcher "$dir")
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "a clear lane in a non-git primary must permit the turn end"
  [ -z "$out" ] || fail "the healthy path in a non-git primary must stay silent: $out"
  log=$(last_guard_log "$dir")
  [ "$(printf '%s' "$log" | jq -r '.decision')" = allowed_needs_firstmate_empty ] || fail "a non-git primary must record its permit, not skip evaluation: $log"
  pass "fm-turnend-guard: a clear non-git primary permits and records allowed_needs_firstmate_empty"
}

# Scoping's third exclusion: a session that lost the per-home session lock is read-only
# (AGENTS.md section 3). It must not block and must not mutate fleet state - no decision
# log, no block-id set.
test_hook_inert_when_another_live_session_owns_the_lock() {
  local dir pid holder out status
  dir=$(make_nongit_primary_dir "$TMP_ROOT/hook-foreign-lock")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-o1 'done: ready in branch fm/ship-o1'
  # A live process that is NOT in this test's ancestry: the session lock's holder.
  sleep 60 >/dev/null 2>&1 &
  holder=$!
  printf '%s\n' "$holder" > "$dir/state/.lock"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$holder"
  stop_watcher "$pid"
  expect_code 0 "$status" "a read-only session (another live session holds the lock) must not block"
  [ -z "$out" ] || fail "a read-only session must stay silent: $out"
  [ ! -e "$dir/state/.turnend-guard.log" ] || fail "a read-only session must not mutate fleet state (it wrote the decision log)"
  [ ! -e "$dir/state/.turnend-guard-block-ids" ] || fail "a read-only session must not mutate fleet state (it wrote the block-id set)"
  pass "fm-turnend-guard: inert and non-mutating when another live session holds the per-home lock"
}

# FAIL ARMED, not inert. A lock is only a stand-down when a live foreign holder proves it:
# a stale lock (dead holder) must leave the gate fully armed, or an unreadable lock becomes
# a second silent way for this gate not to exist.
test_hook_blocks_when_the_session_lock_is_stale() {
  local dir pid dead out status
  dir=$(make_nongit_primary_dir "$TMP_ROOT/hook-stale-lock")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-p1 'done: ready in branch fm/ship-p1'
  dead=$(nonexistent_pid)
  printf '%s\n' "$dead" > "$dir/state/.lock"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "a stale session lock must leave the guard armed, never stand it down"
  assert_contains "$out" "ship-p1" "the armed guard must still name the unattended work"
  pass "fm-turnend-guard: a stale (dead-holder) session lock leaves the gate armed"
}

# The lock held by THIS session's own ancestry is the primary itself: fully armed.
test_hook_blocks_when_this_session_owns_the_lock() {
  local dir pid out status
  dir=$(make_nongit_primary_dir "$TMP_ROOT/hook-own-lock")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-q1 'done: ready in branch fm/ship-q1'
  printf '%s\n' "$$" > "$dir/state/.lock"
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "the lock-owning session is the primary and must be guarded"
  assert_contains "$out" "ship-q1" "the lock-owning primary must be told which work is unattended"
  pass "fm-turnend-guard: armed when the session lock is held by this session's own ancestry"
}

# The linked-worktree exclusion must survive the scoping rewrite: a crewmate/scout worktree
# of firstmate-on-itself carries a state/ dir and an inherited FM_HOME in the real fleet,
# so git-ness is still the discriminator that keeps it inert. Pinned here WITH unattended
# work present, which is the condition that would otherwise block.
test_hook_silent_in_crewmate_worktree_with_unattended_work() {
  local base dir pid out status
  base="$TMP_ROOT/hook-crew-nf-base"
  dir="$TMP_ROOT/hook-crew-nf-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-r1 'done: ready in branch fm/ship-r1'
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 0 "$status" "a crewmate task worktree must stay inert even with unattended work in view"
  [ -z "$out" ] || fail "hook produced output inside a crewmate task worktree: $out"
  [ ! -e "$dir/state/.turnend-guard.log" ] || fail "a crewmate task worktree must not write the decision log"
  pass "fm-turnend-guard: still inert in a linked crewmate worktree when unattended work is present"
}

# Same, for a secondmate home: it runs its OWN primary firstmate session, so the
# marker force-includes it and unattended work blocks its turn end exactly as it
# does for the main primary (the crewmate-worktree exemption above does not apply).
test_hook_blocks_in_secondmate_home_with_unattended_work() {
  local dir pid out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-nf")
  pid=$(start_healthy_watcher "$dir")
  write_nf_signal "$dir" ship-s1 'done: ready in branch fm/ship-s1'
  out=$(run_hook "$dir" false); status=$?
  stop_watcher "$pid"
  expect_code 2 "$status" "a secondmate home must block a turn end while unattended work is in view"
  [ -n "$out" ] || fail "the block in a secondmate home printed no reason"
  [ -e "$dir/state/.turnend-guard.log" ] || fail "a blocked secondmate evaluation must write the decision log"
  pass "fm-turnend-guard: blocks on unattended work in a secondmate home (guarded like the main primary)"
}

test_hook_missing_jq_is_a_loud_guard_error() {
  local dir out status fakebin tool tool_path log
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
  assert_contains "$out" "TURN-END GUARD ERROR" "a missing jq in the primary is a guard outage, never a silent permit"
  assert_contains "$out" "jq" "the failed component must be named"
  log=$(tail -n 1 "$dir/state/.turnend-guard.log" 2>/dev/null)
  case "$log" in
    *'"decision":"allowed_guard_error"'*) : ;;
    *) fail "a missing jq must still log a guard_error decision, got: $log" ;;
  esac
  pass "fm-turnend-guard: fails open on missing jq with a loud guard-error banner and record"
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

# --- DECISION LOG: the guard must explain its own decision --------------------
#
# "No live watcher (last beat: 1s ago)" reads as impossible - and a log that records
# only that verdict cannot settle it. The beacon outlives the watcher that touched it,
# so a fresh beacon with an absent lock is perfectly consistent and perfectly real: a
# broken check woke the watcher every cycle, it exited every cycle, and it released the
# lock every cycle. Three wrong diagnoses came out of a decision record that could not
# say WHICH check failed. Every evaluation now records the observations.

log_field() {
  local dir=$1 field=$2
  tail -n 1 "$dir/state/.turnend-guard.log" 2>/dev/null \
    | sed -n "s/.*\"$field\":\"\{0,1\}\([^,\"]*\)\"\{0,1\}.*/\1/p"
}

test_hook_logs_the_observations_behind_a_block() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-log-block")
  : > "$dir/state/task1.meta"
  dead=$(nonexistent_pid)
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block on a dead watcher lock"
  [ -s "$dir/state/.turnend-guard.log" ] || fail "the block wrote no decision record at all"
  [ "$(log_field "$dir" decision)" = blocked_watcher_down ] || fail "decision was not recorded: $(tail -n1 "$dir/state/.turnend-guard.log")"
  [ "$(log_field "$dir" lock_pid)" = "$dead" ] || fail "the lock pid it actually read was not recorded"
  [ "$(log_field "$dir" lock_pid_alive)" = false ] || fail "whether the lock pid was alive was not recorded"
  [ "$(log_field "$dir" watcher_fail)" = lock-pid-dead ] || fail "the failing check was not named: $(tail -n1 "$dir/state/.turnend-guard.log")"
  case "$(log_field "$dir" beacon_age)" in
    ''|*[!0-9]*) fail "beacon age was not recorded as a number: $(tail -n1 "$dir/state/.turnend-guard.log")" ;;
  esac
  # And on screen, so a blocked turn is readable without opening the log.
  assert_contains "$out" "observed: lock pid=$dead alive=false" "the banner must state what it observed"
  pass "fm-turnend-guard: a block records the lock pid, its liveness, the beacon age, and which check failed"
}

test_hook_logs_an_absent_lock_distinctly_from_a_mismatched_one() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-log-no-lock")
  : > "$dir/state/task1.meta"
  # The real production shape: the watcher woke, exited, and took the lock with it,
  # leaving a FRESH beacon behind. Absent must not be logged as if it were a stale or
  # mismatched lock - that distinction is what a diagnosis turns on.
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when no watcher holds the lock"
  [ "$(log_field "$dir" watcher_fail)" = no-lock-pid ] || fail "an absent lock was not recorded distinctly: $(tail -n1 "$dir/state/.turnend-guard.log")"
  [ "$(log_field "$dir" lock_pid)" = none ] || fail "an absent lock pid was not recorded as none"
  [ "$(log_field "$dir" identity_match)" = unknown ] || fail "an identity comparison that never ran must not be recorded as a result"
  pass "fm-turnend-guard: an absent lock is recorded as absent, not as a failed identity match"
}

test_hook_logs_an_allowed_healthy_evaluation() {
  local dir pid identity status
  dir=$(make_primary_dir "$TMP_ROOT/hook-log-allow")
  : > "$dir/state/task1.meta"
  sleep 300 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid")
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  run_hook "$dir" false >/dev/null; status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must allow a live, identity-matched watcher"
  [ "$(log_field "$dir" decision)" = allowed_needs_firstmate_empty ] || fail "a permitted turn end was not recorded"
  [ "$(log_field "$dir" identity_match)" = true ] || fail "the identity comparison result was not recorded on the allow path"
  [ "$(log_field "$dir" watcher_fail)" = none ] || fail "a healthy evaluation must record no failing check"
  pass "fm-turnend-guard: permitted turn ends are recorded too, with the comparisons that permitted them"
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

# --- .pi extensions under bare node -----------------------------------------
#
# The Pi extensions are tracked as .ts because Pi loads them through its own
# TypeScript loader. Tests that exercise their REAL logic import them under bare
# node instead, and node's ability to load .ts varies by host: >= 22.18 strips
# types natively, older ones reject the extension outright
# (ERR_UNKNOWN_FILE_EXTENSION), and some distro builds ship without the stripper
# altogether (ERR_NO_TYPESCRIPT). So probe this node once, then either import the
# .ts directly or fall back to an equivalent type-stripped .mjs. The extension's
# logic is exercised either way - only the type annotations differ - so the suite
# stays green on any node without pinning one.
NODE_IMPORTS_TS=""
node_imports_ts() {
  if [ -z "$NODE_IMPORTS_TS" ]; then
    local probe="$TMP_ROOT/ts-probe.ts"
    mkdir -p "$TMP_ROOT"
    printf 'export const answer: number = 1;\n' > "$probe"
    if TS_PROBE="$probe" node --input-type=module >/dev/null 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.TS_PROBE).href);
if (mod.answer !== 1) process.exit(1);
EOF
    then NODE_IMPORTS_TS=yes
    else NODE_IMPORTS_TS=no
    fi
  fi
  [ "$NODE_IMPORTS_TS" = yes ]
}

# Install the tracked pi turn-end extension into <ext-dir> in a form this node
# can import, and echo the importable path. It must land in <repo>/.pi/extensions
# either way: the extension resolves its repo root from its own directory (../..)
# to find bin/fm-turnend-guard.sh.
install_pi_turnend_extension() {  # <ext-dir> -> echoes plugin path
  local dir=$1 src dest
  src="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  if node_imports_ts; then
    dest="$dir/fm-primary-turnend-guard.ts"
    cp "$src" "$dest"
  else
    dest="$dir/fm-primary-turnend-guard.mjs"
    node "$ROOT/tests/lib/strip-ts-types.mjs" "$src" "$dest" \
      || fail "could not type-strip the pi extension for a node that cannot import .ts"
  fi
  printf '%s\n' "$dest"
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
  log="$TMP_ROOT/pi-logical-run-guard.log"
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  ext=$(install_pi_turnend_extension "$repo/.pi/extensions")
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
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/state"
  ext=$(install_pi_turnend_extension "$repo/.pi/extensions")
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
test_predicate_ambient_test_mode_requires_test_owned_home
test_hook_silent_when_no_work_in_flight
test_hook_blocks_on_unattended_finished_work
test_hook_reads_live_state_not_the_duty_cache
test_hook_silent_when_lane_is_clear
test_hook_genuine_terminal_dispositions_discharge
test_hook_paper_dispositions_do_not_discharge
test_hook_verified_captain_transfer_discharges_without_hiding_the_decision
test_hook_no_progress_permit_queues_a_durable_wake
test_metrics_report_counts_outcomes
test_hook_blocks_on_both_reasons_at_once
test_hook_guard_error_fails_open_loudly
test_hook_source_failure_is_absorbed_by_retry
test_hook_persistent_source_failure_reports_with_caller_identity
test_hook_guard_error_bug_is_coalesced_fleet_wide
test_hook_guard_error_bug_refiles_after_window
test_hook_linked_worktree_excluded_when_git_is_broken
test_hook_exclusion_survives_production_fm_root_override
test_hook_separate_git_dir_primary_is_guarded
test_hook_guard_error_stale_lock_is_reclaimed
test_hook_coalesced_occurrence_still_surfaces
test_hook_guard_error_failed_filing_stays_eligible
test_hook_malformed_ledger_rows_do_not_hide_work
test_hook_afk_stands_down_without_losing_work
test_hook_duty_kill_switch_is_loud_and_logged
test_hook_unchanged_second_stop_is_a_stand_down_not_a_permit
test_hook_second_stop_after_real_progress_is_allowed_after_valid_progress
test_hook_blocks_when_fresh_beacon_has_no_live_lock
test_hook_blocks_when_dead_lock_has_fresh_beacon
test_hook_silent_with_live_lock_and_fresh_beacon
test_hook_blocks_with_live_lock_and_stale_beacon
test_hook_codex_accepts_valid_checkpoint_schedule
test_hook_codex_rejects_no_watcher_and_no_schedule
test_hook_codex_rejects_overdue_checkpoint_schedule
test_hook_codex_rejects_malformed_checkpoint_schedule
test_hook_codex_rejects_owner_mismatch_schedule
test_hook_codex_rejects_duplicate_checkpoint_schedules
test_hook_codex_rejects_disabled_scheduler
test_hook_codex_rejects_bad_generation_and_excessive_lateness
test_hook_codex_production_identity_override_cannot_make_wrong_owner_healthy
test_hook_codex_forged_state_files_cannot_own_schedule
test_hook_codex_production_ambient_fake_dir_cannot_fake_health
test_hook_codex_ambient_test_mode_outside_test_owned_home_is_never_green
test_hook_codex_schedule_bound_to_live_primary
test_hook_codex_failed_checkpoint_is_not_green
test_hook_codex_normal_bounded_exit_is_not_a_crash
test_hook_codex_rejects_schedule_without_scheduler_registration
test_hook_codex_unattended_gate_still_blocks_with_healthy_schedule
test_hook_blocks_when_unhealthy_in_primary
test_hook_blocks_from_fm_home_state
test_hook_x_mode_reason_sources_cadence
test_hook_ignores_repo_state_when_fm_home_set
test_hook_uses_state_override
test_hook_loop_guard_allows_retry
test_hook_blocks_in_secondmate_own_home
test_hook_silent_in_idle_secondmate_home
test_hook_secondmate_loop_guard_allows_retry
test_hook_secondmate_reinvoke_recovery_loop
test_hook_silent_in_secondmate_child_worktree
test_hook_blocks_in_treehouse_leased_secondmate_home
test_hook_exempts_linked_worktree_with_stray_marker
test_hook_exempts_linked_worktree_with_non_ascii_marker
test_hook_silent_in_crewmate_worktree
test_hook_blocks_on_unattended_work_in_a_nongit_primary_home
test_hook_permits_and_logs_in_a_clear_nongit_primary_home
test_hook_inert_when_another_live_session_owns_the_lock
test_hook_blocks_when_the_session_lock_is_stale
test_hook_blocks_when_this_session_owns_the_lock
test_hook_silent_in_crewmate_worktree_with_unattended_work
test_hook_blocks_in_secondmate_home_with_unattended_work
test_hook_missing_jq_is_a_loud_guard_error
test_hook_silent_without_stdin
test_hook_runs_fast
test_hook_logs_the_observations_behind_a_block
test_hook_logs_an_absent_lock_distinctly_from_a_mismatched_one
test_hook_logs_an_allowed_healthy_evaluation
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
