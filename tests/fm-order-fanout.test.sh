#!/usr/bin/env bash
# Behavior tests for the completion fan-out at closeout chokepoints
# (ORD-260 slice S3, report section 5.1-C6): bin/fm-order.sh's `fanout` verb and
# its wiring into bin/fm-teardown.sh, bin/fm-pr-merge.sh, and bin/fm-merge-local.sh.
#
# The load-bearing property is that task-done fans out to order-closed AT THE MOMENT
# OF CLOSEOUT, not in a later sweep. The Memory-PR-1 cluster (14 finished tasks whose
# captain orders were never closed) is exactly the loss this closes: work landed, the
# task was torn down, and nothing ever pointed the closing task back at the orders that
# asked for it. So these cases pin that a closeout enumerates the specific non-terminal
# orders linked to the closing task, prints each with its one-line closing command, and
# refreshes the order audit so the gate refuses quiet - and that a closeout with no
# linked order stays silent, exactly like a clean triage pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "ok - fm-order-fanout: skipped (no jq)"; exit 0; }

# fm-order.sh write verbs (add/dispatch/complete/fanout) are primary-only, and firstmate
# development tasks run inside a disposable crewmate worktree whose .fm-crew-role marker makes
# the role resolver report "crewmate". Apply the repository's sanctioned audited override here
# so this suite is self-running in that environment; a clean CI checkout has no marker and is
# already primary, so the override is a harmless no-op there. Every fixture write and closeout
# subprocess in this file inherits it.
export FM_ROLE_OVERRIDE=primary
export FM_ROLE_OVERRIDE_REASON="ORD-260 S3 fan-out test fixtures inside a disposable worktree"

# shellcheck disable=SC2153 # ROOT is provided by tests/lib.sh.
ORDER="$ROOT/bin/fm-order.sh"
TMP_ROOT=$(fm_test_tmproot fm-order-fanout)
fm_git_identity fmtest fmtest@example.invalid

# fresh_home <name>: a home with its own inbox and state dir. Sets HOME_DIR/INBOX/STATE.
fresh_home() {
  local name=$1
  HOME_DIR="$TMP_ROOT/$name"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
  INBOX="$HOME_DIR/captain-orders.jsonl"
  STATE="$HOME_DIR/state"
}

# order: run fm-order.sh scoped to the current fresh_home's inbox and state.
order() {
  FM_ORDERS_PATH="$INBOX" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" "$ORDER" "$@"
}

# ============================================================================
# Part A - the `fanout` verb
# ============================================================================

# --- A1: an order linked to the closing task is surfaced with its closing command ---
fresh_home a1
order add "Land the memory registry PR." "An unrelated request." >/dev/null
order dispatch ORD-001 --task memory-pr-a1 >/dev/null
order dispatch ORD-002 --task other-b2 >/dev/null
OUT=$(order fanout memory-pr-a1 2>&1)
printf '%s\n' "$OUT" | grep -F 'CAPTAIN ORDER FAN-OUT' >/dev/null \
  || fail "fanout did not print the fan-out banner for a linked task"
printf '%s\n' "$OUT" | grep -F 'ORD-001' >/dev/null \
  || fail "fanout did not name the order linked to the closing task"
printf '%s\n' "$OUT" | grep -F 'bin/fm-order.sh complete ORD-001 --link' >/dev/null \
  || fail "fanout did not print the one-line closing command for the linked order"
printf '%s\n' "$OUT" | grep -F 'ORD-002' >/dev/null \
  && fail "fanout surfaced an order that points at a different task"
pass "fanout surfaces the order linked to the closing task, with its closing command, and only that order"

# --- A2: a scout link is followed too (linked_scout_ids), not just linked_task_ids ---
fresh_home a2
order add "Investigate the successor gap." >/dev/null
order dispatch ORD-001 --scout gap-scout-s7 >/dev/null
order fanout gap-scout-s7 2>&1 | grep -F 'ORD-001' >/dev/null \
  || fail "fanout did not follow a linked scout id to its order"
pass "fanout follows a linked scout id, not only a linked task id"

# --- A3: a terminal order is never fanned out (nothing is owed at closeout) ---
fresh_home a3
order add "Already-finished thread." >/dev/null
order dispatch ORD-001 --task done-task-c3 >/dev/null
order complete ORD-001 --link "data/done-task-c3/report.md" >/dev/null
OUT=$(order fanout done-task-c3 2>&1)
[ -z "$OUT" ] || fail "fanout surfaced a terminal (completed) order: $OUT"
pass "a terminal order is excluded from the fan-out"

# --- A4: a closeout with no linked order is silent (rc 0, no output) ---
fresh_home a4
order add "Some request." >/dev/null
order dispatch ORD-001 --task some-task-d4 >/dev/null
set +e
OUT=$(order fanout task-with-no-order 2>&1); RC=$?
set -e
expect_code 0 "$RC" "fanout on a task with no linked order should exit 0"
[ -z "$OUT" ] || fail "fanout was not silent for a task no order points at: $OUT"
pass "a closeout with no linked order fans out nothing, silently"

# --- A5: a missing inbox is a silent no-op, not a die on every closeout ---
fresh_home a5   # no `add`, so the inbox file never gets created
[ ! -f "$INBOX" ] || fail "a5 precondition: inbox should not exist yet"
set +e
OUT=$(order fanout any-task 2>&1); RC=$?
set -e
expect_code 0 "$RC" "fanout must exit 0 when the home has no inbox"
[ -z "$OUT" ] || fail "fanout on a home with no inbox was not silent: $OUT"
JSON=$(order fanout any-task --json 2>/dev/null)
[ "$(printf '%s' "$JSON" | jq -r '.count')" = 0 ] \
  || fail "fanout --json on a missing inbox did not report count 0"
pass "a missing inbox makes fanout a silent no-op (and an empty --json result)"

# --- A6: --json emits a stable machine-readable shape ---
fresh_home a6
order add "First." "Second." >/dev/null
order dispatch ORD-001 --task shared-task-e6 >/dev/null
order dispatch ORD-002 --task shared-task-e6 >/dev/null
JSON=$(order fanout shared-task-e6 --json 2>/dev/null)
[ "$(printf '%s' "$JSON" | jq -r '.schema')" = "fm-order-fanout/v1" ] \
  || fail "fanout --json schema is not fm-order-fanout/v1"
[ "$(printf '%s' "$JSON" | jq -r '.task_id')" = "shared-task-e6" ] \
  || fail "fanout --json did not echo the task id"
[ "$(printf '%s' "$JSON" | jq -r '.count')" = 2 ] \
  || fail "fanout --json did not count both linked orders"
[ "$(printf '%s' "$JSON" | jq -r '.orders | map(.order_id) | join(",")')" = "ORD-001,ORD-002" ] \
  || fail "fanout --json did not list both linked orders sorted by id"
pass "fanout --json emits schema, task id, count, and the sorted linked orders"

# --- A7: the printed closing command is ALWAYS a valid shell command that delivers the exact
# evidence as one argument - a clean token stays readable, and whitespace, an apostrophe, or a
# shell metacharacter is shell-quoted, never left to break the command or (worse) expand.
# This is the qa-dj-s3-q103 regression: a naive single-quote wrap rendered "it's local main"
# as an unbalanced quote, so the advertised close command did not parse. ---
fresh_home a7
order add "Ship it." >/dev/null
order dispatch ORD-001 --task evi-task-f7 >/dev/null
# a clean token (URL/SHA/plain path) is printed unquoted, so the command stays readable.
order fanout evi-task-f7 --evidence "https://github.com/o/r/pull/9" --no-audit 2>&1 \
  | grep -F 'complete ORD-001 --link https://github.com/o/r/pull/9' >/dev/null \
  || fail "fanout did not print a clean evidence token unquoted in the closing command"
# render_link extracts the evidence portion of the printed close command for <evidence>.
render_link() {  # <evidence> -> the "complete ... --link X" tail as printed
  order fanout evi-task-f7 --evidence "$1" --no-audit 2>&1 \
    | grep -oE 'complete ORD-001 --link .*$'
}
# The single-quoted cases are literal metacharacter test data on purpose - the whole point is
# that fanout must NOT let them expand - so SC2016 (no expansion in single quotes) is expected.
# shellcheck disable=SC2016
for ev in \
  "local main" \
  "it's local main" \
  "data/it's a report/report.md" \
  'oops; rm -rf /' \
  'has$var and `backticks`' \
  "quote'and\$meta;chars"; do
  line=$(render_link "$ev")
  [ -n "$line" ] || fail "fanout printed no closing command for evidence [$ev]"
  # The printed command must PARSE as valid shell...
  if ! bash -n <<<"$line" 2>/dev/null; then
    fail "the printed closing command does not parse for evidence [$ev]: $line"
  fi
  # ...and deliver the exact evidence as a single argument, with no expansion.
  got=$(eval "set -- ${line#complete ORD-001 --link }; printf '%s' \"\$1\"")
  [ "$got" = "$ev" ] \
    || fail "the printed closing command did not deliver the exact evidence for [$ev]: got [$got]"
done
pass "the printed closing command always parses and delivers the exact evidence, through whitespace, apostrophes, and shell metacharacters"

# --- A8: fanout refreshes the order audit, so the gate has current truth (unless --no-audit) ---
fresh_home a8
order add "Account me." >/dev/null
order dispatch ORD-001 --task audit-task-g8 >/dev/null
rm -f "$STATE/.order-audit-last.json"
# grace 0 so the just-added order is evaluated on its merits, not excused as "fresh".
FM_ORDER_ACCOUNT_GRACE_SECS=0 order fanout audit-task-g8 >/dev/null 2>&1
[ -f "$STATE/.order-audit-last.json" ] \
  || fail "fanout did not refresh the order audit result file at closeout"
FM_ORDER_ACCOUNT_GRACE_SECS=0 order fanout audit-task-g8 >/dev/null 2>&1
printf '%s' "$(cat "$STATE/.order-audit-last.json")" \
  | jq -e '.unaccounted_orders | map(.order_id) | index("ORD-001")' >/dev/null \
  || fail "the refreshed audit did not carry the still-open linked order as unaccounted"
rm -f "$STATE/.order-audit-last.json"
FM_ORDER_ACCOUNT_GRACE_SECS=0 order fanout audit-task-g8 --no-audit >/dev/null 2>&1
[ ! -f "$STATE/.order-audit-last.json" ] \
  || fail "--no-audit still refreshed the audit result file"
pass "fanout refreshes the audit at closeout, and --no-audit suppresses only that refresh"

# --- A9: a bad invocation is a caller bug and fails loudly ---
fresh_home a9
order add "x." >/dev/null
set +e
order fanout 2>/dev/null; RC=$?
set -e
[ "$RC" -ne 0 ] || fail "fanout with no task id should fail (caller bug), not silently pass"
set +e
order fanout t1 t2 2>/dev/null; RC=$?
set -e
[ "$RC" -ne 0 ] || fail "fanout with two task ids should fail (caller bug)"
pass "fanout rejects a missing or extra task-id argument as a caller bug"

# ============================================================================
# Part B - integration: bin/fm-merge-local.sh fans out at the local-merge closeout
# ============================================================================

MERGE="$ROOT/bin/fm-merge-local.sh"

# A home with state/, a governed project on `main`, a serving worktree, and a finished
# crew branch fm/<id> cut from trunk (mirrors tests/fm-merge-local.test.sh make_fleet).
make_fleet() {
  local name=$1 id=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data"
  git init -q -b main "$dir/proj"
  git -C "$dir/proj" commit -q --allow-empty -m X
  git -C "$dir/proj" worktree add -q -b serving "$dir/serving" main
  git -C "$dir/proj" branch "fm/$id" main
  git -C "$dir/proj" worktree add -q "$dir/crew" "fm/$id"
  git -C "$dir/crew" commit -q --allow-empty -m 'the finished work'
  printf -- '- proj [local-only] - governed test project (added 2026-07-13)\n' > "$dir/home/data/projects.md"
  printf '%s\n' '#!/usr/bin/env node' 'process.exit(0);' > "$dir/home/visibility.mjs"
  cat > "$dir/home/config/canonical-trunk.json" <<EOF
{"schema":"firstmate/canonical-trunk/1","projects":{"proj":{"trunk_branch":"main","trunk_checkout":"$dir/proj","provisioning_base":"main","serving":{"source":"none","why":"no running process serves this test repo"}}}}
EOF
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$dir/crew" \
    "project=$dir/proj" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  FLEET_DIR="$dir"
}

make_fleet mergefleet task-a1
FLEET_INBOX="$FLEET_DIR/home/captain-orders.jsonl"
# A captain order that asked for exactly this task, still open.
FM_ORDERS_PATH="$FLEET_INBOX" FM_STATE_OVERRIDE="$FLEET_DIR/home/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ORDER" add "Land the task-a1 change on local main." >/dev/null
FM_ORDERS_PATH="$FLEET_INBOX" FM_STATE_OVERRIDE="$FLEET_DIR/home/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ORDER" dispatch ORD-001 --task task-a1 >/dev/null
rm -f "$FLEET_DIR/home/state/.order-audit-last.json"

set +e
OUT=$(FM_HOME="$FLEET_DIR/home" FM_ROOT_OVERRIDE='' FM_ORDERS_PATH="$FLEET_INBOX" \
  FM_STATE_OVERRIDE="$FLEET_DIR/home/state" FM_VISIBILITY_CLI="$FLEET_DIR/home/visibility.mjs" \
  "$MERGE" task-a1 2>&1)
RC=$?
set -e
expect_code 0 "$RC" "local-only merge should succeed for a legitimate fast-forward"
printf '%s\n' "$OUT" | grep -F 'CAPTAIN ORDER FAN-OUT' >/dev/null \
  || fail "a local-only merge did not fan out to the open order pointing at the task"
printf '%s\n' "$OUT" | grep -F 'complete ORD-001 --link' >/dev/null \
  || fail "the local-merge fan-out did not print the order's closing command"
[ -f "$FLEET_DIR/home/state/.order-audit-last.json" ] \
  || fail "the local-merge closeout did not refresh the order audit"
pass "a local-only merge fans out to the open captain order and refreshes the audit"

# ============================================================================
# Part C - integration: bin/fm-pr-merge.sh fans out at the PR-merge closeout,
# citing the PR URL as the closing evidence.
# ============================================================================

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"

make_pr_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/wt" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' '#!/usr/bin/env node' 'process.exit(0);' > "$case_dir/visibility.mjs"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  PR_CASE_DIR="$case_dir"
}

make_pr_case prcase
PR_INBOX="$PR_CASE_DIR/captain-orders.jsonl"
PR_URL="https://github.com/example/repo/pull/9"
FM_ORDERS_PATH="$PR_INBOX" FM_STATE_OVERRIDE="$PR_CASE_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ORDER" add "Merge the repo fix." >/dev/null
FM_ORDERS_PATH="$PR_INBOX" FM_STATE_OVERRIDE="$PR_CASE_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ORDER" dispatch ORD-001 --task task-x1 >/dev/null

set +e
OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PR_CASE_DIR/state" FM_ORDERS_PATH="$PR_INBOX" \
  FM_VISIBILITY_CLI="$PR_CASE_DIR/visibility.mjs" PATH="$PR_CASE_DIR/fakebin:$PATH" \
  "$PR_MERGE" task-x1 "$PR_URL" 2>&1)
RC=$?
set -e
expect_code 0 "$RC" "pr-merge should succeed with the gh-axi mock"
printf '%s\n' "$OUT" | grep -F 'CAPTAIN ORDER FAN-OUT' >/dev/null \
  || fail "a PR merge did not fan out to the open order pointing at the task"
printf '%s\n' "$OUT" | grep -F "complete ORD-001 --link $PR_URL" >/dev/null \
  || fail "the PR-merge fan-out did not cite the PR URL as the closing evidence"
pass "a PR merge fans out to the open captain order, citing the PR URL as evidence"

# ============================================================================
# Part D - integration: bin/fm-teardown.sh fans out at a scout closeout,
# citing the report path (following the linked_scout_ids edge).
# ============================================================================

TEARDOWN="$ROOT/bin/fm-teardown.sh"

make_scout_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data/task-s1"
  git init -q -b main "$case_dir/project"
  git -C "$case_dir/project" commit -q --allow-empty -m base
  # A plain (non-treehouse) worktree: teardown skips the pool return and continues.
  git -C "$case_dir/project" worktree add -q -b fm/task-s1 "$case_dir/wt" main
  printf '# findings\n' > "$case_dir/data/task-s1/report.md"
  printf '%s\n' '#!/usr/bin/env node' 'process.exit(0);' > "$case_dir/visibility.mjs"
  touch "$case_dir/state/.last-watcher-beat"
  # Own the session lock so the triage/fan-out path runs as the locked primary.
  printf '%s\n' "$$" > "$case_dir/state/.lock"
  fm_write_meta "$case_dir/state/task-s1.meta" \
    "window=fm-task-s1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=echo" \
    "kind=scout" \
    "mode=local-only" \
    "yolo=off"
  SCOUT_CASE_DIR="$case_dir"
}

make_scout_case scoutcase
SCOUT_INBOX="$SCOUT_CASE_DIR/captain-orders.jsonl"
FM_ORDERS_PATH="$SCOUT_INBOX" FM_STATE_OVERRIDE="$SCOUT_CASE_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ORDER" add "Find out why reports lack successors." >/dev/null
FM_ORDERS_PATH="$SCOUT_INBOX" FM_STATE_OVERRIDE="$SCOUT_CASE_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ORDER" dispatch ORD-001 --scout task-s1 >/dev/null

set +e
OUT=$(FM_HOME="$SCOUT_CASE_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$SCOUT_CASE_DIR/state" FM_CONFIG_OVERRIDE="$SCOUT_CASE_DIR/config" \
  FM_DATA_OVERRIDE="$SCOUT_CASE_DIR/data" FM_ORDERS_PATH="$SCOUT_INBOX" \
  FM_VISIBILITY_CLI="$SCOUT_CASE_DIR/visibility.mjs" \
  "$TEARDOWN" task-s1 2>&1)
RC=$?
set -e
expect_code 0 "$RC" "scout teardown should succeed once the report exists"
printf '%s\n' "$OUT" | grep -F 'CAPTAIN ORDER FAN-OUT' >/dev/null \
  || fail "a scout teardown did not fan out to the open order pointing at the scout task: $OUT"
printf '%s\n' "$OUT" | grep -F 'complete ORD-001 --link' >/dev/null \
  || fail "the scout-teardown fan-out did not print the order's closing command"
printf '%s\n' "$OUT" | grep -F 'report.md' >/dev/null \
  || fail "the scout-teardown fan-out did not cite the report path as the closing evidence"
pass "a scout teardown fans out to the open captain order, citing the report path"

echo "ok - fm-order-fanout: all cases passed"
