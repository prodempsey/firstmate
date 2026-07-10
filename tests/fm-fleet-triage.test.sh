#!/usr/bin/env bash
# Behavior tests for the read-only fleet-triage enumerator.
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
  cp "$TRIAGE" "$root/bin/fm-fleet-triage.sh"
  chmod +x "$root/bin/fm-fleet-triage.sh"
  printf '%s|%s\n' "$root" "$home"
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

run_triage() {
  local root=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_FLEET_TRIAGE_BUG_CLI="${FM_FLEET_TRIAGE_BUG_CLI:-off}" \
    "$root/bin/fm-fleet-triage.sh" "$@"
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

  [ "$(printf '%s' "$out" | jq -r '.schema')" = 'fm-fleet-triage/v1' ] \
    || fail "JSON should expose the stable triage schema"
  [ "$(printf '%s' "$out" | jq -r '.read_only')" = true ] \
    || fail "JSON should declare the read-only contract"
  [ "$(printf '%s' "$out" | jq -r '.lanes.needs_firstmate.items[0].id')" = ready-a1 ] \
    || fail "Needs FirstMate lane should contain reconciler output"
  [ "$(cat "$nf_log")" = list ] || fail "triage should call fm-nf-reconcile.sh list"
  [ "$(printf '%s' "$out" | jq -r '.lanes.bugs.items | length')" -eq 1 ] \
    || fail "bugs lane should include only open bugs"
  [ "$(printf '%s' "$out" | jq -r '.lanes.scout_reports.items[0].id')" = orphan-s1 ] \
    || fail "scout lane should include reports without backlog reconciliation"
  [ "$(printf '%s' "$out" | jq -r '.lanes.scout_reports.items | length')" -eq 1 ] \
    || fail "scout lane should exclude reports recorded in the Done archive"
  [ "$(printf '%s' "$out" | jq -r '.lanes.backlog_hygiene.items | map(.status) | unique | sort | join(",")')" = 'blocker_done,ready,unstructured' ] \
    || fail "backlog lane should cover ready, unblocked, and unstructured rows"
  [ "$(printf '%s' "$out" | jq -r '.lanes.visibility_history.items | map(.id) | sort | join(",")')" = 'active-orphan-t1,visibility-never-drop-s5' ] \
    || fail "visibility lane should retain the umbrella and flag active tasks missing from backlog"
  pass "JSON covers every triage lane and composes the NF reconciler"
}

test_acknowledged_fingerprint_is_suppressed_from_digest() {
  local pair root home first fingerprint digest
  pair=$(new_world handled)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  first=$(FM_TEST_SNAPSHOT='{"backlog":{"records":[{"order":1,"state":"queued","structured":true,"id":"ready-q1","title":"Ready work","blocked_by":null}]},"scout_reports":[]}' \
    run_triage "$root" "$home" --json)
  fingerprint=$(printf '%s' "$first" | jq -r '.items[0].fingerprint')
  printf 'backlog_hygiene\tready-q1\t%s\n' "$fingerprint" > "$home/state/.fleet-triage-handled"

  digest=$(FM_TEST_SNAPSHOT='{"backlog":{"records":[{"order":1,"state":"queued","structured":true,"id":"ready-q1","title":"Ready work","blocked_by":null}]},"scout_reports":[]}' \
    run_triage "$root" "$home" --digest)
  assert_contains "$digest" 'FLEET TRIAGE: 0 unhandled candidate(s), 1 total' \
    "acknowledged unchanged candidate should not re-alert"
  assert_not_contains "$digest" '[backlog hygiene] ready-q1' \
    "handled candidate should be absent from digest details"
  pass "handled fingerprints suppress unchanged digest alerts"
}

test_digest_is_capped_and_missing_optional_lanes_are_visible() {
  local pair root home out snapshot
  pair=$(new_world capped)
  root=${pair%%|*}
  home=${pair#*|}
  write_snapshot_stub "$root"
  snapshot='{"backlog":{"records":[
    {"order":1,"state":"queued","structured":true,"id":"one","title":"One","blocked_by":null},
    {"order":2,"state":"queued","structured":true,"id":"two","title":"Two","blocked_by":null},
    {"order":3,"state":"queued","structured":true,"id":"three","title":"Three","blocked_by":null}
  ]},"scout_reports":[]}'
  out=$(FM_TEST_SNAPSHOT="$snapshot" FM_FLEET_TRIAGE_DIGEST_MAX_ITEMS=2 \
    run_triage "$root" "$home" --digest)
  assert_contains "$out" 'needs firstmate: 0 (unavailable:' \
    "digest should expose the missing NF dependency"
  assert_contains "$out" 'bugs: 0 (unavailable:' \
    "digest should expose unconfigured bug input"
  assert_contains "$out" 'and 1 more' "digest should report capped remainder"
  [ "$(printf '%s\n' "$out" | grep -c '^  - \[')" -eq 2 ] \
    || fail "digest should print only the configured number of candidate lines"
  pass "digest stays capped and reports unavailable optional lanes"
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
  FM_TEST_SNAPSHOT='{"backlog":{"records":[]},"scout_reports":[]}' \
    run_triage "$root" "$home" --json >/dev/null
  after=$(cksum "$home/data/backlog.md" "$home/state/task.status")
  [ "$before" = "$after" ] || fail "triage must not mutate backlog or state inputs"
  [ ! -e "$home/state/.fleet-triage-handled" ] \
    || fail "enumeration must not create its acknowledgement ledger"
  pass "enumerator leaves operational inputs and ledger untouched"
}

test_json_covers_all_lanes_and_reuses_nf
test_acknowledged_fingerprint_is_suppressed_from_digest
test_digest_is_capped_and_missing_optional_lanes_are_visible
test_enumerator_does_not_mutate_operational_inputs
