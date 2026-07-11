#!/usr/bin/env bash
# Behavior tests for the read-only fleet-triage enumerator and its ledger writer.
#
# The load-bearing property under test is that an item is handled only when it carries a
# terminal outcome WITH lineage. Printing, seeing, or acknowledging an item must never
# retire it, and a recorded disposition must come back when the self-audit finds it no
# longer holds.
set -u

# shellcheck disable=SC1091 # Dynamic test-library path is resolved from BASH_SOURCE.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153 # ROOT is provided by tests/lib.sh.
TRIAGE="$ROOT/bin/fm-fleet-triage.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-triage)

new_world() {
  local name=$1 world root home
  world="$TMP_ROOT/$name"
  root="$world/root"
  home="$world/home"
  mkdir -p "$root/bin" "$home/state" "$home/data"
  cp "$TRIAGE" "$ROOT/bin/fm-fleet-triage-lib.sh" "$ROOT/bin/fm-fleet-triage-record.sh" "$root/bin/"
  chmod +x "$root/bin/fm-fleet-triage.sh" "$root/bin/fm-fleet-triage-record.sh"
  printf '%s|%s\n' "$root" "$home"
}

# The writer only acts for the session that owns the per-home lock. A test owns it by
# publishing its own pid, which is in the ancestry of every command it runs.
own_lock() {  # <home>
  printf '%s\n' "$$" > "$1/state/.lock"
}

write_snapshot_stub() {
  local root=$1
  cat > "$root/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_SNAPSHOT"
SH
  chmod +x "$root/bin/fm-fleet-snapshot.sh"
}

write_nf_stub() {
  local root=$1
  cat > "$root/bin/fm-nf-reconcile.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_NF_LOG"
cat <<'EOF'
NEEDS FIRSTMATE: 1 unhandled

ready-a1
  signal: done: ready in branch fm/ready-a1
  verb: done
  fingerprint: nf-source-fingerprint
  kind: ship
EOF
SH
  chmod +x "$root/bin/fm-nf-reconcile.sh"
}

write_bug_stub() {
  local root=$1
  cat > "$root/bin/bug-cli" <<'SH'
#!/usr/bin/env bash
cat <<'EOF'
[
  {"id":"bug-open-b1","title":"Open bug","status":"open"},
  {"id":"bug-fixed-b2","title":"Resolved bug","status":"resolved"}
]
EOF
SH
  chmod +x "$root/bin/bug-cli"
}

snapshot_fixture() {
  cat <<'EOF'
{
  "schema":"fm-fleet-snapshot.v1",
  "backlog":{"records":[
    {"order":1,"state":"queued","structured":true,"id":"ready-q1","title":"Ready queued work","blocked_by":null},
    {"order":2,"state":"done","structured":true,"id":"blocker-d1","title":"Completed blocker","blocked_by":null},
    {"order":3,"state":"queued","structured":true,"id":"unblocked-q2","title":"Now unblocked","blocked_by":"blocker-d1"},
    {"order":4,"state":"queued","structured":true,"id":"visibility-never-drop-s5","title":"Keep fleet history visible","blocked_by":null},
    {"order":5,"state":"queued","structured":false,"id":null,"raw":"legacy free-form item"},
    {"order":6,"state":"done","structured":true,"id":"processed-s2","title":"Processed report","blocked_by":null}
  ]},
  "tasks":[
    {"id":"active-orphan-t1","kind":"ship","current_state":{"state":"working"},"paths":{"meta":{"path":"/home/state/active-orphan-t1.meta"}}},
    {"id":"domain-sm","kind":"secondmate","current_state":{"state":"idle"},"paths":{"meta":{"path":"/home/state/domain-sm.meta"}}}
  ],
  "scout_reports":[
    {"id":"orphan-s1","path":"/home/data/orphan-s1/report.md","kind":"scout"},
    {"id":"processed-s2","path":"/home/data/processed-s2/report.md","kind":"scout"},
    {"id":"archived-s3","path":"/home/data/archived-s3/report.md","kind":"scout"}
  ]
}
EOF
}

# One queued backlog item, ready-q1, enumerated in the backlog_hygiene lane.
#
# The caller varies exactly one thing at a time, which is the distinction the fingerprint
# has to draw:
#   one_item_snapshot "<title>"          prose only; the item's structured evidence is
#                                        unchanged, so its evidence version must not move
#   one_item_snapshot "<title>" blocked  structured evidence moves: ready-q1 gains a
#                                        completed blocker, so its status flips from
#                                        `ready` to `blocker_done`
#
# The blocker is deliberately DONE. A blocker that is merely queued would drop ready-q1
# out of the enumeration altogether, which would compare a real item against an absent
# one rather than against a changed one.
one_item_snapshot() {  # [title] [blocked]
  local title=${1:-Ready work} blocked=${2:-}
  if [ -n "$blocked" ]; then
    cat <<EOF
{"backlog":{"records":[
  {"order":1,"state":"queued","structured":true,"id":"ready-q1","title":"$title","blocked_by":"blocker-d1"},
  {"order":2,"state":"done","structured":true,"id":"blocker-d1","title":"Completed blocker","blocked_by":null}
]},"scout_reports":[],"tasks":[]}
EOF
  else
    cat <<EOF
{"backlog":{"records":[
  {"order":1,"state":"queued","structured":true,"id":"ready-q1","title":"$title","blocked_by":null}
]},"scout_reports":[],"tasks":[]}
EOF
  fi
}

run_triage() {
  local root=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_FLEET_TRIAGE_BUG_CLI="${FM_FLEET_TRIAGE_BUG_CLI:-off}" \
    "$root/bin/fm-fleet-triage.sh" "$@"
}

run_record() {
  local root=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_FLEET_TRIAGE_BUG_CLI="${FM_FLEET_TRIAGE_BUG_CLI:-off}" \
    "$root/bin/fm-fleet-triage-record.sh" "$@"
}

ledger_of() {  # <home>
  printf '%s/data/fleet-triage.jsonl' "$1"
}

test_json_covers_all_lanes_and_reuses_nf() {
  local pair root home out nf_log
  pair=$(new_world lanes)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  write_nf_stub "$root"
  write_bug_stub "$root"
  nf_log="$home/nf.log"
  printf '%s\n' '- [x] archived-s3 - Archived scout report (reported 2026-07-01)' > "$home/data/done-archive.md"

  out=$(FM_TEST_SNAPSHOT="$(snapshot_fixture)" FM_TEST_NF_LOG="$nf_log" \
    FM_FLEET_TRIAGE_BUG_CLI="$root/bin/bug-cli" run_triage "$root" "$home" --json)

  [ "$(printf '%s' "$out" | jq -r '.schema')" = 'fm-fleet-triage/v2' ] \
    || fail "JSON should expose the stable triage schema"
  [ "$(printf '%s' "$out" | jq -r '.read_only')" = true ] \
    || fail "JSON should declare the read-only contract"
  [ "$(printf '%s' "$out" | jq -r '.lanes.needs_firstmate.items[0].source_id')" = ready-a1 ] \
    || fail "Needs FirstMate lane should contain reconciler output"
  [ "$(cat "$nf_log")" = list ] || fail "triage should call fm-nf-reconcile.sh list"
  [ "$(printf '%s' "$out" | jq -r '.lanes.bugs.items | length')" -eq 1 ] \
    || fail "bugs lane should include only open bugs"
  [ "$(printf '%s' "$out" | jq -r '.lanes.scout_reports.items[0].source_id')" = orphan-s1 ] \
    || fail "scout lane should include reports without backlog reconciliation"
  [ "$(printf '%s' "$out" | jq -r '.lanes.scout_reports.items | length')" -eq 1 ] \
    || fail "scout lane should exclude reports recorded in the Done archive"
  [ "$(printf '%s' "$out" | jq -r '.lanes.backlog_hygiene.items | map(.status) | unique | sort | join(",")')" = 'blocker_done,ready,unstructured' ] \
    || fail "backlog lane should cover ready, unblocked, and unstructured rows"
  [ "$(printf '%s' "$out" | jq -r '.lanes.visibility_history.items | map(.source_id) | sort | join(",")')" = 'active-orphan-t1,visibility-never-drop-s5' ] \
    || fail "visibility lane should retain the umbrella and flag active tasks missing from backlog"

  # Action class is deterministic and deliberately conservative: only the mechanically
  # proven done-blocker row may ever be auto-coordinated.
  [ "$(printf '%s' "$out" | jq -r '[.items[] | select(.action_class == "AUTO_COORDINATION") | .source_id] | join(",")')" = unblocked-q2 ] \
    || fail "only a done-blocker row should be classified AUTO_COORDINATION"
  [ "$(printf '%s' "$out" | jq -r '[.items[] | select(.action_class == "CAPTAIN_GATE") | .lane] | unique | join(",")')" = visibility_history ] \
    || fail "only the visibility lane should be captain-gated"
  pass "JSON covers every triage lane and composes the NF reconciler"
}

test_evidence_version_ignores_prose_edits() {
  local pair root home reworded out ev1 ev2 ev3 id1 id2
  pair=$(new_world fingerprint)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  reworded='Ready work, but reworded entirely for clarity'

  ev1=$(FM_TEST_SNAPSHOT="$(one_item_snapshot 'Ready work')" \
    run_triage "$root" "$home" --json | jq -r '.items[0].evidence_version')
  id1=$(FM_TEST_SNAPSHOT="$(one_item_snapshot 'Ready work')" \
    run_triage "$root" "$home" --json | jq -r '.items[0].item_id')
  ev2=$(FM_TEST_SNAPSHOT="$(one_item_snapshot "$reworded")" \
    run_triage "$root" "$home" --json | jq -r '.items[0].evidence_version')
  id2=$(FM_TEST_SNAPSHOT="$(one_item_snapshot "$reworded")" \
    run_triage "$root" "$home" --json | jq -r '.items[0].item_id')

  [ "$ev1" = "$ev2" ] || fail "a prose-only edit must not change the evidence version"
  [ "$id1" = "$id2" ] || fail "a prose-only edit must not mint a new logical item"

  # Structured evidence moving IS a real change. Assert the item is still the SAME
  # enumerated item, so this compares a changed item rather than a vanished one.
  out=$(FM_TEST_SNAPSHOT="$(one_item_snapshot 'Ready work' blocked)" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items | length')" -eq 1 ] \
    || fail "the structured-change fixture must still enumerate exactly one item"
  [ "$(printf '%s' "$out" | jq -r '.items[0].item_id')" = "$id1" ] \
    || fail "structured change must keep the same logical identity"
  ev3=$(printf '%s' "$out" | jq -r '.items[0].evidence_version')
  [ "$ev1" != "$ev3" ] || fail "changed structured evidence must change the evidence version"
  pass "evidence version tracks structured fields and ignores prose"
}

test_repeat_scans_do_not_duplicate_or_wake() {
  local pair root home snap first second lines
  pair=$(new_world dedupe)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  first=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  second=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$first" | jq -r '.items | length')" -eq 1 ] \
    || fail "first scan should enumerate one logical item"
  [ "$(printf '%s' "$second" | jq -r '.items | length')" -eq 1 ] \
    || fail "a duplicate scan must not create a second logical item"
  [ "$(printf '%s' "$first" | jq -r '.items[0].item_id')" \
    = "$(printf '%s' "$second" | jq -r '.items[0].item_id')" ] \
    || fail "identity must be stable across scans"

  # Once dispositioned, an unchanged fleet produces no actionable output at all. This is
  # what keeps a no-change cycle from waking firstmate or costing a model call.
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" reject backlog_hygiene:ready-q1 \
    --reason 'not worth doing' >/dev/null
  lines=$(wc -l < "$(ledger_of "$home")" | tr -d ' ')
  FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json >/dev/null
  [ "$(wc -l < "$(ledger_of "$home")" | tr -d ' ')" -eq "$lines" ] \
    || fail "enumeration must never append to the ledger"
  assert_contains "$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --digest)" \
    'FLEET TRIAGE: 0 actionable, 1 total' \
    "an unchanged, dispositioned fleet should raise no actionable wake"
  pass "duplicate scans neither duplicate items nor raise no-change wakes"
}

test_terminal_outcome_requires_lineage() {
  local pair root home snap out
  pair=$(new_world lineage)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  # There is deliberately no acknowledge verb; these are the only ways to finish an item.
  out=$(FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" successor backlog_hygiene:ready-q1 2>&1) \
    && fail "a successor outcome without --link must be refused"
  assert_contains "$out" 'requires --link' "the refusal should name the missing lineage"

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" reject backlog_hygiene:ready-q1 >/dev/null 2>&1 \
    && fail "a rejection without --reason must be refused"

  out=$(FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" hold backlog_hygiene:ready-q1 \
    --reason waiting 2>&1) \
    && fail "a hold without --review-after must be refused"
  assert_contains "$out" 'review-after' "a hold must demand a review date or unblock condition"

  [ ! -f "$(ledger_of "$home")" ] || fail "a refused outcome must not write to the ledger"

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" successor backlog_hygiene:ready-q1 \
    --link built-x1 >/dev/null \
    || fail "a successor WITH lineage should record"
  [ "$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json | jq -r '.items[0].outcome_link')" = built-x1 ] \
    || fail "the recorded lineage should fold back into the item"
  pass "a terminal outcome is refused without its lineage"
}

test_surfacing_does_not_handle_an_item() {
  local pair root home snap out
  pair=$(new_world surfaced)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" surface --all >/dev/null \
    || fail "surface --all should stamp first sight"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].processing_state')" = surfaced ] \
    || fail "a surfaced item should record that it was seen"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "being seen is not an outcome: a surfaced item must stay actionable"
  [ "$(printf '%s' "$out" | jq -r '.metrics.actionable')" -eq 1 ] \
    || fail "a surfaced item must still count as actionable work"
  pass "an item is not handled merely by being surfaced or acknowledged"
}

test_ownerless_and_released_items_stay_visible() {
  local pair root home snap out
  pair=$(new_world owners)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].owner')" = null ] || fail "a fresh item has no owner"
  [ "$(printf '%s' "$out" | jq -r '.metrics.ownerless')" -eq 1 ] \
    || fail "an actionable item without an owner must be counted as ownerless"

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" claim backlog_hygiene:ready-q1 \
    --owner crew-a >/dev/null
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].owner')" = crew-a ] \
    || fail "a claim should record its owner"
  [ "$(printf '%s' "$out" | jq -r '.metrics.ownerless')" -eq 0 ] \
    || fail "a claimed item is owned and no longer ownerless"

  # Releasing a claim must hand the item back, not quietly finish it.
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" release backlog_hygiene:ready-q1 >/dev/null
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].owner')" = null ] || fail "release must clear the owner"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "a released item must return to the actionable queue"
  pass "ownerless items stay visible and released claims come back"
}

# The self-audit cases below seed ledger rows directly. That is deliberate: each one
# simulates a row the writer would never produce (an old claim, a stale hold, a
# hand-appended terminal row), which is exactly the drift the health field exists to catch.
seed_ledger() {  # <home> <json>
  printf '%s\n' "$2" >> "$(ledger_of "$1")"
}

test_self_audit_resurfaces_broken_dispositions() {
  local pair root home snap out ev
  pair=$(new_world selfaudit)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')
  ev=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json | jq -r '.items[0].evidence_version')

  # A hold whose review date has arrived.
  seed_ledger "$home" "{\"item_id\":\"backlog_hygiene:ready-q1\",\"processing_state\":\"held\",\"outcome_type\":\"held\",\"outcome_reason\":\"waiting on upstream\",\"review_after\":\"2020-01-01T00:00:00Z\",\"evidence_version\":\"$ev\"}"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = hold_expired ] \
    || fail "an expired hold should be flagged hold_expired"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "an expired hold must return to the actionable queue"

  # A terminal outcome whose linked successor does not exist.
  : > "$(ledger_of "$home")"
  seed_ledger "$home" "{\"item_id\":\"backlog_hygiene:ready-q1\",\"processing_state\":\"terminal\",\"outcome_type\":\"successor_created\",\"outcome_link\":\"ghost-task-x9\",\"evidence_version\":\"$ev\"}"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = successor_missing ] \
    || fail "a successor link naming no known task should be flagged successor_missing"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "an item whose successor vanished must come back"

  # A terminal row that bypassed the writer and carries no lineage at all.
  : > "$(ledger_of "$home")"
  seed_ledger "$home" "{\"item_id\":\"backlog_hygiene:ready-q1\",\"processing_state\":\"terminal\",\"outcome_type\":\"resolved\",\"evidence_version\":\"$ev\"}"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = dangling_outcome ] \
    || fail "a terminal outcome with no lineage should be flagged dangling_outcome"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "an item cannot be handled by a lineage-free terminal row"

  # A claim that went stale without ever reaching an outcome.
  : > "$(ledger_of "$home")"
  seed_ledger "$home" "{\"item_id\":\"backlog_hygiene:ready-q1\",\"processing_state\":\"claimed\",\"owner\":\"crew-a\",\"claimed_at\":\"2020-01-01T00:00:00Z\",\"evidence_version\":\"$ev\"}"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = claim_abandoned ] \
    || fail "a long-stale claim should be flagged claim_abandoned"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "an abandoned claim must release the item back to the queue"

  # A claim with no owner at all.
  : > "$(ledger_of "$home")"
  seed_ledger "$home" "{\"item_id\":\"backlog_hygiene:ready-q1\",\"processing_state\":\"claimed\",\"evidence_version\":\"$ev\"}"
  [ "$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json | jq -r '.items[0].health')" = owner_missing ] \
    || fail "a claimed item with no owner should be flagged owner_missing"

  # Surfaced long ago and still not dispositioned.
  : > "$(ledger_of "$home")"
  seed_ledger "$home" "{\"item_id\":\"backlog_hygiene:ready-q1\",\"processing_state\":\"surfaced\",\"first_seen_at\":\"2020-01-01T00:00:00Z\",\"evidence_version\":\"$ev\"}"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = stale_unprocessed ] \
    || fail "an item surfaced long ago and never dispositioned should be flagged stale_unprocessed"
  [ "$(printf '%s' "$out" | jq -r '.items[0].age_seconds')" -gt 86400 ] \
    || fail "age should accrue from the durable first-seen stamp"
  pass "the self-audit re-surfaces holds, successors, claims, and stale items"
}

test_changed_evidence_invalidates_a_recorded_outcome() {
  local pair root home out
  pair=$(new_world evidence)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"

  # Decide against the evidence as it stands...
  FM_TEST_SNAPSHOT="$(one_item_snapshot 'Ready work')" \
    run_record "$root" "$home" reject backlog_hygiene:ready-q1 --reason 'not worth doing' >/dev/null
  out=$(FM_TEST_SNAPSHOT="$(one_item_snapshot 'Ready work')" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = false ] \
    || fail "a rejection with a reason should retire the item while its evidence holds"

  # ...then let the underlying evidence move. The old decision no longer applies.
  out=$(FM_TEST_SNAPSHOT="$(one_item_snapshot 'Ready work' blocked)" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = evidence_changed ] \
    || fail "moved evidence should invalidate the recorded classification"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "an item whose evidence changed must be re-evaluated"
  pass "changed evidence invalidates an old processing assumption"
}

test_only_the_lock_owner_may_mutate_processing_state() {
  local pair root home snap out
  pair=$(new_world lock)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')

  out=$(FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" reject backlog_hygiene:ready-q1 \
    --reason x 2>&1) \
    && fail "a session holding no lock must not record outcomes"
  assert_contains "$out" 'does not own the fleet session lock' "the refusal should name the lock"

  # A live lock held by another session. Pid 1 is never in our ancestry.
  printf '1\n' > "$home/state/.lock"
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" reject backlog_hygiene:ready-q1 \
    --reason x >/dev/null 2>&1 \
    && fail "a session that does not own the lock must not record outcomes"
  [ ! -f "$(ledger_of "$home")" ] || fail "a refused write must leave no ledger"

  own_lock "$home"
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" reject backlog_hygiene:ready-q1 \
    --reason x >/dev/null \
    || fail "the lock owner should be able to record an outcome"
  pass "only the lock owner may claim or record outcomes"
}

test_enumerate_only_mode_blocks_every_domain_action() {
  local pair root home snap out
  pair=$(new_world killswitch)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  out=$(FM_TEST_SNAPSHOT="$snap" FLEET_TRIAGE_MODE=enumerate_only \
    run_record "$root" "$home" reject backlog_hygiene:ready-q1 --reason x 2>&1) \
    && fail "enumerate_only must refuse ledger writes even for the lock owner"
  assert_contains "$out" 'enumerate_only' "the refusal should name the kill switch"
  [ ! -f "$(ledger_of "$home")" ] || fail "enumerate_only must not write the ledger"

  # Enumeration itself still works, and reports which mode it is in.
  out=$(FM_TEST_SNAPSHOT="$snap" FLEET_TRIAGE_MODE=enumerate_only run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.mode')" = enumerate_only ] \
    || fail "the enumerator should report the active triage mode"
  [ "$(printf '%s' "$out" | jq -r '.items | length')" -eq 1 ] \
    || fail "enumerate_only still inspects and classifies"
  pass "enumerate-only mode classifies but applies nothing"
}

test_digest_reports_metrics_and_caps_detail() {
  local pair root home out snapshot
  pair=$(new_world digest)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  snapshot='{"backlog":{"records":[
    {"order":1,"state":"queued","structured":true,"id":"one","title":"One","blocked_by":null},
    {"order":2,"state":"queued","structured":true,"id":"two","title":"Two","blocked_by":null},
    {"order":3,"state":"queued","structured":true,"id":"three","title":"Three","blocked_by":null}
  ]},"scout_reports":[],"tasks":[]}'
  out=$(FM_TEST_SNAPSHOT="$snapshot" FM_FLEET_TRIAGE_DIGEST_MAX_ITEMS=2 \
    run_triage "$root" "$home" --digest)

  assert_contains "$out" 'FLEET TRIAGE: 3 actionable, 3 total (mode: active)' \
    "digest header should carry actionable and total counts and the mode"
  assert_contains "$out" 'ownerless: 3' "digest header should carry the ownerless count"
  assert_contains "$out" 'captain-gated: 0' "digest header should carry the captain-gated count"
  assert_contains "$out" 'needs firstmate: 0 (unavailable:' \
    "digest should expose the missing NF dependency"
  assert_contains "$out" 'bugs: 0 (unavailable:' "digest should expose unconfigured bug input"
  assert_contains "$out" 'backlog hygiene: 3 (oldest ' \
    "digest should carry per-lane counts and oldest age"
  assert_contains "$out" 'and 1 more' "digest should report capped remainder"
  [ "$(printf '%s\n' "$out" | grep -c '^  - \[')" -eq 2 ] \
    || fail "digest should print only the configured number of candidate lines"
  pass "digest reports lane counts, oldest age, and stays capped"
}

test_enumerator_does_not_mutate_operational_inputs() {
  local pair root home before after
  pair=$(new_world readonly)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  printf 'sentinel backlog\n' > "$home/data/backlog.md"
  printf 'sentinel state\n' > "$home/state/task.status"
  before=$(cksum "$home/data/backlog.md" "$home/state/task.status")
  FM_TEST_SNAPSHOT='{"backlog":{"records":[]},"scout_reports":[],"tasks":[]}' \
    run_triage "$root" "$home" --json >/dev/null
  after=$(cksum "$home/data/backlog.md" "$home/state/task.status")
  [ "$before" = "$after" ] || fail "triage must not mutate backlog or state inputs"
  [ ! -e "$(ledger_of "$home")" ] || fail "enumeration must not create its processing ledger"
  pass "enumerator leaves operational inputs and ledger untouched"
}

test_json_covers_all_lanes_and_reuses_nf
test_evidence_version_ignores_prose_edits
test_repeat_scans_do_not_duplicate_or_wake
test_terminal_outcome_requires_lineage
test_surfacing_does_not_handle_an_item
test_ownerless_and_released_items_stay_visible
test_self_audit_resurfaces_broken_dispositions
test_changed_evidence_invalidates_a_recorded_outcome
test_only_the_lock_owner_may_mutate_processing_state
test_enumerate_only_mode_blocks_every_domain_action
test_digest_reports_metrics_and_caps_detail
test_enumerator_does_not_mutate_operational_inputs
