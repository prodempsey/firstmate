# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh.

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
