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
  cp "$TRIAGE" "$ROOT/bin/fm-fleet-triage-lib.sh" "$ROOT/bin/fm-supervision-lib.sh" \
    "$ROOT/bin/fm-fleet-triage-record.sh" "$root/bin/"
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

write_counting_snapshot_stub() {
  local root=$1
  cat > "$root/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf 'scan\n' >> "$FM_HOME/full-scan.log"
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

# The visibility lane is joined by an explicit (triage: ...) marker on the backlog row, so
# the fixture carries the row's raw text: that marker is the only thing that puts a row in
# the lane, and it is what the classifier reads.
#
# hist-datetime-d3 is the load-bearing negative. It is an ordinary engineering defect whose
# TITLE merely contains the word "history". The retired title-substring selector pulled
# exactly this row into the visibility lane and escalated it to the captain.
snapshot_fixture() {
  cat <<'EOF'
{
  "schema":"fm-fleet-snapshot.v1",
  "backlog":{"records":[
    {"order":1,"state":"queued","structured":true,"id":"ready-q1","title":"Ready queued work","blocked_by":null,"raw":"- [ ] ready-q1 - Ready queued work"},
    {"order":2,"state":"done","structured":true,"id":"blocker-d1","title":"Completed blocker","blocked_by":null,"raw":"- [x] blocker-d1 - Completed blocker"},
    {"order":3,"state":"queued","structured":true,"id":"unblocked-q2","title":"Now unblocked","blocked_by":"blocker-d1","raw":"- [ ] unblocked-q2 - Now unblocked blocked-by: blocker-d1"},
    {"order":4,"state":"queued","structured":true,"id":"visibility-umbrella-u1","title":"Standing order: no dropped tasks","blocked_by":null,"raw":"- [ ] visibility-umbrella-u1 - Standing order: no dropped tasks (repo: firstmate, triage: visibility-umbrella)"},
    {"order":5,"state":"queued","structured":false,"id":null,"raw":"legacy free-form item"},
    {"order":6,"state":"done","structured":true,"id":"processed-s2","title":"Processed report","blocked_by":null,"raw":"- [x] processed-s2 - Processed report"},
    {"order":7,"state":"queued","structured":true,"id":"hist-datetime-d3","title":"Fix Crew Task History datetime column","blocked_by":null,"raw":"- [ ] hist-datetime-d3 - Fix Crew Task History datetime column (repo: bridge)"},
    {"order":8,"state":"queued","structured":true,"id":"vis-gap-v2","title":"Reconcile a dropped row","blocked_by":null,"raw":"- [ ] vis-gap-v2 - Reconcile a dropped row (repo: firstmate, triage: visibility)"}
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
    FM_VISIBILITY_CLI="${FM_VISIBILITY_CLI:-$root/bin/visibility-unavailable.mjs}" \
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
  [ "$(printf '%s' "$out" | jq -r '.lanes.visibility_history.items | map(.source_id) | sort | join(",")')" = 'active-orphan-t1,vis-gap-v2,visibility-umbrella-u1' ] \
    || fail "visibility lane should hold marked rows and active tasks missing from backlog"

  # Action class is deterministic and deliberately conservative. AUTO_COORDINATION is only
  # for a mechanically known correction: a proven-done blocker, or an active task simply
  # missing its backlog row.
  [ "$(printf '%s' "$out" | jq -r '[.items[] | select(.action_class == "AUTO_COORDINATION") | .source_id] | sort | join(",")')" = 'active-orphan-t1,unblocked-q2' ] \
    || fail "a done-blocker row and a task missing from the backlog should be AUTO_COORDINATION"
  [ "$(printf '%s' "$out" | jq -r '[.items[] | select(.action_class == "CAPTAIN_GATE") | .source_id] | join(",")')" = visibility-umbrella-u1 ] \
    || fail "only the declared product-semantics umbrella should be captain-gated"
  pass "JSON covers every triage lane and composes the NF reconciler"
}

# --- Gap 4: the visibility lane is classified by verb, not by lane or by title keyword. --
test_mechanical_visibility_items_are_not_captain_gated() {
  local pair root home out
  pair=$(new_world visibility)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  write_bug_stub "$root"
  out=$(FM_TEST_SNAPSHOT="$(snapshot_fixture)" FM_TEST_NF_LOG="$home/nf.log" \
    run_triage "$root" "$home" --json)

  # An active task missing from the backlog is a mechanically known correction: the task
  # exists, its id is known, and the row simply has to be restored. That is coordination,
  # not a product decision.
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.source_id == "active-orphan-t1") | .action_class')" = AUTO_COORDINATION ] \
    || fail "a task missing from the backlog must be AUTO_COORDINATION, not CAPTAIN_GATE"
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.source_id == "active-orphan-t1") | .proposed_action.verb')" = restore_active_visibility ] \
    || fail "the mechanical visibility item should keep its distinguishing verb"

  # A marked engineering visibility gap needs a human read, but it is not the captain's.
  # Selected by item_id: a marked backlog row is also an ordinary queued row, so it appears
  # in the backlog_hygiene lane too, and only its visibility-lane item is under test here.
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "visibility_history:vis-gap-v2") | .action_class')" = FIRSTMATE_JUDGMENT ] \
    || fail "an engineering visibility gap belongs to firstmate, not the captain"
  pass "mechanical visibility work is coordinated, not escalated to the captain"
}

test_history_in_a_title_does_not_captain_gate_a_row() {
  local pair root home out
  pair=$(new_world histtitle)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  write_bug_stub "$root"
  out=$(FM_TEST_SNAPSHOT="$(snapshot_fixture)" FM_TEST_NF_LOG="$home/nf.log" \
    run_triage "$root" "$home" --json)

  # hist-datetime-d3 is an ordinary datetime bug. The retired selector matched the word
  # "history" in its title, pulled it into the visibility lane, and escalated it.
  [ "$(printf '%s' "$out" | jq -r '[.items[] | select(.source_id == "hist-datetime-d3") | .lane] | join(",")')" = backlog_hygiene ] \
    || fail "a title containing 'history' must not pull a row into the visibility lane"
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.source_id == "hist-datetime-d3") | .action_class')" != CAPTAIN_GATE ] \
    || fail "an engineering row must never be captain-gated for a keyword in its title"

  # Lane membership is declared, so no captain personal backlog id is baked into the tool.
  grep -q 'visibility-never-drop' "$root/bin/fm-fleet-triage.sh" \
    && fail "a specific captain's backlog id must not ship in the shared enumerator"
  pass "a keyword in a title neither joins the visibility lane nor reaches the captain"
}

test_product_semantics_item_still_captain_gates() {
  local pair root home out
  pair=$(new_world umbrella)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  write_bug_stub "$root"
  out=$(FM_TEST_SNAPSHOT="$(snapshot_fixture)" FM_TEST_NF_LOG="$home/nf.log" \
    run_triage "$root" "$home" --json)

  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "visibility_history:visibility-umbrella-u1") | .action_class')" = CAPTAIN_GATE ] \
    || fail "the declared product-semantics umbrella must still reach the captain"
  [ "$(printf '%s' "$out" | jq -r '.metrics.captain_gated')" -eq 1 ] \
    || fail "exactly the umbrella item should be counted as captain-gated"
  pass "genuine product-semantics work still gates on the captain"
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

  # Both properties are asserted in one test on purpose. Widening evidence coverage and
  # keeping prose out of the hash pull against each other: a fix for either one alone can
  # silently break the other, turning the queue either blind or churning.
  [ "$ev1" = "$ev2" ] || fail "widening evidence coverage must not start churning on prose"
  pass "evidence version tracks structured fields and ignores prose"
}

# --- Gap 2: the bugs and scout lanes were materially blind. ---------------------------
# The bug CLI emits id, kind, links, note, schema, sourceText, status, title, ts, type.
# The lane hashed `status` alone, so a bug could gain a task link, a resolution note, or a
# reclassified type without ever invalidating a disposition decided before that move.
write_var_bug_stub() {
  local root=$1
  cat > "$root/bin/bug-var-cli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_BUG_JSON"
SH
  chmod +x "$root/bin/bug-var-cli"
}

bug_evidence_version() {  # <root> <home> <bug-json>
  local root=$1 home=$2 bug=$3
  FM_TEST_SNAPSHOT='{"backlog":{"records":[]},"scout_reports":[],"tasks":[]}' \
    FM_TEST_BUG_JSON="$bug" FM_FLEET_TRIAGE_BUG_CLI="$root/bin/bug-var-cli" \
    run_triage "$root" "$home" --json | jq -r '.items[0].evidence_version'
}

test_evidence_version_tracks_material_bug_drift() {
  local pair root home base ev0 ev_link ev_note ev_type ev_prose
  pair=$(new_world bugdrift)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  write_var_bug_stub "$root"

  base='[{"id":"bug-b1","title":"Ask is broken","sourceText":"Ask is broken","status":"open","type":"bug","links":{},"note":""}]'
  ev0=$(bug_evidence_version "$root" "$home" "$base")

  # Each of these is a material move: the bug now has a task on it, a resolution note, or a
  # different classification. A rejection decided before any of them no longer holds.
  ev_link=$(bug_evidence_version "$root" "$home" \
    '[{"id":"bug-b1","title":"Ask is broken","sourceText":"Ask is broken","status":"open","type":"bug","links":{"taskId":"fix-ask-a1"},"note":""}]')
  ev_note=$(bug_evidence_version "$root" "$home" \
    '[{"id":"bug-b1","title":"Ask is broken","sourceText":"Ask is broken","status":"open","type":"bug","links":{},"note":"repro found: scoping prompt"}]')
  ev_type=$(bug_evidence_version "$root" "$home" \
    '[{"id":"bug-b1","title":"Ask is broken","sourceText":"Ask is broken","status":"open","type":"improvement","links":{},"note":""}]')

  [ "$ev0" != "$ev_link" ] || fail "a bug gaining a task link must move its evidence version"
  [ "$ev0" != "$ev_note" ] || fail "a bug gaining a resolution note must move its evidence version"
  [ "$ev0" != "$ev_type" ] || fail "a reclassified bug type must move its evidence version"

  # ...and the prose rule still holds on this lane too: the title and repro text are not
  # structured evidence, so rewording them must not mint a new logical item.
  ev_prose=$(bug_evidence_version "$root" "$home" \
    '[{"id":"bug-b1","title":"The Ask feature does not work","sourceText":"Completely different wording of the same report","status":"open","type":"bug","links":{},"note":""}]')
  [ "$ev0" = "$ev_prose" ] || fail "rewording a bug must not move its evidence version"
  pass "material bug drift moves the evidence version and prose does not"
}

test_evidence_version_tracks_rewritten_scout_report() {
  local pair root home snap ev1 ev2 out
  pair=$(new_world reportdrift)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  mkdir -p "$home/data/orphan-s1"
  snap="{\"backlog\":{\"records\":[]},\"tasks\":[],\"scout_reports\":[{\"id\":\"orphan-s1\",\"path\":\"$home/data/orphan-s1/report.md\",\"kind\":\"scout\"}]}"

  printf 'Finding: the cache is cold on boot.\n' > "$home/data/orphan-s1/report.md"
  ev1=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json | jq -r '.items[0].evidence_version')

  # Same report path, entirely different findings. The report IS the deliverable, so a
  # disposition decided against the old body cannot survive the rewrite.
  printf 'Finding: the cache is fine; the clock is wrong.\n' > "$home/data/orphan-s1/report.md"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  ev2=$(printf '%s' "$out" | jq -r '.items[0].evidence_version')

  [ "$(printf '%s' "$out" | jq -r '.items[0].item_id')" = 'scout_reports:orphan-s1' ] \
    || fail "a rewritten report must stay the same logical item"
  [ "$ev1" != "$ev2" ] || fail "a report rewritten with different findings must move its evidence version"
  pass "a rewritten scout report invalidates a disposition made against the old one"
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

# --- Gap 3: a skipped ledger row must leave a trace. -----------------------------------
# The fold survives a malformed row, which is right. Surviving it silently is not: the two
# directions are asymmetric. A malformed TERMINAL row fails safe (the item reverts to
# actionable, costing rework). A malformed SURFACE row fails DANGEROUS - first_seen_at is
# gone, so age() is null, stale_unprocessed can never fire, and the item can sit forever
# with the self-audit structurally unable to see it.
test_malformed_ledger_row_does_not_break_the_fold() {
  local pair root home snap out
  pair=$(new_world malformedfold)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')
  own_lock "$home"

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" resolve backlog_hygiene:ready-q1 \
    --link sha-abc >/dev/null
  printf '%s\n' 'this row is not json at all' >> "$(ledger_of "$home")"

  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "backlog_hygiene:ready-q1") | .processing_state')" = terminal ] \
    || fail "a malformed row must not cost the fold the good rows around it"
  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "backlog_hygiene:ready-q1") | .outcome_link')" = sha-abc ] \
    || fail "the surviving rows must keep their recorded lineage"
  pass "a malformed ledger row does not break the fold"
}

test_malformed_ledger_row_is_visible_and_repairable() {
  local pair root home snap out digest
  pair=$(new_world malformedvisible)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')
  own_lock "$home"

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" surface backlog_hygiene:ready-q1 >/dev/null
  printf '%s\n' '{"item_id":"backlog_hygiene:ready-q1","processing_state":' \
    >> "$(ledger_of "$home")"

  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.metrics.ledger_health.malformed_rows')" -eq 1 ] \
    || fail "a malformed row must be counted in metrics.ledger_health"
  [ "$(printf '%s' "$out" | jq -r '.metrics.ledger_health.rows[0].line')" -eq 2 ] \
    || fail "a malformed row must be reported with the line that holds it"
  [ "$(printf '%s' "$out" | jq -r '.lanes.ledger_health.items[0].item_id')" = 'ledger_health:fleet-triage.jsonl' ] \
    || fail "a malformed ledger must surface a stable ledger-health item"

  digest=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --digest)
  assert_contains "$digest" 'ledger health: 1 malformed of' \
    "the digest should name the corruption it found"
  assert_contains "$digest" 'first at line 2' "the digest should point at the bad row"
  pass "a malformed ledger row is counted, located, and named in the digest"
}

test_malformed_rows_surface_one_stable_item() {
  local pair root home snap first second
  pair=$(new_world malformedstable)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')

  # Many bad rows, and one of them is bad in the other way the fold skips: valid JSON with
  # no item_id.
  printf '%s\n' 'garbage one' 'garbage two' '{"processing_state":"surfaced"}' \
    >> "$(ledger_of "$home")"

  first=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  second=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)

  [ "$(printf '%s' "$first" | jq -r '.metrics.ledger_health.malformed_rows')" -eq 3 ] \
    || fail "every skipped row should be counted"
  # The anti-recursion property: N bad rows are ONE item, and rescanning never grows a
  # chain of triage-about-triage items.
  [ "$(printf '%s' "$first" | jq -r '[.items[] | select(.lane == "ledger_health")] | length')" -eq 1 ] \
    || fail "3 malformed rows must produce exactly one ledger-health item, never one per row"
  [ "$(printf '%s' "$second" | jq -r '[.items[] | select(.lane == "ledger_health")] | length')" -eq 1 ] \
    || fail "a repeated scan must not add a second ledger-health item"
  [ "$(printf '%s' "$first" | jq -r '[.items[] | select(.lane == "ledger_health") | .item_id] | join(",")')" \
    = "$(printf '%s' "$second" | jq -r '[.items[] | select(.lane == "ledger_health") | .item_id] | join(",")')" ] \
    || fail "the ledger-health item id must be stable across scans"
  pass "N malformed rows surface exactly one stable item across repeated scans"
}

test_malformed_surface_row_is_reported_not_silently_lost() {
  local pair root home snap out
  pair=$(new_world malformedsurface)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')

  # The fail-dangerous direction. This item's ONLY ledger row is a corrupt surface row, so
  # its first_seen_at is gone for good and it can never age into stale_unprocessed. The
  # timestamp is unrecoverable; what must not happen is losing it in silence.
  printf '%s\n' '{"item_id":"backlog_hygiene:ready-q1","processing_state":"surfaced","first_seen_at' \
    >> "$(ledger_of "$home")"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)

  [ "$(printf '%s' "$out" | jq -r '.items[] | select(.item_id == "backlog_hygiene:ready-q1") | .processing_state')" = new ] \
    || fail "an item whose only row is corrupt folds back to new"
  [ "$(printf '%s' "$out" | jq -r '.metrics.ledger_health.malformed_rows')" -eq 1 ] \
    || fail "the lost surface row must be reported, not silently dropped"
  [ "$(printf '%s' "$out" | jq -r '.metrics.ledger_health.rows[0].reason')" = 'unparseable JSON' ] \
    || fail "the report should say why the row could not be read"
  assert_contains "$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --digest)" \
    'ledger health: 1 malformed' "a lost surface stamp must be visible in the digest"
  pass "a malformed surface row is reported rather than silently losing first_seen_at"
}

# --- Gap 5: the folded current state must be coherent. ---------------------------------
# The ledger accumulates, so a field an event does not mention keeps its old value. That
# left an item folding to terminal while still carrying the owner and claimed_at of the
# crew that finished it, and left a re-opened item advertising the outcome it had been
# re-opened FROM - with a phantom owner that hid it from the ownerless metric.
fold_field() {  # <root> <home> <item-id> <field>
  # shellcheck disable=SC1090,SC1091 # Path is the per-test copy of the library under test.
  . "$1/bin/fm-fleet-triage-lib.sh"
  fm_triage_fold "$(ledger_of "$2")" | jq -r --arg id "$3" --arg f "$4" '.[$id][$f] // "null"'
}

test_terminal_outcome_clears_the_claim() {
  local pair root home snap out
  pair=$(new_world terminalclaim)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" surface backlog_hygiene:ready-q1 >/dev/null
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" claim backlog_hygiene:ready-q1 \
    --owner crew-a >/dev/null
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" resolve backlog_hygiene:ready-q1 \
    --link sha-abc >/dev/null

  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].processing_state')" = terminal ] \
    || fail "a resolve should fold to terminal"
  [ "$(printf '%s' "$out" | jq -r '.items[0].owner')" = null ] \
    || fail "an item cannot be terminal AND still actively claimed"
  [ "$(fold_field "$root" "$home" backlog_hygiene:ready-q1 claimed_at)" = null ] \
    || fail "a terminal outcome must clear claimed_at, not just the owner"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = false ] \
    || fail "a resolved item with lineage should still retire"
  pass "a terminal outcome ends the claim it finishes"
}

test_resurfacing_clears_the_stale_disposition() {
  local pair root home snap out
  pair=$(new_world resurface)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" claim backlog_hygiene:ready-q1 \
    --owner crew-a >/dev/null
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" resolve backlog_hygiene:ready-q1 \
    --link sha-abc >/dev/null
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" surface backlog_hygiene:ready-q1 >/dev/null

  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].processing_state')" = surfaced ] \
    || fail "a re-surfaced item should come back as surfaced"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "a re-opened item must be actionable again"
  [ "$(printf '%s' "$out" | jq -r '.items[0].outcome_type')" = null ] \
    || fail "a re-opened item must not still advertise the outcome it was re-opened from"
  [ "$(printf '%s' "$out" | jq -r '.items[0].outcome_link')" = null ] \
    || fail "a re-opened item must not carry a live-looking outcome link"
  [ "$(printf '%s' "$out" | jq -r '.items[0].decided_at')" = null ] \
    || fail "a re-opened item must not carry a stale decision date"

  # The phantom-owner metric bug: the item kept the owner of a crew that finished and left,
  # so it was excluded from `ownerless` and firstmate believed someone was on it.
  [ "$(printf '%s' "$out" | jq -r '.items[0].owner')" = null ] \
    || fail "a re-opened item must not keep the owner of the crew that finished it"
  [ "$(printf '%s' "$out" | jq -r '.metrics.ownerless')" -eq 1 ] \
    || fail "a re-opened item with no live owner must count as ownerless"
  pass "re-surfacing clears the stale disposition and the phantom owner"
}

test_ledger_preserves_prior_decisions_as_history() {
  local pair root home snap ledger
  pair=$(new_world history)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')
  ledger=$(ledger_of "$home")

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" claim backlog_hygiene:ready-q1 \
    --owner crew-a >/dev/null
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" resolve backlog_hygiene:ready-q1 \
    --link sha-abc --reason 'fixed upstream' >/dev/null
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" surface backlog_hygiene:ready-q1 >/dev/null

  # Clearing is about what the fold computes as CURRENT. The log itself is append-only and
  # every prior event stays in it verbatim, which is where the history belongs.
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 3 ] \
    || fail "every event must remain in the append-only ledger"
  [ "$(jq -r 'select(.event == "claim") | .owner' "$ledger")" = crew-a ] \
    || fail "the original claim must survive verbatim in the ledger"
  [ "$(jq -r 'select(.event == "resolve") | .outcome_link' "$ledger")" = sha-abc ] \
    || fail "the prior resolution must survive verbatim in the ledger"
  [ "$(jq -r 'select(.event == "resolve") | .outcome_reason' "$ledger")" = 'fixed upstream' ] \
    || fail "the prior decision's reason must survive verbatim in the ledger"
  pass "clearing the folded state never deletes ledger history"
}

test_surface_all_does_not_reopen_dispositioned_work() {
  local pair root home snap out
  pair=$(new_world surfaceall)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" resolve backlog_hygiene:ready-q1 \
    --link sha-abc >/dev/null

  # A surface re-opens an item and clears the disposition it re-opens, so a blanket --all
  # over every enumerated item would resurrect settled work on every pass. --all stamps
  # first sight of what still needs one; re-opening finished work is a deliberate act.
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" surface --all >/dev/null
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)

  [ "$(printf '%s' "$out" | jq -r '.items[0].processing_state')" = terminal ] \
    || fail "surface --all must not re-open a dispositioned item"
  [ "$(printf '%s' "$out" | jq -r '.items[0].outcome_type')" = resolved ] \
    || fail "surface --all must not clear a healthy disposition"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = false ] \
    || fail "a scheduled surface --all must not resurrect finished work"
  pass "surface --all stamps unfinished work without re-opening finished work"
}

test_hold_expiry_and_successor_disappearance() {
  local pair root home snap out
  pair=$(new_world holdsuccessor)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  # Driven through the writer rather than seeded rows, so the writer's own event shapes are
  # what the self-audit is tested against.
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" hold backlog_hygiene:ready-q1 \
    --reason 'waiting on upstream' --review-after '2020-01-01T00:00:00Z' >/dev/null
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].processing_state')" = held ] \
    || fail "a hold should fold to held"
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = hold_expired ] \
    || fail "a hold whose review date has passed must expire"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "an expired hold must return to the queue"

  : > "$(ledger_of "$home")"
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" successor backlog_hygiene:ready-q1 \
    --link ghost-task-x9 >/dev/null
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = successor_missing ] \
    || fail "a successor that does not exist must re-open the item it was supposed to own"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "work handed to a task that never appeared must come back"
  pass "an expired hold and a vanished successor both return the work"
}

# A hold is the cheapest way to silence an item, so it is the one disposition that MUST be
# able to come due. It could not: the health ladder read review_after with bare
# fromdateiso8601, which accepts only a full instant, and no hold ever written carried one -
# every value was a calendar date or an unblock condition in prose. age() went null,
# hold_expired never fired once across 42 holds, and `hold` was a permanent mute button. On
# 2026-07-13 eight finished-work items were muted with it in 137 seconds.
test_a_calendar_date_review_comes_due() {
  local pair root home snap out yesterday tomorrow
  pair=$(new_world holddate)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')
  yesterday=$(date -u -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
  tomorrow=$(date -u -d '2 days' +%Y-%m-%d 2>/dev/null || date -u -v+2d +%Y-%m-%d)

  # The form every real hold in the ledger actually used: a bare calendar date.
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" hold backlog_hygiene:ready-q1 \
    --reason 'waiting on upstream' --review-after "$yesterday" >/dev/null
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = hold_expired ] \
    || fail "a calendar-date review that has arrived must expire the hold"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "a hold whose review date arrived must be actionable again"

  # ...and a date that has NOT arrived still holds, or the hold would be useless.
  : > "$(ledger_of "$home")"
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" hold backlog_hygiene:ready-q1 \
    --reason 'waiting on upstream' --review-after "$tomorrow" >/dev/null
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = ok ] \
    || fail "a review date still in the future must not expire the hold"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = false ] \
    || fail "a live hold must stay parked"
  pass "a hold with a calendar review date comes due when that date arrives, and not before"
}

# Both doors on the mute button. The writer refuses a review date no clock can read, and the
# ladder fails a legacy row carrying one back into the queue rather than honoring a hold that
# can never expire.
test_an_unreadable_review_date_cannot_park_work() {
  local pair root home snap out ev
  pair=$(new_world holdprose)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  out=$(FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" hold backlog_hygiene:ready-q1 \
    --reason 'waiting on upstream' --review-after 'next bug-triage pass' 2>&1) \
    && fail "the writer accepted a review date that can never come due"
  assert_contains "$out" 'never expires' "the refusal must say why an unreadable date is refused"
  assert_absent "$(ledger_of "$home")" "a refused hold must not reach the ledger"

  # A legacy row that predates the refusal, or a hand-append that bypassed it.
  ev=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json | jq -r '.items[0].evidence_version')
  seed_ledger "$home" "{\"item_id\":\"backlog_hygiene:ready-q1\",\"processing_state\":\"held\",\"outcome_type\":\"held\",\"outcome_reason\":\"waiting\",\"review_after\":\"next bug-triage pass\",\"evidence_version\":\"$ev\"}"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = hold_unreviewable ] \
    || fail "a hold whose review date cannot be read must be flagged, not honored"
  [ "$(printf '%s' "$out" | jq -r '.items[0].actionable')" = true ] \
    || fail "a hold that can never come due must not park work"
  pass "an unreadable review date is refused at the writer and re-opened by the self-audit"
}

# Age was fiction: first_seen_at is persisted only by a surface row, nothing wrote one
# automatically, so every actionable item reported age 0 forever and stale_unprocessed - the
# model's only escalator - was unreachable code. surface --new is what the duty pass runs on
# every pass to make age real, and it must survive later passes to be worth anything.
test_first_seen_at_persists_and_stale_unprocessed_can_fire() {
  local pair root home snap out first second ev
  pair=$(new_world firstseen)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  own_lock "$home"
  snap=$(one_item_snapshot 'Ready work')

  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].processing_state')" = new ] \
    || fail "an item the ledger has never seen should read as new"

  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" surface --new >/dev/null
  first=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json | jq -r '.items[0].first_seen_at')
  [ -n "$first" ] && [ "$first" != null ] || fail "surface --new stamped no first_seen_at"

  # The stamp is what has to survive: a second pass must not reset the clock, or age can
  # never accumulate and the item stays permanently "new".
  FM_TEST_SNAPSHOT="$snap" run_record "$root" "$home" surface --new >/dev/null
  second=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json | jq -r '.items[0].first_seen_at')
  [ "$second" = "$first" ] || fail "a later pass re-stamped first_seen_at ($first -> $second); age would never accumulate"
  [ "$(jq -rc 'select(.event == "surface" and .item_id == "backlog_hygiene:ready-q1")' "$(ledger_of "$home")" | wc -l)" -eq 1 ] \
    || fail "surface --new stamped an already-seen item a second time"

  # With a real first_seen_at, age becomes real - and the escalator can finally fire.
  : > "$(ledger_of "$home")"
  ev=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json | jq -r '.items[0].evidence_version')
  seed_ledger "$home" "{\"item_id\":\"backlog_hygiene:ready-q1\",\"processing_state\":\"surfaced\",\"first_seen_at\":\"2020-01-01T00:00:00Z\",\"evidence_version\":\"$ev\"}"
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.items[0].health')" = stale_unprocessed ] \
    || fail "an item sitting unprocessed far past the stale threshold must be flagged stale_unprocessed"
  [ "$(printf '%s' "$out" | jq -r '.items[0].age_seconds')" -gt 0 ] \
    || fail "age_seconds is still zero despite a persisted first_seen_at"
  pass "first sight is persisted once, survives later passes, and lets stale_unprocessed fire"
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

test_check_skips_unchanged_evidence_inside_cooldown() {
  local pair root home snap first second
  pair=$(new_world checkquiet)
  root=${pair%%|*}
  home=${pair#*|}
  write_counting_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')

  first=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --check)
  second=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --check)
  [[ "$first" == 'FLEET_TRIAGE: check: 1 actionable (+1 new)' ]] \
    || fail "first check should surface its actionable baseline: $first"
  [ -z "$second" ] || fail "unchanged evidence inside cooldown must stay silent"
  [ "$(wc -l < "$home/full-scan.log")" -eq 1 ] \
    || fail "unchanged cheap path invoked the full enumerator"
  pass "watcher check skips the full enumerator while evidence is unchanged"
}

test_check_detects_proxy_change() {
  local pair root home snap out
  pair=$(new_world checkchange)
  root=${pair%%|*}
  home=${pair#*|}
  write_counting_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')
  FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --check >/dev/null
  printf 'changed evidence\n' > "$home/data/backlog.md"
  snap=$(one_item_snapshot 'Ready work' blocked)
  out=$(FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --check)
  [[ "$out" == 'FLEET_TRIAGE: check: 1 actionable (+1 new)' ]] \
    || fail "material evidence change did not surface: $out"
  [ "$(wc -l < "$home/full-scan.log")" -eq 2 ] \
    || fail "proxy change did not trigger a full scan"
  pass "watcher check detects changed local evidence"
}

test_check_cooldown_and_resurface_are_independent() {
  local pair root home snap out
  pair=$(new_world checkresurface)
  root=${pair%%|*}
  home=${pair#*|}
  write_counting_snapshot_stub "$root"
  snap=$(one_item_snapshot 'Ready work')
  FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --check >/dev/null
  out=$(FM_FLEET_TRIAGE_CHECK_INTERVAL=0 FM_FLEET_TRIAGE_RESURFACE_SECS=999999 \
    FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --check)
  [ -z "$out" ] || fail "cooldown scan should stay silent when its actionable set is unchanged"
  out=$(FM_FLEET_TRIAGE_CHECK_INTERVAL=0 FM_FLEET_TRIAGE_RESURFACE_SECS=0 \
    FM_TEST_SNAPSHOT="$snap" run_triage "$root" "$home" --check)
  [[ "$out" == 'FLEET_TRIAGE: check: 1 actionable (+0 new; re-surface)' ]] \
    || fail "deliberate re-surface threshold did not wake: $out"
  [ "$(wc -l < "$home/full-scan.log")" -eq 3 ] \
    || fail "independent cooldown did not force both full scans"
  pass "full-scan cooldown and actionable re-surface thresholds are independent"
}

test_check_surfaces_full_scan_failure() {
  local pair root home out
  pair=$(new_world checkfailure)
  root=${pair%%|*}
  home=${pair#*|}
  cat > "$root/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf 'snapshot unavailable\n' >&2
exit 7
SH
  chmod +x "$root/bin/fm-fleet-snapshot.sh"
  out=$(FM_TEST_SNAPSHOT='' run_triage "$root" "$home" --check)
  [[ "$out" == FLEET_TRIAGE:\ check\ failed:*snapshot\ unavailable* ]] \
    || fail "full-scan failure was invisible to the watcher: $out"
  pass "watcher check converts full-scan failure into a concise wake signal"
}

test_check_installer_is_idempotent_and_executable() {
  local pair root home shim before after
  pair=$(new_world checkinstall)
  root=${pair%%|*}
  home=${pair#*|}
  run_triage "$root" "$home" install
  shim="$home/state/fleet-triage.check.sh"
  [ -x "$shim" ] || fail "installer did not create an executable watcher shim"
  before=$(stat -c '%Y:%s' "$shim")
  sleep 1
  run_triage "$root" "$home" install
  after=$(stat -c '%Y:%s' "$shim")
  [ "$before" = "$after" ] || fail "idempotent reinstall rewrote the unchanged shim"
  grep -q -- '--check' "$shim" || fail "installed shim does not invoke watcher check mode"
  pass "fleet-triage check installer is idempotent and executable"
}

test_visibility_audit_feeds_existing_lane() {
  local pair root home out cli
  pair=$(new_world visibility-audit)
  root=${pair%%|*}; home=${pair#*|}
  write_snapshot_stub "$root"
  cli="$home/visibility.mjs"
  printf '%s\n' '#!/usr/bin/env node' 'console.log(JSON.stringify({ok:false,diagnostics:[{code:"history_missing",fingerprint:"audit-1",message:"terminal task missing from History"}]})); process.exitCode=2;' > "$cli"
  out=$(FM_TEST_SNAPSHOT='{"backlog":{"records":[]},"tasks":[],"scout_reports":[]}' FM_VISIBILITY_CLI="$cli" run_triage "$root" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.lanes.visibility_history.items[0].source_id')" = audit-1 ] || fail "visibility audit finding did not enter visibility_history"
  pass "visibility audit findings feed the existing visibility lane"
}

test_json_covers_all_lanes_and_reuses_nf
test_mechanical_visibility_items_are_not_captain_gated
test_history_in_a_title_does_not_captain_gate_a_row
test_product_semantics_item_still_captain_gates
test_evidence_version_ignores_prose_edits
test_evidence_version_tracks_material_bug_drift
test_evidence_version_tracks_rewritten_scout_report
test_malformed_ledger_row_does_not_break_the_fold
test_malformed_ledger_row_is_visible_and_repairable
test_malformed_rows_surface_one_stable_item
test_malformed_surface_row_is_reported_not_silently_lost
test_terminal_outcome_clears_the_claim
test_resurfacing_clears_the_stale_disposition
test_ledger_preserves_prior_decisions_as_history
test_surface_all_does_not_reopen_dispositioned_work
test_hold_expiry_and_successor_disappearance
test_a_calendar_date_review_comes_due
test_an_unreadable_review_date_cannot_park_work
test_first_seen_at_persists_and_stale_unprocessed_can_fire
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
test_check_skips_unchanged_evidence_inside_cooldown
test_check_detects_proxy_change
test_check_cooldown_and_resurface_are_independent
test_check_surfaces_full_scan_failure
test_check_installer_is_idempotent_and_executable
test_visibility_audit_feeds_existing_lane
