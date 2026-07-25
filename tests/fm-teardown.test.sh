#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" is proven from the task's
# refs/heads/fm/<id>, never recycled worktree HEAD: a remote contains the ref,
# `git cherry` proves all its patches are in the authoritative base, or a merged
# PR positively contains it.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
#   (z) recorded worktree == project's own checkout            -> return skipped, ALLOW (graceful)
#
# Also covers the durable-closeout gate (bin/fm-task-events.sh), which teardown refuses on:
#   (aa) closeout fails outright                     -> REFUSE, volatile state preserved
#   (ab) no TaskRecord exists (task predates the CLI) -> record backfilled, then ALLOW
#   (ac) record already terminal with valid evidence  -> ALLOW on the existing trail
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_STAT_FOR_TEST=$(command -v stat)
export REAL_STAT_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  # Ordinary task worktrees live below a pool-shaped path so teardown's shared
  # treehouse-pool predicate exercises the normal destructive-return path.
  case_dir="$TMP_ROOT/.treehouse/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"
  printf '%s\n' '#!/usr/bin/env node' 'process.exit(0);' > "$case_dir/visibility.mjs"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Report PR 7 as merged with the supplied head, modelling the REAL gh-axi contract
# (bughunt-fm-h2 finding 5). gh-axi's `pr view` takes only a number and emits a
# YAML-ish block (no --json/-q) and exposes NO head OID, so:
#   - fake gh-axi `pr view` prints the structured `state:`/`merged:` block and
#     REJECTS the bare-gh --json/-q flags, so a regression that passes them is caught
#     here instead of masked;
#   - the PR head OID comes from git's refs/pull/<n>/head, so we publish that ref
#     into the bare origin exactly as GitHub keeps it after a squash+delete;
#   - bare `gh` is not used by the teardown chain at all now, so its mock serves only
#     fm-pr-check.sh's own single-field reads (out of finding 5's scope) and fails
#     loudly on anything else, catching any regression back to bare gh in teardown.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1" "pull_requests[1]{number,title,state}:" "  7,merged pr,merged" ; exit 0 ;;
  "pr view")
    for a in "$@"; do
      case "$a" in
        --json|-q|--jq) echo "error: unknown flag '$a' for gh-axi pr view" >&2 ; exit 2 ;;
      esac
    done
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" "  merged: yes" ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
# Only fm-pr-check.sh's own single-field reads (out of finding 5's scope) may use
# bare gh; the teardown safety chain must not. Anything else fails loudly.
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
      *"state"*) printf '%s\n' 'MERGED' ; exit 0 ;;
    esac
    ;;
esac
echo "error: teardown must not call bare gh (bughunt-fm-h2 finding 5)" >&2
exit 3
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
  # Publish the PR head into the bare origin so `git ls-remote origin
  # refs/pull/7/head` resolves it, exactly like GitHub's kept PR head ref (survives
  # the squash+delete these tests simulate). The head commit lives in the worktree's
  # object DB; pushing it by raw SHA uploads the object and creates the ref.
  git -C "$case_dir/wt" push -q origin "$head:refs/pull/7/head" 2>/dev/null || true
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
real=${REAL_STAT_FOR_TEST:?}
last=
for arg in "$@"; do last=$arg; done
case "$last" in
  *index.lock)
    echo "stat: simulated failure" >&2
    exit 1
    ;;
esac
exec "$real" "$@"
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_VISIBILITY_CLI="${FM_VISIBILITY_CLI:-$case_dir/visibility.mjs}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
}

# Closeout is the fleet-triage duty's highest-value trigger: a torn-down task can
# clear a blocker or leave a report with no successor, and nothing else surfaces it.
# The banner is stderr-only so teardown's own stdout stays byte-identical.
# Lock ownership: fm-triage-duty walks our process ancestry for the lock PID, so
# writing this test's own PID makes the case home the locked primary.
own_session_lock() {
  printf '%s\n' "$$" > "$1/state/.lock"
}

test_teardown_prompts_the_fleet_triage_duty() {
  local case_dir
  case_dir=$(make_case triage-duty-ship)
  write_meta "$case_dir" local-only ship
  own_session_lock "$case_dir"
  wt_commit "$case_dir" "landed work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"

  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "triage-duty-ship: teardown failed"
  assert_grep 'FLEET TRIAGE DUTY - TASK TORN DOWN' "$case_dir/stderr" \
    "ship teardown did not prompt the fleet-triage duty"
  assert_grep 'task-x1 torn down.' "$case_dir/stderr" \
    "teardown's duty banner did not name the task"
  assert_no_grep 'FLEET TRIAGE DUTY' "$case_dir/stdout" \
    "the duty banner reached teardown's stdout; it must stay on stderr"
  pass "ship teardown prompts the fleet-triage duty on stderr"
}

test_scout_teardown_prompts_the_scout_completion_duty() {
  local case_dir
  case_dir=$(make_case triage-duty-scout)
  write_meta "$case_dir" local-only scout
  own_session_lock "$case_dir"
  mkdir -p "$case_dir/data/task-x1"
  printf '# findings\n' > "$case_dir/data/task-x1/report.md"

  FM_DATA_OVERRIDE="$case_dir/data" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "triage-duty-scout: teardown failed"
  assert_grep 'FLEET TRIAGE DUTY - SCOUT REPORT CLOSED OUT' "$case_dir/stderr" \
    "scout teardown did not prompt the scout-completion duty"
  pass "scout teardown prompts the duty as a scout completion"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_missing_worktree_does_not_bypass_unlanded_branch_refusal() {
  local case_dir rc missing_wt
  case_dir=$(make_case missing-worktree-unlanded)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unlanded work"
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  missing_wt="$case_dir/wt"
  [ ! -d "$missing_wt" ] || fail "missing-worktree-unlanded: setup did not remove worktree"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-worktree-unlanded: teardown must still require positive branch proof"
  assert_grep "REFUSED: no positive landed proof" "$case_dir/stderr" \
    "missing-worktree-unlanded: missing residency bypassed the branch proof"
  assert_present "$case_dir/state/task-x1.meta" "missing-worktree-unlanded: refusal must preserve meta"
  pass "a missing worktree cannot bypass fail-closed proof for an unlanded task branch"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

# bughunt-fm-h2 finding 9: land a branch whose HEAD IS the merged PR head, then
# add tracked placeholders so .claude/ and .opencode/plugins/ show their untracked
# contents individually (git collapses an entirely-untracked dir). Used by the two
# dirty-filter tests below.
setup_landed_case_with_harness_dirs() {  # <name> -> echoes case_dir
  local case_dir=$1 pr_head
  case_dir=$(make_case "$1")
  write_meta "$case_dir" no-mistakes ship
  mkdir -p "$case_dir/wt/.claude" "$case_dir/wt/.opencode/plugins"
  printf '{}\n' > "$case_dir/wt/.claude/settings.json"
  printf '\n' > "$case_dir/wt/.opencode/plugins/.gitkeep"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "tracked harness dirs"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s' "$case_dir"
}

# The exact firstmate-owned untracked files spawn writes - every harness's turn-end
# hook plus the crew-role marker - must NOT block teardown even when info/exclude
# failed to hide them (simulated here by writing them without excluding). This is
# the symmetry fix: opencode's hook is now ignored just like claude's.
test_teardown_ignores_firstmate_owned_untracked_hooks() {
  local case_dir rc
  case_dir=$(setup_landed_case_with_harness_dirs fm-owned-hooks)
  printf '{}\n'          > "$case_dir/wt/.claude/settings.local.json"
  printf 'x\n'           > "$case_dir/wt/.opencode/plugins/fm-turn-end.js"
  printf 'token=fm.x\n'  > "$case_dir/wt/.fm-grok-turnend"
  printf 'role=crew\n'   > "$case_dir/wt/.fm-crew-role"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fm-owned-hooks: firstmate's own hook files (every harness + crew-role) must not block teardown"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fm-owned-hooks: teardown printed a REFUSED line: $(cat "$case_dir/stderr")"
  pass "teardown ignores every firstmate-owned untracked hook file symmetrically (finding 9)"
}

# The former broad `.claude/` ignore silently discarded a crewmate's own untracked
# work under .claude/. That file must now block teardown, since only the exact
# firstmate-owned names are ignored.
test_teardown_refuses_crewmate_untracked_under_claude() {
  local case_dir rc
  case_dir=$(setup_landed_case_with_harness_dirs crew-claude-file)
  printf 'important draft\n' > "$case_dir/wt/.claude/crewmate-notes.md"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "crew-claude-file: a crewmate's own untracked .claude/ file must block teardown"
  grep -q REFUSED "$case_dir/stderr" || fail "crew-claude-file: no REFUSED line in stderr"
  pass "a crewmate's own untracked file under .claude/ blocks teardown (no longer over-broad, finding 9)"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

# Override the treehouse mock so `treehouse return` fails, simulating treehouse
# refusing a worktree it does not manage (the "is not managed by treehouse"
# choke the robustness fix must survive).
add_treehouse_return_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  echo "error: worktree is not managed by treehouse" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# A meta that records a directory which is NOT a registered worktree of the
# project (reproduces a pre-fix meta that recorded the launch cwd / firstmate
# home instead of the leased worktree) must not brick teardown: it should skip
# the worktree return, warn, and still kill the window and clear volatile state.
test_stale_nontreehouse_worktree_degrades_gracefully() {
  local case_dir rc other
  case_dir=$(make_case stale-nontreehouse)
  # Standalone clone of origin: HEAD is on origin/main (landed, so the
  # landed-work check passes to the worktree-return step) but the clone is not a
  # worktree registered in the project's `git worktree list`.
  other="$case_dir/not-a-pool-worktree"
  git clone -q "$case_dir/origin.git" "$other"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$other" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  add_treehouse_return_failure "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-nontreehouse: teardown must not abort on a non-treehouse worktree"
  grep -q "missing, unsafe, or no longer positively owned" "$case_dir/stderr" \
    || fail "stale-nontreehouse: expected a graceful warning about the non-treehouse worktree"$'\n'"$(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "stale-nontreehouse: meta should be cleared after teardown"
  pass "teardown degrades gracefully when the recorded worktree is not a treehouse worktree"
}

# `git worktree list --porcelain` always lists a project's own primary
# checkout as a registered worktree, so a corrupted/hand-edited meta that
# records worktree=<project's own checkout> must still be refused by
# safe_task_worktree - not just FM_ROOT/FM_HOME - or teardown would detach
# HEAD and delete whatever branch (main) is checked out in the shared clone.
test_project_own_checkout_worktree_degrades_gracefully() {
  local case_dir rc head_branch
  case_dir=$(make_case project-own-checkout)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/project" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  add_treehouse_return_failure "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "project-own-checkout: teardown must not abort when worktree=project"
  grep -q "missing, unsafe, or no longer positively owned" "$case_dir/stderr" \
    || fail "project-own-checkout: expected a graceful warning about the project's own checkout"$'\n'"$(cat "$case_dir/stderr")"
  head_branch=$(git -C "$case_dir/project" rev-parse --abbrev-ref HEAD)
  [ "$head_branch" = main ] \
    || fail "project-own-checkout: teardown detached HEAD on the project's own checkout (branch: $head_branch)"
  assert_absent "$case_dir/state/task-x1.meta" "project-own-checkout: meta should be cleared after graceful teardown"
  pass "recorded worktree equal to the project's own checkout degrades gracefully instead of mutating it"
}

# A same-repo sibling can be registered with the project while still being a
# long-lived serving checkout outside the treehouse pool. Legacy bad meta may
# name one, so teardown must neither detach/delete its branch nor call
# `treehouse return --force` for it.
test_same_repo_sibling_outside_pool_degrades_gracefully() {
  local case_dir rc sibling head_branch return_marker
  case_dir=$(make_case same-repo-sibling-outside-pool)
  sibling="$TMP_ROOT/serving-checkout"
  return_marker="$case_dir/treehouse-return-called"
  git -C "$case_dir/project" worktree add -q -b serving-live "$sibling" main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$sibling" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
touch "$return_marker"
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "same-repo-sibling: teardown must skip a registered sibling outside the pool"
  assert_grep "missing, unsafe, or no longer positively owned" "$case_dir/stderr" \
    "same-repo-sibling: expected a graceful warning about the non-pool sibling"
  head_branch=$(git -C "$sibling" rev-parse --abbrev-ref HEAD)
  [ "$head_branch" = serving-live ] \
    || fail "same-repo-sibling: teardown detached or deleted the serving branch (branch: $head_branch)"
  assert_absent "$return_marker" "same-repo-sibling: teardown called treehouse return for a non-pool sibling"
  assert_absent "$case_dir/state/task-x1.meta" "same-repo-sibling: meta should be cleared after graceful teardown"
  pass "same-repo sibling outside the treehouse pool is preserved and return is skipped"
}

# When the recorded worktree IS positively owned but `treehouse return` fails,
# teardown must fail before writing terminal proof or clearing volatile state.
test_registered_worktree_return_failure_preserves_state() {
  local case_dir rc
  case_dir=$(make_case return-failure-nonfatal)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_treehouse_return_failure "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "return-failure: a failed treehouse return must abort teardown"
  grep -q "treehouse return failed" "$case_dir/stderr" \
    || fail "return-failure: expected a refusal naming the failed return"$'\n'"$(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.meta" "return-failure: meta must remain after incomplete lease cleanup"
  pass "a failed treehouse return preserves volatile state and writes no successful teardown"
}


test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "lsof check failed" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

# A recorded worktree that is a standalone clone rather than a REGISTERED
# worktree of the project (the shape a pre-worktree-path-fix meta could record)
# never reaches the lock machinery at all: safe_task_worktree refuses it, so
# teardown warns, skips the return, and touches nothing inside it - including a
# stale index.lock. That refusal is the point (teardown must not detach,
# branch-delete, or `treehouse return` a directory that is not the task's pool
# worktree), and it is why the "non-linked" .git/index.lock form is only ever a
# defensive branch of worktree_git_lock_path now. The lock-clearing behavior
# itself stays covered for the real (linked, registered) worktree by
# test_stale_index_lock_cleared_and_teardown_succeeds.
test_unregistered_worktree_lock_is_left_untouched() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  # Replace the registered linked worktree with a standalone clone. That clone
  # is not in the project's `git worktree list`, so safe_task_worktree refuses
  # destructive return (the pre-fix "meta recorded the launch cwd" class).
  # Teardown must still complete: warn, skip return, clear volatile state.
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  # Even with a stale index.lock on a normal (non-linked) repo, a non-registered
  # worktree must not brick teardown. Lock clearing is owned by the return path
  # for registered worktrees; this case takes the graceful skip path instead.
  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unregistered-worktree-lock: teardown should still complete (window kill + state clear)"
  assert_grep "missing, unsafe, or no longer positively owned" "$case_dir/stderr" \
    "unregistered-worktree-lock: teardown did not warn that the recorded worktree is unregistered"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "unregistered-worktree-lock: teardown must not touch git state inside an unregistered worktree"
  assert_present "$lock" "unregistered-worktree-lock: the lock file must be left exactly as found"
  assert_absent "$case_dir/state/task-x1.meta" \
    "unregistered-worktree-lock: meta should be cleared after the graceful teardown"
  pass "an unregistered (cloned) worktree is never returned and its index.lock is left untouched"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker endpoint
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=herdr' >> "$case_dir/state/task-x1.meta"
  endpoint="$case_dir/herdr-endpoint"
  : > "$endpoint"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" status --json "*) printf '%s\n' '{"server":{"running":true}}'; exit 0 ;;
  *" pane close "*) rm -f "$FM_FAKE_HERDR_ENDPOINT"; exit 0 ;;
  *" pane get "*) [ -f "$FM_FAKE_HERDR_ENDPOINT" ]; exit ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  FM_FAKE_HERDR_ENDPOINT="$endpoint" run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

test_closeout_failure_preserves_volatile_state() {
  local case_dir rc
  case_dir=$(make_case closeout-failure)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "landed work"
  add_fork_with_pushed_branch "$case_dir"
  printf '%s\n' 'done: ready' > "$case_dir/state/task-x1.status"
  printf '%s\n' '#!/usr/bin/env node' 'process.exit(1);' > "$case_dir/failing-visibility.mjs"
  rc=0
  FM_VISIBILITY_CLI="$case_dir/failing-visibility.mjs" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "closeout failure must refuse teardown"
  assert_present "$case_dir/state/task-x1.meta" "closeout failure must preserve meta"
  assert_present "$case_dir/state/task-x1.status" "closeout failure must preserve status"
  assert_grep 'durable visibility closeout/finalize failed' "$case_dir/stderr" "refusal should name closeout failure"
  pass "closure-evidence failure preserves volatile task state"
}

test_successful_finalize_orders_lease_window_close_and_state_removal() {
  local case_dir order_log endpoint return_line kill_line close_line
  case_dir=$(make_case finalize-order)
  write_meta "$case_dir" local-only ship
  printf '%s\n' 'done: ready' > "$case_dir/state/task-x1.status"
  wt_commit "$case_dir" "landed work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  order_log="$case_dir/finalize-order.log"
  endpoint="$case_dir/tmux-endpoint"
  : > "$order_log"
  : > "$endpoint"

  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then printf '%s\n' return >> "$FM_CLEANUP_ORDER_LOG"; fi
exit 0
SH
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    [ -f "$FM_FAKE_TMUX_ENDPOINT" ] && printf '%s\n' fm-task-x1
    ;;
  kill-window)
    printf '%s\n' kill >> "$FM_CLEANUP_ORDER_LOG"
    rm -f "$FM_FAKE_TMUX_ENDPOINT"
    ;;
esac
exit 0
SH
  cat > "$case_dir/visibility.mjs" <<'JS'
#!/usr/bin/env node
import { appendFileSync } from 'node:fs';
if (process.argv[2] === 'close') appendFileSync(process.env.FM_CLEANUP_ORDER_LOG, 'close\n');
process.exit(0);
JS
  chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/tmux"

  FM_CLEANUP_ORDER_LOG="$order_log" FM_FAKE_TMUX_ENDPOINT="$endpoint" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "finalize-order: teardown failed"

  return_line=$(grep -n '^return$' "$order_log" | cut -d: -f1)
  kill_line=$(grep -n '^kill$' "$order_log" | cut -d: -f1)
  close_line=$(grep -n '^close$' "$order_log" | cut -d: -f1)
  [ "$return_line" -lt "$kill_line" ] && [ "$kill_line" -lt "$close_line" ] \
    || fail "finalize-order: expected return -> kill -> close, got $(tr '\n' ' ' < "$order_log")"
  assert_absent "$case_dir/state/task-x1.meta" "finalize-order: successful close must remove meta"
  assert_absent "$case_dir/state/task-x1.status" "finalize-order: successful close must remove status"
  pass "successful teardown writes terminal proof only after lease/window cleanup, then removes volatile state"
}

test_runtime_endpoint_that_survives_kill_preserves_state_and_has_no_close() {
  local case_dir endpoint order_log rc=0
  case_dir=$(make_case endpoint-survives)
  write_meta "$case_dir" local-only ship
  printf '%s\n' 'done: ready' > "$case_dir/state/task-x1.status"
  wt_commit "$case_dir" "landed work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  endpoint="$case_dir/tmux-endpoint"
  order_log="$case_dir/finalize-order.log"
  : > "$endpoint"
  : > "$order_log"

  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) [ -f "$FM_FAKE_TMUX_ENDPOINT" ] && printf '%s\n' fm-task-x1 ;;
  kill-window) printf '%s\n' kill >> "$FM_CLEANUP_ORDER_LOG" ;;
esac
exit 0
SH
  cat > "$case_dir/visibility.mjs" <<'JS'
#!/usr/bin/env node
import { appendFileSync } from 'node:fs';
if (process.argv[2] === 'close') appendFileSync(process.env.FM_CLEANUP_ORDER_LOG, 'close\n');
process.exit(0);
JS
  chmod +x "$case_dir/fakebin/tmux"

  FM_CLEANUP_ORDER_LOG="$order_log" FM_FAKE_TMUX_ENDPOINT="$endpoint" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "endpoint-survives: teardown must refuse when the endpoint remains"
  assert_present "$case_dir/state/task-x1.meta" "endpoint-survives: meta must remain"
  assert_present "$case_dir/state/task-x1.status" "endpoint-survives: status must remain"
  assert_not_contains "$(cat "$order_log")" "close" "endpoint-survives: no terminal event may precede verified endpoint removal"
  assert_grep "still exists after removal" "$case_dir/stderr" "endpoint-survives: refusal must name the surviving endpoint"
  pass "a runtime endpoint that survives kill cannot produce a closed event or volatile-state removal"
}

# The gate must not trap tasks whose durable record is merely absent: every task that ran
# before the visibility CLI existed has no TaskRecord, and refusing them all is a bug, not
# safety. The writer backfills the record from meta and then closes.
test_missing_task_record_is_backfilled_and_teardown_proceeds() {
  local case_dir rc=0
  case_dir=$(make_case closeout-backfill)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "landed work"
  add_fork_with_pushed_branch "$case_dir"
  printf '%s\n' 'done: ready' > "$case_dir/state/task-x1.status"
  # A visibility CLI that only closes tasks it has a record for, exactly like the real one.
  cat > "$case_dir/visibility.mjs" <<'JS'
#!/usr/bin/env node
import { appendFileSync, existsSync, writeFileSync } from 'node:fs';
const argv = process.argv.slice(2);
const marker = `${process.env.FM_STATE_OVERRIDE}/fake-record`;
appendFileSync(`${process.env.FM_STATE_OVERRIDE}/fake-visibility.log`, `${argv.join(' ')}\n`);
if (argv[0] === 'record') { writeFileSync(marker, 'recorded'); process.exit(0); }
if (argv[0] === 'close' && !existsSync(marker)) {
  console.error(`✗ unknown task: home/${argv[1]}`);
  process.exit(1);
}
process.exit(0);
JS
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a task with no durable record must still be tearable down"
  assert_grep 'record task-x1' "$case_dir/state/fake-visibility.log" "the missing record should be backfilled"
  assert_grep 'close task-x1' "$case_dir/state/fake-visibility.log" "the backfilled record should then be closed"
  assert_absent "$case_dir/state/task-x1.meta" "teardown should clear volatile state once the trail is durable"
  pass "task with no durable record is backfilled, closed, and torn down"
}

# An out-of-band closeout carrying valid evidence is the property the gate protects, so it
# must let teardown through rather than trap the task forever behind its own success.
test_already_terminal_record_allows_teardown() {
  local case_dir rc=0
  case_dir=$(make_case closeout-terminal)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "landed work"
  add_fork_with_pushed_branch "$case_dir"
  printf '%s\n' 'done: ready' > "$case_dir/state/task-x1.status"
  # Record already closed out of band; audit reports its closure evidence is valid.
  cat > "$case_dir/visibility.mjs" <<'JS'
#!/usr/bin/env node
const argv = process.argv.slice(2);
if (argv[0] === 'audit') { console.log('{"ok":true,"diagnostics":[]}'); process.exit(0); }
if (argv[0] === 'close') {
  console.error(`✗ terminal task cannot accept closure_evidence: home/${argv[1]}`);
  process.exit(1);
}
process.exit(0);
JS
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "an already-closed record with valid evidence must not block teardown"
  assert_no_grep 'durable visibility closeout failed' "$case_dir/stderr" "teardown should not refuse a valid existing trail"
  assert_absent "$case_dir/state/task-x1.meta" "teardown should proceed on the existing durable trail"
  pass "already-terminal record with valid evidence lets teardown proceed"
}

test_unreadable_target_meta_blocks_single_record_closeout() {
  local case_dir rc=0 attention_count
  case_dir=$(make_case unreadable-target-meta)
  write_meta "$case_dir" local-only ship
  touch "$case_dir/state/task-x1.status"
  chmod 000 "$case_dir/state/task-x1.meta"

  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  chmod 600 "$case_dir/state/task-x1.meta"

  expect_code 1 "$rc" "single-record teardown must fail when its target meta is unreadable"
  assert_present "$case_dir/state/task-x1.meta" "unreadable target meta must remain"
  assert_present "$case_dir/state/task-x1.status" "unreadable target status must remain"
  assert_grep 'GHOST_RECONCILE: ATTENTION:' "$case_dir/stderr" \
    "unreadable target closeout must emit the shared loud failure"
  assert_grep 'no task records were touched' "$case_dir/stderr" \
    "unreadable target closeout must state the mutation-free result"
  attention_count=$(grep -c '^GHOST_RECONCILE: ATTENTION:' "$case_dir/stderr")
  [ "$attention_count" -eq 1 ] \
    || fail "unreadable target closeout must emit exactly one ATTENTION, got $attention_count"
  pass "single-record teardown consumes the shared attestation before volatile removal"
}

test_local_only_fork_remote_allows
test_unreadable_target_meta_blocks_single_record_closeout
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_missing_worktree_does_not_bypass_unlanded_branch_refusal
test_local_only_merged_to_local_main_allows
test_teardown_prompts_the_fleet_triage_duty
test_scout_teardown_prompts_the_scout_completion_duty
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_herdr_teardown_clears_escalation_marker
test_closeout_failure_preserves_volatile_state
test_successful_finalize_orders_lease_window_close_and_state_removal
test_runtime_endpoint_that_survives_kill_preserves_state_and_has_no_close
test_missing_task_record_is_backfilled_and_teardown_proceeds
test_already_terminal_record_allows_teardown
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_teardown_ignores_firstmate_owned_untracked_hooks
test_teardown_refuses_crewmate_untracked_under_claude
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_unregistered_worktree_lock_is_left_untouched
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_stale_nontreehouse_worktree_degrades_gracefully
test_project_own_checkout_worktree_degrades_gracefully
test_same_repo_sibling_outside_pool_degrades_gracefully
test_registered_worktree_return_failure_preserves_state
