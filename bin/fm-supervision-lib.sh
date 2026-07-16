# shellcheck shell=bash
# Shared supervision health predicates.
# Usage: . bin/fm-supervision-lib.sh
#
# fm_supervision_unhealthy is true exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# legacy grace-based warning predicate directly in older call paths. New guards use
# fm_supervision_health, which keeps persistent harnesses on live watcher identity checks
# and lets Codex prove continuity with a durable next-checkpoint schedule after a normal
# bounded checkpoint exits. Scheduled Codex health is never file-content alone: it
# requires a LIVE verified primary (session-lock pid plus process identity, home, and
# UID) that matches the schedule owner, a durable codex harness record for this home,
# and the scheduler adapter's read-back of the loaded timer/service contract. The
# schedule's sha256 `integrity` field is a corruption checksum only, never an
# authenticity control - the state dir is same-account-writable by design, so the Unix
# account boundary is the outermost trust boundary here.

FM_CODEX_CHECKPOINT_SCHEDULE_NAME=.codex-watch-checkpoint.next.json
FM_CODEX_CHECKPOINT_LAST_NAME=.codex-watch-checkpoint.last.json
FM_CODEX_CHECKPOINT_RUNNING_NAME=.codex-watch-checkpoint.running.json
FM_PRIMARY_HARNESS_NAME=.primary-harness.json
FM_CODEX_CHECKPOINT_MECHANISM=codex-bounded-checkpoint
FM_CODEX_SCHEDULING_MECHANISM=systemd-user-timer

# fm_session_lock_owner <state-dir>
# Reads the per-home session lock (state/.lock, whose sole writer is bin/fm-lock.sh:
# the harness PID of the session that owns this home) and prints who owns it now:
#   self     a live holder that is this process or one of its ancestors - we are the
#            locked session, so we own the home.
#   other    a live holder that is provably NOT in our ancestry - another live session
#            owns the home and this one is read-only (AGENTS.md section 3).
#   none     no lock, an unreadable/garbage lock, or a dead holder - nobody owns it.
#   unknown  the ancestry walk could not be completed (no usable ps), so ownership is
#            undeterminable.
# Callers decide their own fail direction; the distinction between `none`/`unknown` and
# `other` is the point. A caller that must not act without ownership treats everything
# but `self` as no; a caller that must not silently disarm itself (bin/fm-turnend-guard.sh)
# stands down only on `other`. Always returns 0.
fm_session_lock_owner() {
  local state=$1 lock holder pid parent depth=0
  lock="$state/.lock"
  if [ ! -f "$lock" ]; then printf 'none\n'; return 0; fi
  holder=$(cat "$lock" 2>/dev/null)
  case "$holder" in
    ''|*[!0-9]*) printf 'none\n'; return 0 ;;
  esac
  if ! kill -0 "$holder" 2>/dev/null; then printf 'none\n'; return 0; fi
  pid=$$
  while [ "$depth" -lt 40 ]; do
    if [ "$pid" = "$holder" ]; then printf 'self\n'; return 0; fi
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$parent" in
      ''|*[!0-9]*) printf 'unknown\n'; return 0 ;;
    esac
    # Reached the top of the tree without meeting the holder: it is a live process on
    # some other branch, i.e. another session.
    [ "$parent" -gt 1 ] || { printf 'other\n'; return 0; }
    pid=$parent
    depth=$((depth + 1))
  done
  printf 'unknown\n'
  return 0
}

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_sup_repo_bin_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd
}

fm_sup_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_sup_hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

fm_supervision_primary_harness_path() {
  printf '%s/%s\n' "$1" "$FM_PRIMARY_HARNESS_NAME"
}

fm_supervision_persist_primary_harness() {
  local state=$1 home=$2 harness=$3 path canon_home primary_identity payload
  mkdir -p "$state" || return 1
  path=$(fm_supervision_primary_harness_path "$state")
  canon_home=$(cd "$home" 2>/dev/null && pwd -P) || canon_home=$home
  primary_identity=$(fm_supervision_detect_primary_identity "$state" "$home" "$harness") || return 1
  payload=$(jq -cnS \
    --arg harness "$harness" \
    --arg primary_identity "$primary_identity" \
    --arg fm_home "$canon_home" \
    --argjson uid "$(id -u)" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{version:1,harness:$harness,primary_identity:$primary_identity,
      fm_home:$fm_home,uid:$uid,recorded_at:$recorded_at}' 2>/dev/null) || return 1
  fm_codex_write_json_atomic "$path" "$payload"
}

# fm_supervision_detect_primary_identity <state> <home> [harness]
# Prints a LIVE, VERIFIED primary identity or fails (review finding F-2):
# outside test mode the only source is the per-home session lock's live holder
# pid bound to its full process identity (fm_pid_identity: start time plus
# command line). A pid whose identity cannot be read is not a verified primary.
# There is deliberately no fallback to recorded state-file content: everything
# in the state dir is same-account-writable, so a recorded identity can assert
# ownership but never prove it.
fm_supervision_detect_primary_identity() {
  local state=$1 home=$2 harness=${3:-} lock pid ident
  if [ "${FM_SUPERVISION_TEST_MODE:-}" = 1 ] && [ -n "${FM_CODEX_PRIMARY_IDENTITY:-}" ]; then
    printf '%s\n' "$FM_CODEX_PRIMARY_IDENTITY"
    return 0
  fi
  lock="$state/.lock"
  pid=$(cat "$lock" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) pid= ;;
  esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    if command -v fm_pid_identity >/dev/null 2>&1 || fm_sup_load_wake_lib; then
      ident=$(fm_pid_identity "$pid" 2>/dev/null || true)
    else
      ident=
    fi
    if [ -n "$ident" ]; then
      printf 'pid:%s:%s\n' "$pid" "$ident"
      return 0
    fi
  fi
  if [ "${FM_SUPERVISION_TEST_MODE:-}" = 1 ]; then
    printf 'test:%s:%s\n' "${harness:-unknown}" "$(cd "$home" 2>/dev/null && pwd -P || printf '%s' "$home")"
    return 0
  fi
  return 1
}

fm_supervision_primary_harness() {
  local state=$1 home=$2 ambient=${3:-} path canon_home harness file_home uid
  path=$(fm_supervision_primary_harness_path "$state")
  if [ -f "$path" ] && command -v jq >/dev/null 2>&1; then
    harness=$(jq -r '.harness // empty' "$path" 2>/dev/null)
    file_home=$(jq -r '.fm_home // empty' "$path" 2>/dev/null)
    uid=$(jq -r '.uid // empty' "$path" 2>/dev/null)
    canon_home=$(cd "$home" 2>/dev/null && pwd -P) || canon_home=$home
    if [ -n "$harness" ] && [ "$file_home" = "$canon_home" ] && [ "$uid" = "$(id -u)" ]; then
      printf '%s\n' "$harness"
      return 0
    fi
  fi
  if [ "${FM_SUPERVISION_TEST_MODE:-}" = 1 ] && [ -n "$ambient" ]; then
    printf '%s\n' "$ambient"
    return 0
  fi
  printf '%s\n' "${ambient:-unknown}"
}

fm_sup_load_wake_lib() {
  command -v fm_watcher_healthy >/dev/null 2>&1 && return 0
  local bin_dir
  bin_dir=$(fm_sup_repo_bin_dir) || return 1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$bin_dir/fm-wake-lib.sh"
}

fm_codex_schedule_path() {
  printf '%s/%s\n' "$1" "$FM_CODEX_CHECKPOINT_SCHEDULE_NAME"
}

fm_codex_last_path() {
  printf '%s/%s\n' "$1" "$FM_CODEX_CHECKPOINT_LAST_NAME"
}

fm_codex_running_path() {
  printf '%s/%s\n' "$1" "$FM_CODEX_CHECKPOINT_RUNNING_NAME"
}

fm_codex_scheduler_cmd() {
  local bin_dir
  bin_dir=$(fm_sup_repo_bin_dir) || return 1
  printf '%s/fm-codex-systemd-scheduler.sh\n' "$bin_dir"
}

fm_codex_scheduler_metadata() {
  local state=$1 home=$2 scheduler
  scheduler=$(fm_codex_scheduler_cmd) || return 1
  [ -x "$scheduler" ] || return 1
  "$scheduler" unit-metadata --state "$state" --home "$home"
}

fm_codex_scheduler_validate() {
  local state=$1 home=$2 record=$3 scheduler out reason
  scheduler=$(fm_codex_scheduler_cmd) || { FM_CODEX_SCHEDULE_REASON='scheduler-missing'; return 1; }
  [ -x "$scheduler" ] || { FM_CODEX_SCHEDULE_REASON='scheduler-missing'; return 1; }
  out=$("$scheduler" validate --state "$state" --home "$home" --record "$record" --json 2>/dev/null) || {
    reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null || true)
    FM_CODEX_SCHEDULE_REASON=${reason:-scheduler-invalid}
    return 1
  }
  [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" = true ] || {
    FM_CODEX_SCHEDULE_REASON=$(printf '%s' "$out" | jq -r '.reason // "scheduler-invalid"' 2>/dev/null)
    return 1
  }
  return 0
}

fm_codex_scheduler_schedule() {
  local state=$1 home=$2 record=$3 scheduler
  scheduler=$(fm_codex_scheduler_cmd) || return 1
  [ -x "$scheduler" ] || return 1
  "$scheduler" schedule --state "$state" --home "$home" --record "$record"
}

fm_codex_scheduler_remove() {
  local state=$1 home=$2 scheduler
  scheduler=$(fm_codex_scheduler_cmd) || return 0
  [ -x "$scheduler" ] || return 0
  "$scheduler" remove --state "$state" --home "$home" >/dev/null 2>&1 || true
}

fm_codex_schedule_files() {
  local state=$1 f
  for f in "$state"/.codex-watch-checkpoint.next*.json; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f"
  done
}

fm_codex_schedule_count() {
  fm_codex_schedule_files "$1" | grep -c . 2>/dev/null || true
}

# fm_codex_primary_identity <state> <home>
# The current primary's identity, live-verified only (review finding F-2). The
# former fallback to the recorded .primary-harness.json identity is deliberately
# gone: a schedule whose owner cannot be matched against a live verified primary
# must never be treated as healthy-checkpoint-scheduled.
fm_codex_primary_identity() {
  fm_supervision_detect_primary_identity "$1" "$2" codex 2>/dev/null
}

fm_codex_schedule_integrity_payload() {
  jq -cS 'del(.integrity)' "$1" 2>/dev/null
}

# The `integrity` field is a plain sha256 CORRUPTION CHECKSUM, not an
# authenticity control: any same-account writer can recompute it, so it detects
# truncation and accidental edits, never forgery. Ownership is proven by the
# live-verified primary identity above, not by this hash.
fm_codex_schedule_integrity() {
  fm_codex_schedule_integrity_payload "$1" | fm_sup_hash_stdin
}

fm_codex_write_json_atomic() {
  local dest=$1 payload=$2 tmp
  tmp="${dest}.tmp.$$"
  printf '%s\n' "$payload" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

# fm_codex_write_json_exclusive <dest> <payload>
# Atomic CREATE (noclobber): fails when <dest> already exists, so exactly one
# concurrent writer wins. This is the running-checkpoint lease acquisition
# (review finding F-6); the old bare `[ -f ]` probe was a TOCTOU window, not a
# lock.
fm_codex_write_json_exclusive() {
  local dest=$1 payload=$2
  ( umask 077; set -o noclobber; printf '%s\n' "$payload" > "$dest" ) 2>/dev/null
}

# fm_codex_checkpoint_release_own <running-path>
# Releases the running-checkpoint lease only when this process owns it; a
# loser or a bystander can never delete the winner's lease. Always returns 0.
fm_codex_checkpoint_release_own() {
  local running=$1 pid
  pid=$(jq -r '.runner_pid // empty' "$running" 2>/dev/null || true)
  [ "$pid" = "$$" ] && rm -f "$running" 2>/dev/null
  return 0
}

fm_codex_build_schedule_payload() {
  local state=$1 home=$2 start_epoch=$3 end_epoch=$4 result=$5 cadence=$6 max_lateness=$7 generation=$8 lease_id=$9
  local canon_home canon_state owner payload hash scheduler
  canon_home=$(cd "$home" 2>/dev/null && pwd -P) || canon_home=$home
  canon_state=$(cd "$state" 2>/dev/null && pwd -P) || canon_state=$state
  owner=$(fm_codex_primary_identity "$state" "$home") || return 1
  scheduler=$(fm_codex_scheduler_metadata "$state" "$home") || return 1
  payload=$(jq -cnS \
    --argjson scheduler "$scheduler" \
    --arg harness codex \
    --arg owner "codex:$owner" \
    --arg primary_identity "$owner" \
    --arg fm_home "$canon_home" \
    --arg state_dir "$canon_state" \
    --arg previous_result "$result" \
    --arg mechanism "$FM_CODEX_CHECKPOINT_MECHANISM" \
    --arg scheduling_mechanism "$FM_CODEX_SCHEDULING_MECHANISM" \
    --arg lease_id "$lease_id" \
    --argjson version 1 \
    --argjson checkpoint_start "$start_epoch" \
    --argjson checkpoint_end "$end_epoch" \
    --argjson next_due "$((end_epoch + cadence))" \
    --argjson cadence_seconds "$cadence" \
    --argjson max_lateness_seconds "$max_lateness" \
    --argjson generation "$generation" \
    '{version:$version,harness:$harness,owner:$owner,primary_identity:$primary_identity,
      fm_home:$fm_home,state_dir:$state_dir,previous_checkpoint_start:$checkpoint_start,
      previous_checkpoint_end:$checkpoint_end,previous_result:$previous_result,
      next_checkpoint_due:$next_due,cadence_seconds:$cadence_seconds,
      max_lateness_seconds:$max_lateness_seconds,generation:$generation,
      lease_id:$lease_id,mechanism:$mechanism,scheduling_mechanism:$scheduling_mechanism,
      scheduler:$scheduler}' 2>/dev/null) || return 1
  hash=$(printf '%s\n' "$payload" | fm_sup_hash_stdin) || return 1
  printf '%s\n' "$payload" | jq -cS --arg integrity "sha256:$hash" '. + {integrity:$integrity}' 2>/dev/null
}

# fm_codex_field_numeric <value>: one field, one check (review finding F-8).
# The old concatenated `start:end:due:...` case pattern had a trailing-empty-
# field hole; every numeric field is validated individually instead.
fm_codex_field_numeric() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

fm_codex_schedule_validate() {
  local state=$1 home=$2 now file
  local count integrity expected version harness mechanism scheduling owner primary current file_home file_state canon_home canon_state durable_harness scheduler_adapter expected_late unit_name timer_name service_name rec_uid
  local start end due cadence late result generation lease
  now=${3:-$(date +%s)}
  file=${4:-$(fm_codex_schedule_path "$state")}
  FM_CODEX_SCHEDULE_REASON=
  FM_CODEX_SCHEDULE_DUE=
  count=$(fm_codex_schedule_count "$state")
  if [ "$count" -gt 1 ]; then
    FM_CODEX_SCHEDULE_REASON=duplicate-schedule
    return 1
  fi
  [ -f "$file" ] || { FM_CODEX_SCHEDULE_REASON=missing-schedule; return 1; }
  command -v jq >/dev/null 2>&1 || { FM_CODEX_SCHEDULE_REASON=jq-missing; return 1; }
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { FM_CODEX_SCHEDULE_REASON=malformed-schedule; return 1; }
  integrity=$(jq -r '.integrity // empty' "$file" 2>/dev/null)
  expected=$(fm_codex_schedule_integrity "$file" 2>/dev/null || true)
  if [ -z "$integrity" ] || [ -z "$expected" ] || [ "$integrity" != "sha256:$expected" ]; then
    FM_CODEX_SCHEDULE_REASON=bad-integrity
    return 1
  fi
  version=$(jq -r '.version // empty' "$file" 2>/dev/null)
  harness=$(jq -r '.harness // empty' "$file" 2>/dev/null)
  mechanism=$(jq -r '.mechanism // empty' "$file" 2>/dev/null)
  scheduling=$(jq -r '.scheduling_mechanism // empty' "$file" 2>/dev/null)
  owner=$(jq -r '.owner // empty' "$file" 2>/dev/null)
  primary=$(jq -r '.primary_identity // empty' "$file" 2>/dev/null)
  file_home=$(jq -r '.fm_home // empty' "$file" 2>/dev/null)
  file_state=$(jq -r '.state_dir // empty' "$file" 2>/dev/null)
  result=$(jq -r '.previous_result // empty' "$file" 2>/dev/null)
  start=$(jq -r '.previous_checkpoint_start // empty' "$file" 2>/dev/null)
  end=$(jq -r '.previous_checkpoint_end // empty' "$file" 2>/dev/null)
  due=$(jq -r '.next_checkpoint_due // empty' "$file" 2>/dev/null)
  cadence=$(jq -r '.cadence_seconds // empty' "$file" 2>/dev/null)
  late=$(jq -r '.max_lateness_seconds // empty' "$file" 2>/dev/null)
  generation=$(jq -r '.generation // empty' "$file" 2>/dev/null)
  lease=$(jq -r '.lease_id // empty' "$file" 2>/dev/null)
  scheduler_adapter=$(jq -r '.scheduler.adapter // empty' "$file" 2>/dev/null)
  unit_name=$(jq -r '.scheduler.unit_name // empty' "$file" 2>/dev/null)
  timer_name=$(jq -r '.scheduler.timer_name // empty' "$file" 2>/dev/null)
  service_name=$(jq -r '.scheduler.service_name // empty' "$file" 2>/dev/null)
  rec_uid=$(jq -r '.scheduler.uid // empty' "$file" 2>/dev/null)
  [ "$version" = 1 ] || { FM_CODEX_SCHEDULE_REASON=unsupported-version; return 1; }
  [ "$harness" = codex ] || { FM_CODEX_SCHEDULE_REASON='harness-mismatch'; return 1; }
  [ "$mechanism" = "$FM_CODEX_CHECKPOINT_MECHANISM" ] || { FM_CODEX_SCHEDULE_REASON='mechanism-mismatch'; return 1; }
  [ "$scheduling" = "$FM_CODEX_SCHEDULING_MECHANISM" ] || { FM_CODEX_SCHEDULE_REASON='scheduler-mismatch'; return 1; }
  [ "$scheduler_adapter" = "$FM_CODEX_SCHEDULING_MECHANISM" ] || { FM_CODEX_SCHEDULE_REASON='scheduler-mismatch'; return 1; }
  [ -n "$unit_name" ] && [ -n "$timer_name" ] && [ -n "$service_name" ] || { FM_CODEX_SCHEDULE_REASON='scheduler-mismatch'; return 1; }
  durable_harness=$(fm_supervision_primary_harness "$state" "$home" "")
  [ "$durable_harness" = codex ] || { FM_CODEX_SCHEDULE_REASON='harness-mismatch'; return 1; }
  current=$(fm_codex_primary_identity "$state" "$home") || { FM_CODEX_SCHEDULE_REASON='owner-mismatch'; return 1; }
  [ "$primary" = "$current" ] && [ "$owner" = "codex:$current" ] || { FM_CODEX_SCHEDULE_REASON='owner-mismatch'; return 1; }
  canon_home=$(cd "$home" 2>/dev/null && pwd -P) || canon_home=$home
  canon_state=$(cd "$state" 2>/dev/null && pwd -P) || canon_state=$state
  [ "$file_home" = "$canon_home" ] && [ "$file_state" = "$canon_state" ] || { FM_CODEX_SCHEDULE_REASON='home-mismatch'; return 1; }
  case "$result" in
    quiet|wake) ;;
    failed) FM_CODEX_SCHEDULE_REASON='last-checkpoint-failed'; return 1 ;;
    *) FM_CODEX_SCHEDULE_REASON=bad-result; return 1 ;;
  esac
  [ "$rec_uid" = "$(id -u)" ] || { FM_CODEX_SCHEDULE_REASON=uid-mismatch; return 1; }
  fm_codex_field_numeric "$start" || { FM_CODEX_SCHEDULE_REASON=bad-time; return 1; }
  fm_codex_field_numeric "$end" || { FM_CODEX_SCHEDULE_REASON=bad-time; return 1; }
  fm_codex_field_numeric "$due" || { FM_CODEX_SCHEDULE_REASON=bad-time; return 1; }
  fm_codex_field_numeric "$cadence" || { FM_CODEX_SCHEDULE_REASON=bad-cadence; return 1; }
  fm_codex_field_numeric "$late" || { FM_CODEX_SCHEDULE_REASON=bad-lateness; return 1; }
  fm_codex_field_numeric "$generation" || { FM_CODEX_SCHEDULE_REASON=bad-generation; return 1; }
  [ -n "$lease" ] || { FM_CODEX_SCHEDULE_REASON=missing-lease; return 1; }
  case "$lease" in
    *[!A-Za-z0-9._-]*) FM_CODEX_SCHEDULE_REASON=bad-lease; return 1 ;;
  esac
  [ "$end" -ge "$start" ] || { FM_CODEX_SCHEDULE_REASON=bad-time-order; return 1; }
  [ "$due" -ge "$end" ] || { FM_CODEX_SCHEDULE_REASON=bad-due-time; return 1; }
  [ "$cadence" -gt 0 ] || { FM_CODEX_SCHEDULE_REASON=bad-cadence; return 1; }
  [ "$generation" -gt 0 ] || { FM_CODEX_SCHEDULE_REASON=bad-generation; return 1; }
  expected_late=${FM_CODEX_WATCH_CHECKPOINT_MAX_LATENESS:-60}
  case "$expected_late" in ''|*[!0-9]*) expected_late=60 ;; esac
  [ "$late" -le "$expected_late" ] || { FM_CODEX_SCHEDULE_REASON=bad-lateness; return 1; }
  if [ "$now" -gt "$((due + late))" ]; then
    FM_CODEX_SCHEDULE_REASON=checkpoint-overdue
    FM_CODEX_SCHEDULE_DUE=$due
    return 1
  fi
  fm_codex_scheduler_validate "$state" "$home" "$file" || return 1
  FM_CODEX_SCHEDULE_REASON=valid
  FM_CODEX_SCHEDULE_DUE=$due
  return 0
}

fm_codex_last_checkpoint_failed() {
  local state=$1 last
  last=$(fm_codex_last_path "$state")
  [ -f "$last" ] || return 1
  [ "$(jq -r '.previous_result // .result // empty' "$last" 2>/dev/null)" = failed ]
}

fm_codex_checkpoint_start_record() {
  local state=$1 home=$2 start_epoch=$3 cadence=$4 generation=$5 lease=$6 running owner canon_home canon_state payload
  running=$(fm_codex_running_path "$state")
  owner=$(fm_codex_primary_identity "$state" "$home") || return 1
  canon_home=$(cd "$home" 2>/dev/null && pwd -P) || canon_home=$home
  canon_state=$(cd "$state" 2>/dev/null && pwd -P) || canon_state=$state
  payload=$(jq -cnS \
    --arg owner "codex:$owner" \
    --arg primary_identity "$owner" \
    --arg fm_home "$canon_home" \
    --arg state_dir "$canon_state" \
    --arg mechanism "$FM_CODEX_CHECKPOINT_MECHANISM" \
    --arg lease_id "$lease" \
    --argjson version 1 \
    --argjson runner_pid "$$" \
    --argjson checkpoint_start "$start_epoch" \
    --argjson cadence_seconds "$cadence" \
    --argjson generation "$generation" \
    '{version:$version,harness:"codex",owner:$owner,primary_identity:$primary_identity,
      fm_home:$fm_home,state_dir:$state_dir,runner_pid:$runner_pid,
      checkpoint_start:$checkpoint_start,cadence_seconds:$cadence_seconds,
      generation:$generation,lease_id:$lease_id,
      mechanism:$mechanism}' 2>/dev/null) || return 1
  fm_codex_write_json_atomic "$running" "$payload"
}

# fm_codex_checkpoint_prepare <state> <home> <start-epoch> <cadence>
# Order matters (review finding F-6): resolve the live identity first (nothing
# consumed on an identity blip), acquire the running-checkpoint lease
# atomically, and only then - holding exclusive ownership - validate and
# consume the prior schedule and its armed timer. A losing or failing prepare
# releases only its own lease and leaves the winner and any prior-valid
# schedule untouched.
fm_codex_checkpoint_prepare() {
  local state=$1 home=$2 start_epoch=$3 cadence=$4 running pid count schedule generation lease owner canon_home canon_state payload
  FM_CODEX_CHECKPOINT_PREPARE_REASON=
  mkdir -p "$state" || return 1
  running=$(fm_codex_running_path "$state")
  owner=$(fm_codex_primary_identity "$state" "$home") || {
    FM_CODEX_CHECKPOINT_PREPARE_REASON=identity-unresolvable
    return 1
  }
  if [ -f "$running" ]; then
    pid=$(jq -r '.runner_pid // empty' "$running" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) rm -f "$running" 2>/dev/null || true ;;
      *)
        if kill -0 "$pid" 2>/dev/null; then
          FM_CODEX_CHECKPOINT_PREPARE_REASON=duplicate-running-checkpoint
          return 1
        fi
        rm -f "$running" 2>/dev/null || true
        ;;
    esac
  fi
  lease="${start_epoch}-$$-${RANDOM:-0}"
  canon_home=$(cd "$home" 2>/dev/null && pwd -P) || canon_home=$home
  canon_state=$(cd "$state" 2>/dev/null && pwd -P) || canon_state=$state
  payload=$(jq -cnS \
    --arg owner "codex:$owner" \
    --arg primary_identity "$owner" \
    --arg fm_home "$canon_home" \
    --arg state_dir "$canon_state" \
    --arg mechanism "$FM_CODEX_CHECKPOINT_MECHANISM" \
    --arg lease_id "$lease" \
    --argjson version 1 \
    --argjson runner_pid "$$" \
    --argjson checkpoint_start "$start_epoch" \
    --argjson cadence_seconds "$cadence" \
    '{version:$version,harness:"codex",owner:$owner,primary_identity:$primary_identity,
      fm_home:$fm_home,state_dir:$state_dir,runner_pid:$runner_pid,
      checkpoint_start:$checkpoint_start,cadence_seconds:$cadence_seconds,
      generation:0,lease_id:$lease_id,mechanism:$mechanism}' 2>/dev/null) || return 1
  if ! fm_codex_write_json_exclusive "$running" "$payload"; then
    FM_CODEX_CHECKPOINT_PREPARE_REASON=duplicate-running-checkpoint
    return 1
  fi
  count=$(fm_codex_schedule_count "$state")
  if [ "$count" -gt 1 ]; then
    fm_codex_checkpoint_release_own "$running"
    FM_CODEX_CHECKPOINT_PREPARE_REASON=duplicate-schedule
    return 1
  fi
  schedule=$(fm_codex_schedule_path "$state")
  generation=0
  if [ -f "$schedule" ]; then
    if ! fm_codex_schedule_validate "$state" "$home" "$(date +%s)" "$schedule"; then
      if [ "$FM_CODEX_SCHEDULE_REASON" != checkpoint-overdue ]; then
        fm_codex_checkpoint_release_own "$running"
        FM_CODEX_CHECKPOINT_PREPARE_REASON=$FM_CODEX_SCHEDULE_REASON
        return 1
      fi
    fi
    generation=$(jq -r '.generation // 0' "$schedule" 2>/dev/null)
    fm_codex_scheduler_remove "$state" "$home"
    if ! rm -f "$schedule"; then
      fm_codex_checkpoint_release_own "$running"
      FM_CODEX_CHECKPOINT_PREPARE_REASON=consume-schedule-failed
      return 1
    fi
  fi
  if ! fm_codex_checkpoint_start_record "$state" "$home" "$start_epoch" "$cadence" "$generation" "$lease"; then
    fm_codex_checkpoint_release_own "$running"
    FM_CODEX_CHECKPOINT_PREPARE_REASON=write-running-record-failed
    return 1
  fi
  # shellcheck disable=SC2034 # Read by callers after fm_codex_checkpoint_prepare returns.
  FM_CODEX_CHECKPOINT_GENERATION=$generation
  # shellcheck disable=SC2034 # Read by callers after fm_codex_checkpoint_prepare returns.
  FM_CODEX_CHECKPOINT_LEASE=$lease
  # shellcheck disable=SC2034 # Read by callers after fm_codex_checkpoint_prepare returns.
  FM_CODEX_CHECKPOINT_PREPARE_REASON=ok
  return 0
}

fm_codex_checkpoint_finish() {
  local state=$1 home=$2 start_epoch=$3 end_epoch=$4 result=$5 cadence=$6 max_lateness=$7 generation=$8
  local lease payload schedule last running running_pid running_lease tmp_schedule
  schedule=$(fm_codex_schedule_path "$state")
  last=$(fm_codex_last_path "$state")
  running=$(fm_codex_running_path "$state")
  running_pid=$(jq -r '.runner_pid // empty' "$running" 2>/dev/null || true)
  running_lease=$(jq -r '.lease_id // empty' "$running" 2>/dev/null || true)
  if [ "$running_pid" != "$$" ]; then
    return 1
  fi
  if [ -n "${FM_CODEX_CHECKPOINT_LEASE:-}" ] && [ "$running_lease" != "$FM_CODEX_CHECKPOINT_LEASE" ]; then
    return 1
  fi
  lease="${end_epoch}-$$-${RANDOM:-0}"
  payload=$(fm_codex_build_schedule_payload "$state" "$home" "$start_epoch" "$end_epoch" "$result" "$cadence" "$max_lateness" "$((generation + 1))" "$lease") || return 1
  fm_codex_write_json_atomic "$last" "$payload" || return 1
  if [ "$result" = failed ]; then
    fm_codex_scheduler_remove "$state" "$home"
    rm -f "$schedule" "$running" 2>/dev/null || true
    return 0
  fi
  tmp_schedule="${schedule}.candidate.$$"
  fm_codex_write_json_atomic "$tmp_schedule" "$payload" || return 1
  if ! fm_codex_scheduler_schedule "$state" "$home" "$tmp_schedule"; then
    rm -f "$tmp_schedule"
    return 1
  fi
  if ! mv -f "$tmp_schedule" "$schedule"; then
    rm -f "$tmp_schedule"
    fm_codex_scheduler_remove "$state" "$home"
    return 1
  fi
  rm -f "$running" 2>/dev/null || true
  return 0
}

fm_supervision_health() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} harness=${5:-unknown}
  local running=false count reason
  FM_SUP_HEALTH_STATE=healthy-persistent
  FM_SUP_HEALTHY=true
  FM_SUP_HEALTH_REASON=none
  FM_SUP_SCHEDULE_DUE=
  fm_supervision_status "$state" "$grace"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] || return 0
  fm_sup_load_wake_lib || {
    FM_SUP_HEALTH_STATE=unhealthy-no-supervision
    FM_SUP_HEALTHY=false
    FM_SUP_HEALTH_REASON=wake-lib-unavailable
    return 0
  }
  if fm_watcher_healthy "$state" "$watch_path" "$grace" "$home"; then
    running=true
  fi
  if [ "$harness" != codex ]; then
    if [ "$running" = true ]; then
      FM_SUP_HEALTH_STATE=healthy-persistent
      FM_SUP_HEALTHY=true
      FM_SUP_HEALTH_REASON=watcher-running
    else
      FM_SUP_HEALTH_STATE=unhealthy-no-supervision
      FM_SUP_HEALTHY=false
      FM_SUP_HEALTH_REASON=${FM_WATCHER_DIAG_FAIL:-watcher-down}
    fi
    return 0
  fi
  count=$(fm_codex_schedule_count "$state")
  if [ "$running" = true ]; then
    if [ "$count" -gt 0 ]; then
      FM_SUP_HEALTH_STATE=unhealthy-duplicate-owner
      FM_SUP_HEALTHY=false
      FM_SUP_HEALTH_REASON=live-plus-scheduled
    else
      FM_SUP_HEALTH_STATE=healthy-checkpoint-running
      FM_SUP_HEALTHY=true
      FM_SUP_HEALTH_REASON=checkpoint-running
    fi
    return 0
  fi
  if fm_codex_schedule_validate "$state" "$home" "$(date +%s)"; then
    FM_SUP_HEALTH_STATE=healthy-checkpoint-scheduled
    FM_SUP_HEALTHY=true
    FM_SUP_HEALTH_REASON=checkpoint-scheduled
    # shellcheck disable=SC2034 # Read by callers after fm_supervision_health returns.
    FM_SUP_SCHEDULE_DUE=$FM_CODEX_SCHEDULE_DUE
    return 0
  fi
  reason=$FM_CODEX_SCHEDULE_REASON
  case "$reason" in
    checkpoint-overdue)
      FM_SUP_HEALTH_STATE=unhealthy-checkpoint-overdue ;;
    owner-mismatch|home-mismatch|harness-mismatch|mechanism-mismatch|uid-mismatch*)
      FM_SUP_HEALTH_STATE=unhealthy-owner-mismatch ;;
    scheduler-mismatch|scheduler-missing|scheduler-invalid|timer-not-registered*|timer-not-active*|timer-not-enabled*|service-not-loaded*)
      FM_SUP_HEALTH_STATE=unhealthy-no-supervision ;;
    duplicate-schedule|duplicate-unit*)
      FM_SUP_HEALTH_STATE=unhealthy-duplicate-owner ;;
    last-checkpoint-failed)
      FM_SUP_HEALTH_STATE=unhealthy-last-checkpoint-failed ;;
    *)
      if fm_codex_last_checkpoint_failed "$state"; then
        FM_SUP_HEALTH_STATE=unhealthy-last-checkpoint-failed
        reason='last-checkpoint-failed'
      else
        # shellcheck disable=SC2034 # Read by callers after fm_supervision_health returns.
        FM_SUP_HEALTH_STATE=unhealthy-no-supervision
      fi
      ;;
  esac
  # shellcheck disable=SC2034 # Read by callers after fm_supervision_health returns.
  FM_SUP_HEALTHY=false
  # shellcheck disable=SC2034 # Read by callers after fm_supervision_health returns.
  FM_SUP_HEALTH_REASON=$reason
  return 0
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
