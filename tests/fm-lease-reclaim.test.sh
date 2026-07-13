#!/usr/bin/env bash
# Behavior tests for bin/fm-lease-reclaim.sh - treehouse lease reclamation.
#
# The invariant under test is asymmetric and one-directional: a leaked lease whose
# owner is gone AND whose worktree provably holds nothing is returned to the pool;
# EVERY other lease is left strictly alone. A false park costs a report line, a
# false reclaim destroys unlanded work (AGENTS.md prime directive #3), so most of
# what follows is proof that specific lease shapes are NOT touched.
#
# treehouse is faked with a real mutable pool file, so `return` actually flips the
# slot to available and idempotence is exercised for real rather than asserted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECLAIM="$ROOT/bin/fm-lease-reclaim.sh"

TMP=$(fm_test_tmproot fm-lease-reclaim)
fm_git_identity

HOME_DIR="$TMP/home"
PROJECTS="$TMP/projects"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/data" "$PROJECTS"

POOL="$TMP/pool.tsv"
RETURN_LOG="$TMP/returned.log"
: > "$POOL"
: > "$RETURN_LOG"

FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
# Fake treehouse over a TSV pool: slot<TAB>state<TAB>path<TAB>holder<TAB>procs
pool=${FM_TEST_POOL:?}
case "${1:-}" in
  status)
    while IFS=$'\t' read -r slot state path holder procs; do
      [ -n "$slot" ] || continue
      if [ "$state" = leased ]; then
        printf '%-5s %-12s %s  (held by %s)\n' "$slot" "$state" "$path" "$holder"
        if [ "$procs" = procs ]; then
          printf '                   bash (111), claude (222)\n'
        fi
      else
        printf '%-5s %-12s %s\n' "$slot" "$state" "$path"
      fi
    done < "$pool"
    ;;
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in --force) : ;; *) target=$1 ;; esac
      shift
    done
    [ -n "$target" ] || exit 1
    # Refuse a slot that is not leased, exactly as the real CLI does.
    grep -qF "	leased	$target	" "$pool" || exit 1
    printf '%s\n' "$target" >> "${FM_TEST_RETURN_LOG:?}"
    tmp=$(mktemp)
    while IFS=$'\t' read -r slot state path holder procs; do
      [ -n "$slot" ] || continue
      if [ "$path" = "$target" ]; then
        printf '%s\tavailable\t%s\t\t\n' "$slot" "$path"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$slot" "$state" "$path" "$holder" "$procs"
      fi
    done < "$pool" > "$tmp"
    mv "$tmp" "$pool"
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/treehouse"

export PATH="$FAKEBIN:$PATH"
export FM_TEST_POOL="$POOL" FM_TEST_RETURN_LOG="$RETURN_LOG"

# --- fixtures ---------------------------------------------------------------
#
# One project with an origin, so "reachable from a remote" is a real signal, plus
# a second local-only project with no remote at all, which forces the
# content-already-in-the-default-branch path.

PROJ="$PROJECTS/alpha"
fm_git_init_commit "$PROJ"
fm_git_add_origin "$PROJ" "$TMP/alpha-origin.git"
git -C "$PROJ" fetch -q origin
DEFAULT=$(git -C "$PROJ" rev-parse --abbrev-ref HEAD)
git -C "$PROJ" push -q origin "$DEFAULT"
git -C "$PROJ" fetch -q origin

LOCAL_PROJ="$PROJECTS/localonly"
fm_git_init_commit "$LOCAL_PROJ"

WT_DIR="$TMP/wt"
mkdir -p "$WT_DIR"

# new_worktree <project> <name>: a detached-HEAD worktree on the default branch,
# the shape fm-spawn.sh hands a crewmate.
new_worktree() {
  local proj=$1 path="$WT_DIR/$2"
  git -C "$proj" worktree add -q --detach "$path" HEAD
  printf '%s\n' "$path"
}

# lease <slot> <path> <holder> <procs|noprocs>
lease() {
  printf '%s\tleased\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$POOL"
}

# A: clean worktree, HEAD on the remote => genuinely landed => RECLAIM.
WT_CLEAN=$(new_worktree "$PROJ" clean-landed)
lease 1 "$WT_CLEAN" fm-clean-landed-a1 noprocs

# B: uncommitted changes => PARK, always.
WT_DIRTY=$(new_worktree "$PROJ" dirty)
printf 'captain work in progress\n' > "$WT_DIRTY/notes.txt"
git -C "$WT_DIRTY" add notes.txt
lease 2 "$WT_DIRTY" fm-dirty-b2 noprocs

# C: committed work on no remote and not in the default branch => PARK, always.
WT_UNLANDED=$(new_worktree "$PROJ" unlanded)
git -C "$WT_UNLANDED" checkout -q -b fm/unlanded-c3
printf 'unlanded feature\n' > "$WT_UNLANDED/feature.txt"
git -C "$WT_UNLANDED" add feature.txt
git -C "$WT_UNLANDED" -c user.name=t -c user.email=t@e.invalid commit -qm 'unlanded work'
lease 3 "$WT_UNLANDED" fm-unlanded-c3 noprocs

# D: LIVE agent process in the slot, worktree otherwise reclaimable => never touched.
WT_LIVE=$(new_worktree "$PROJ" live-proc)
lease 4 "$WT_LIVE" fm-live-proc-d4 procs

# E: no process, but this home still has the task's meta - a crashed crew that
# recovery/teardown owns. Reclaiming it would destroy the worktree recovery needs.
WT_META=$(new_worktree "$PROJ" live-meta)
fm_write_meta "$STATE/live-meta-e5.meta" \
  "window=firstmate:fm-live-meta-e5" "worktree=$WT_META" "project=$PROJ" "kind=ship"
lease 5 "$WT_META" fm-live-meta-e5 noprocs

# F: a long-PAUSED crew: meta present, deliberately idle on an external wait, no
# busy process. An idle pane is not a dead task.
WT_PAUSED=$(new_worktree "$PROJ" paused)
fm_write_meta "$STATE/paused-f6.meta" \
  "window=firstmate:fm-paused-f6" "worktree=$WT_PAUSED" "project=$PROJ" "kind=ship"
printf 'paused: waiting on upstream release\n' > "$STATE/paused-f6.status"
lease 6 "$WT_PAUSED" fm-paused-f6 noprocs

# G: an IDLE SECONDMATE home. An idle secondmate pane is HEALTHY (AGENTS.md s8) and
# a persistent home is retired only by explicit teardown.
SM_HOME="$TMP/secondmate-home"
mkdir -p "$SM_HOME/state"
fm_write_secondmate_meta "$STATE/sm-g7.meta" "$SM_HOME" "firstmate:fm-sm-g7" alpha
printf -- '- sm-g7 (home: %s; scope: triage; projects: alpha; added 2026-07-12)\n' "$SM_HOME" \
  > "$HOME_DIR/data/secondmates.md"
lease 7 "$SM_HOME" fm-sm-g7 noprocs

# H: a SECONDMATE'S OWN CREW. Its meta lives in the secondmate's state dir, not
# ours; a main-home-only check would read it as an orphan and kill live work.
WT_SM_CREW=$(new_worktree "$PROJ" sm-crew)
fm_write_meta "$SM_HOME/state/sm-crew-h8.meta" \
  "window=firstmate:fm-sm-crew-h8" "worktree=$WT_SM_CREW" "project=$PROJ" "kind=ship"
lease 8 "$WT_SM_CREW" fm-sm-crew-h8 noprocs

# I: a lease held by something that is not a firstmate task. Not ours to judge.
WT_FOREIGN=$(new_worktree "$PROJ" foreign)
lease 9 "$WT_FOREIGN" someone-else-entirely noprocs

# J: clean, no remote anywhere, but the content is already in the local default
# branch => landed => RECLAIM. Exercises the content-in-default path.
WT_MERGED=$(new_worktree "$LOCAL_PROJ" merged-local)
lease 10 "$WT_MERGED" fm-merged-local-j1 noprocs

# --- run --------------------------------------------------------------------

run_reclaim() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_PROJECTS_OVERRIDE="$PROJECTS" \
    "$RECLAIM" "$@" 2>&1
}

OUT=$(run_reclaim) || fail "fm-lease-reclaim.sh exited non-zero"$'\n'"$OUT"

# --- assertions: what MUST be reclaimed -------------------------------------

assert_contains "$OUT" "reclaimed fm-clean-landed-a1" \
  "a dead lease with a clean, landed worktree must be reclaimed"
assert_grep "$WT_CLEAN" "$RETURN_LOG" "clean+landed worktree must be returned to the pool"
grep -qF "	available	$WT_CLEAN	" "$POOL" || fail "reclaimed slot must return to the pool as available"
pass "clean, landed dead lease is reclaimed and its slot returns to the pool"

assert_contains "$OUT" "reclaimed fm-merged-local-j1" \
  "work already contained in the local default branch is landed and must be reclaimed"
pass "dead lease whose work is already in the default branch is reclaimed"

# --- assertions: what must NEVER be reclaimed -------------------------------

assert_contains "$OUT" "PARKED fm-dirty-b2" "a dirty dead lease must be parked"
assert_contains "$OUT" "UNCOMMITTED CHANGES" "the park reason must name the uncommitted changes"
assert_no_grep "$WT_DIRTY" "$RETURN_LOG" "a dirty worktree must NEVER be returned"
pass "dead lease with uncommitted changes is parked, never reclaimed"

assert_contains "$OUT" "PARKED fm-unlanded-c3" "committed-but-unlanded work must be parked"
assert_contains "$OUT" "UNLANDED WORK" "the park reason must name the unlanded commits"
assert_no_grep "$WT_UNLANDED" "$RETURN_LOG" "unlanded committed work must NEVER be returned"
pass "dead lease with committed-but-unlanded work is parked, never reclaimed"

for held in "$WT_LIVE" "$WT_META" "$WT_PAUSED" "$SM_HOME" "$WT_SM_CREW" "$WT_FOREIGN"; do
  assert_no_grep "$held" "$RETURN_LOG" "a live lease was returned: $held"
done
assert_not_contains "$OUT" "fm-live-proc-d4" "a lease with a live agent process must be left alone"
assert_not_contains "$OUT" "fm-live-meta-e5" "a lease whose task this home still records must be left alone"
assert_not_contains "$OUT" "fm-paused-f6" "a long-paused crew's lease must be left alone"
assert_not_contains "$OUT" "fm-sm-g7" "an idle secondmate's home lease must be left alone"
assert_not_contains "$OUT" "fm-sm-crew-h8" "a secondmate's own crew's lease must be left alone"
assert_not_contains "$OUT" "someone-else-entirely" "a non-firstmate lease must be left alone"
pass "live leases are never touched: live process, recorded task, paused crew, idle secondmate, secondmate's crew, foreign holder"

# The captain must be able to see what the fleet let go of, and what it is holding.
assert_contains "$OUT" "need the captain's decision" "parked leases must be surfaced for the captain"
pass "reclaimed and parked leases are both reported"

# --- idempotence ------------------------------------------------------------

RETURNS_BEFORE=$(wc -l < "$RETURN_LOG")
OUT2=$(run_reclaim) || fail "second run exited non-zero"$'\n'"$OUT2"
RETURNS_AFTER=$(wc -l < "$RETURN_LOG")

[ "$RETURNS_BEFORE" = "$RETURNS_AFTER" ] \
  || fail "second run returned more leases; reclamation is not idempotent"
assert_not_contains "$OUT2" "reclaimed fm-clean-landed-a1" \
  "an already-reclaimed slot must not be reclaimed again"
assert_contains "$OUT2" "PARKED fm-dirty-b2" \
  "a parked lease must stay loud on every run until the captain rules on it"
assert_no_grep "$WT_DIRTY" "$RETURN_LOG" "repeated runs must never erode the dirty-lease protection"
pass "reclamation is idempotent and safe to run repeatedly"

# --- dry run ----------------------------------------------------------------

DIRTY_WT2=$(new_worktree "$PROJ" clean-landed-2)
lease 11 "$DIRTY_WT2" fm-clean-landed-k2 noprocs
OUT3=$(run_reclaim --dry-run) || fail "dry run exited non-zero"$'\n'"$OUT3"
assert_contains "$OUT3" "would reclaim fm-clean-landed-k2" "dry run must report what it would reclaim"
assert_no_grep "$DIRTY_WT2" "$RETURN_LOG" "dry run must not return anything"
pass "--dry-run classifies and reports without returning a lease"
