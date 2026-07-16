#!/usr/bin/env bash
# FirstMate-owned Codex checkpoint scheduler adapter.
#
# This is the only approved managed scheduler for Codex bounded checkpoints on
# Linux/WSL homes with a working systemd --user manager.
# It never backgrounds a shell process.
# Production mode writes one deterministic user service/timer pair for the
# canonical FM_HOME and controls it through systemctl --user.
# Test mode is selected by FM_CODEX_SYSTEMD_FAKE_DIR and writes the same
# registration contract into isolated fixture files instead of touching the user
# manager.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SELF="$SCRIPT_DIR/fm-codex-systemd-scheduler.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SYSTEMCTL=${FM_CODEX_SYSTEMD_SYSTEMCTL:-systemctl}

cmd=${1:-}
[ -n "$cmd" ] || { echo "usage: fm-codex-systemd-scheduler.sh <unit-metadata|schedule|validate|status|remove|doctor> ..." >&2; exit 2; }
shift || true

record=
json=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -gt 1 ] || exit 2; FM_HOME=$2; shift 2 ;;
    --state) [ "$#" -gt 1 ] || exit 2; STATE=$2; shift 2 ;;
    --record) [ "$#" -gt 1 ] || exit 2; record=$2; shift 2 ;;
    --json) json=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: fm-codex-systemd-scheduler.sh <command> [--home PATH] [--state PATH] [--record FILE] [--json]

Commands:
  unit-metadata  Print the deterministic unit names and expected unit paths.
  schedule       Register and start the user timer described by --record.
  validate       Verify --record agrees with the registered scheduler.
  status         Print scheduler status as JSON.
  remove         Disable and remove the deterministic timer/service.
  doctor         Report whether a systemd --user manager is available.
EOF
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

need_jq() {
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

canon_path() {
  local p=$1
  cd "$p" 2>/dev/null && pwd -P
}

unit_base() {
  local canon uid hash
  canon=$(canon_path "$FM_HOME") || canon=$FM_HOME
  uid=$(id -u)
  hash=$(printf '%s:%s\n' "$uid" "$canon" | hash_text | cut -c1-16)
  printf 'fm-codex-checkpoint-%s\n' "$hash"
}

unit_dir() {
  if [ -n "${FM_CODEX_SYSTEMD_UNIT_DIR:-}" ]; then
    printf '%s\n' "$FM_CODEX_SYSTEMD_UNIT_DIR"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s/systemd/user\n' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config/systemd/user\n' "$HOME"
  fi
}

metadata_json() {
  local canon_home canon_state base dir bin uid
  canon_home=$(canon_path "$FM_HOME") || canon_home=$FM_HOME
  canon_state=$(canon_path "$STATE") || canon_state=$STATE
  base=$(unit_base)
  dir=$(unit_dir)
  bin=$(canon_path "$SCRIPT_DIR/fm-watch-checkpoint.sh") || bin="$SCRIPT_DIR/fm-watch-checkpoint.sh"
  uid=$(id -u)
  jq -cnS \
    --arg adapter systemd-user-timer \
    --arg unit_name "$base" \
    --arg service_name "$base.service" \
    --arg timer_name "$base.timer" \
    --arg unit_dir "$dir" \
    --arg service_path "$dir/$base.service" \
    --arg timer_path "$dir/$base.timer" \
    --arg exec_path "$bin" \
    --arg fm_home "$canon_home" \
    --arg state_dir "$canon_state" \
    --argjson uid "$uid" \
    '{adapter:$adapter,unit_name:$unit_name,service_name:$service_name,timer_name:$timer_name,
      unit_dir:$unit_dir,service_path:$service_path,timer_path:$timer_path,exec_path:$exec_path,
      fm_home:$fm_home,state_dir:$state_dir,uid:$uid}'
}

systemd_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//%/%%}
  printf '"%s"' "$s"
}

record_field() {
  jq -r "$1 // empty" "$record" 2>/dev/null
}

fake_root() {
  printf '%s\n' "$FM_CODEX_SYSTEMD_FAKE_DIR"
}

fake_registration() {
  local root base
  root=$(fake_root)
  base=$(unit_base)
  printf '%s/timers/%s.json\n' "$root" "$base"
}

status_json_fake() {
  local file meta
  file=$(fake_registration)
  meta=$(metadata_json) || return 1
  if [ -f "$file" ]; then
    jq -cS --argjson meta "$meta" '. + {mode:"fake",registered:true,metadata:$meta}' "$file"
  else
    jq -cnS --argjson meta "$meta" '{mode:"fake",registered:false,metadata:$meta,reason:"not-registered"}'
  fi
}

status_json_real() {
  local meta timer service timer_show service_show timer_load timer_active service_load service_active next realtime
  meta=$(metadata_json) || return 1
  timer=$(printf '%s' "$meta" | jq -r '.timer_name')
  service=$(printf '%s' "$meta" | jq -r '.service_name')
  timer_show=$("$SYSTEMCTL" --user show "$timer" \
    -p LoadState -p ActiveState -p UnitFileState -p FragmentPath -p Triggers -p NextElapseUSecRealtime 2>/dev/null || true)
  service_show=$("$SYSTEMCTL" --user show "$service" \
    -p LoadState -p ActiveState -p UnitFileState -p FragmentPath 2>/dev/null || true)
  timer_load=$(printf '%s\n' "$timer_show" | sed -n 's/^LoadState=//p')
  timer_active=$(printf '%s\n' "$timer_show" | sed -n 's/^ActiveState=//p')
  service_load=$(printf '%s\n' "$service_show" | sed -n 's/^LoadState=//p')
  service_active=$(printf '%s\n' "$service_show" | sed -n 's/^ActiveState=//p')
  realtime=$(printf '%s\n' "$timer_show" | sed -n 's/^NextElapseUSecRealtime=//p')
  next=
  if [ -n "$realtime" ] && command -v date >/dev/null 2>&1; then
    next=$(date -d "$realtime" +%s 2>/dev/null || true)
  fi
  jq -cnS \
    --argjson meta "$meta" \
    --arg timer_load "${timer_load:-not-found}" \
    --arg timer_active "${timer_active:-inactive}" \
    --arg service_load "${service_load:-not-found}" \
    --arg service_active "${service_active:-inactive}" \
    --arg next_raw "$realtime" \
    --arg next_epoch "$next" \
    '{mode:"systemd",registered:($timer_load == "loaded"),metadata:$meta,
      timer:{load:$timer_load,active:$timer_active,next_raw:$next_raw,next_epoch:$next_epoch},
      service:{load:$service_load,active:$service_active}}'
}

validate_record() {
  local status meta adapter timer_active service_load uid expected_uid lease generation cadence due exec home state reasons
  [ -n "$record" ] && [ -f "$record" ] || { printf 'missing-record\n'; return 1; }
  jq -e 'type == "object"' "$record" >/dev/null 2>&1 || { printf 'malformed-record\n'; return 1; }
  status=$("$SCRIPT_SELF" status --home "$FM_HOME" --state "$STATE" --json) || { printf 'scheduler-status-failed\n'; return 1; }
  meta=$(metadata_json) || { printf 'metadata-failed\n'; return 1; }
  adapter=$(record_field '.scheduler.adapter')
  uid=$(record_field '.scheduler.uid')
  expected_uid=$(id -u)
  lease=$(record_field '.lease_id')
  generation=$(record_field '.generation')
  cadence=$(record_field '.cadence_seconds')
  due=$(record_field '.next_checkpoint_due')
  exec=$(record_field '.scheduler.exec_path')
  home=$(record_field '.fm_home')
  state=$(record_field '.state_dir')
  reasons=
  [ "$adapter" = systemd-user-timer ] || reasons="${reasons} adapter-mismatch"
  [ "$uid" = "$expected_uid" ] || reasons="${reasons} uid-mismatch"
  [ "$exec" = "$(printf '%s' "$meta" | jq -r '.exec_path')" ] || reasons="${reasons} exec-mismatch"
  [ "$home" = "$(printf '%s' "$meta" | jq -r '.fm_home')" ] || reasons="${reasons} home-mismatch"
  [ "$state" = "$(printf '%s' "$meta" | jq -r '.state_dir')" ] || reasons="${reasons} state-mismatch"
  if [ "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then
    if [ "$(printf '%s' "$status" | jq -r '.registered')" != true ]; then
      reasons="${reasons} timer-not-registered"
    fi
    [ "$(printf '%s' "$status" | jq -r '.lease_id // empty')" = "$lease" ] || reasons="${reasons} lease-mismatch"
    [ "$(printf '%s' "$status" | jq -r '.generation // empty')" = "$generation" ] || reasons="${reasons} generation-mismatch"
    [ "$(printf '%s' "$status" | jq -r '.cadence_seconds // empty')" = "$cadence" ] || reasons="${reasons} cadence-mismatch"
    [ "$(printf '%s' "$status" | jq -r '.next_checkpoint_due // empty')" = "$due" ] || reasons="${reasons} due-mismatch"
  else
    timer_active=$(printf '%s' "$status" | jq -r '.timer.active // empty')
    service_load=$(printf '%s' "$status" | jq -r '.service.load // empty')
    [ "$(printf '%s' "$status" | jq -r '.registered')" = true ] || reasons="${reasons} timer-not-registered"
    [ "$timer_active" = active ] || reasons="${reasons} timer-not-active"
    [ "$service_load" = loaded ] || reasons="${reasons} service-not-loaded"
    grep -F "FM_CODEX_SYSTEMD_LEASE=$lease" "$(printf '%s' "$meta" | jq -r '.service_path')" >/dev/null 2>&1 || reasons="${reasons} lease-mismatch"
    grep -F "FM_CODEX_SYSTEMD_GENERATION=$generation" "$(printf '%s' "$meta" | jq -r '.service_path')" >/dev/null 2>&1 || reasons="${reasons} generation-mismatch"
    grep -F "FM_CODEX_WATCH_CHECKPOINT=$cadence" "$(printf '%s' "$meta" | jq -r '.service_path')" >/dev/null 2>&1 || reasons="${reasons} cadence-mismatch"
    grep -F "OnCalendar=" "$(printf '%s' "$meta" | jq -r '.timer_path')" >/dev/null 2>&1 || reasons="${reasons} next-trigger-missing"
  fi
  if [ -n "$reasons" ]; then
    reasons=${reasons# }
    [ "$json" -eq 1 ] && jq -cnS --arg ok false --arg reason "$reasons" --argjson status "$status" '{ok:false,reason:$reason,status:$status}'
    [ "$json" -eq 1 ] || printf '%s\n' "$reasons"
    return 1
  fi
  [ "$json" -eq 1 ] && jq -cnS --argjson status "$status" '{ok:true,reason:"valid",status:$status}'
  [ "$json" -eq 1 ] || printf 'valid\n'
  return 0
}

schedule_fake() {
  local root file meta
  root=$(fake_root)
  file=$(fake_registration)
  meta=$(metadata_json) || return 1
  mkdir -p "$root/timers" || return 1
  jq -cS --argjson meta "$meta" \
    '{registered:true,lease_id:.lease_id,generation:.generation,cadence_seconds:.cadence_seconds,
      next_checkpoint_due:.next_checkpoint_due,previous_result:.previous_result,
      fm_home:.fm_home,state_dir:.state_dir,harness:.harness,metadata:$meta}' "$record" > "$file.tmp.$$" || return 1
  mv -f "$file.tmp.$$" "$file"
}

schedule_real() {
  local meta dir service_path timer_path exec_path canon_home canon_state lease generation cadence due calendar
  meta=$(metadata_json) || return 1
  dir=$(printf '%s' "$meta" | jq -r '.unit_dir')
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  exec_path=$(printf '%s' "$meta" | jq -r '.exec_path')
  canon_home=$(printf '%s' "$meta" | jq -r '.fm_home')
  canon_state=$(printf '%s' "$meta" | jq -r '.state_dir')
  lease=$(record_field '.lease_id')
  generation=$(record_field '.generation')
  cadence=$(record_field '.cadence_seconds')
  due=$(record_field '.next_checkpoint_due')
  calendar=$(date -u -d "@$due" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null) || return 1
  mkdir -p "$dir" || return 1
  {
    printf '[Unit]\nDescription=FirstMate Codex checkpoint for %s\n\n' "$canon_home"
    printf '[Service]\nType=oneshot\nWorkingDirectory=%s\n' "$(systemd_quote "$canon_home")"
    printf 'Environment=%s\n' "$(systemd_quote "FM_HOME=$canon_home")"
    printf 'Environment=%s\n' "$(systemd_quote "FM_STATE_OVERRIDE=$canon_state")"
    printf 'Environment=%s\n' "$(systemd_quote 'FM_SUPERVISION_HARNESS=codex')"
    printf 'Environment=%s\n' "$(systemd_quote "FM_CODEX_SYSTEMD_LEASE=$lease")"
    printf 'Environment=%s\n' "$(systemd_quote "FM_CODEX_SYSTEMD_GENERATION=$generation")"
    printf 'Environment=%s\n' "$(systemd_quote "FM_CODEX_WATCH_CHECKPOINT=$cadence")"
    printf 'ExecStart=%s --seconds %s\n' "$exec_path" "$cadence"
  } > "$service_path.tmp.$$" || return 1
  mv -f "$service_path.tmp.$$" "$service_path" || return 1
  {
    printf '[Unit]\nDescription=FirstMate Codex next checkpoint timer for %s\n\n' "$canon_home"
    printf '[Timer]\nOnCalendar=%s\nAccuracySec=1s\nPersistent=true\nUnit=%s\n\n' "$calendar" "$(printf '%s' "$meta" | jq -r '.service_name')"
    printf '[Install]\nWantedBy=timers.target\n'
  } > "$timer_path.tmp.$$" || return 1
  mv -f "$timer_path.tmp.$$" "$timer_path" || return 1
  "$SYSTEMCTL" --user daemon-reload >/dev/null || return 1
  "$SYSTEMCTL" --user enable --now "$(printf '%s' "$meta" | jq -r '.timer_name')" >/dev/null || return 1
}

remove_scheduler() {
  local meta timer service service_path timer_path
  meta=$(metadata_json) || return 1
  timer=$(printf '%s' "$meta" | jq -r '.timer_name')
  service=$(printf '%s' "$meta" | jq -r '.service_name')
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  if [ "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then
    rm -f "$(fake_registration)"
    return 0
  fi
  "$SYSTEMCTL" --user disable --now "$timer" >/dev/null 2>&1 || true
  "$SYSTEMCTL" --user stop "$service" >/dev/null 2>&1 || true
  rm -f "$timer_path" "$service_path"
  "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1 || true
  "$SYSTEMCTL" --user reset-failed "$timer" "$service" >/dev/null 2>&1 || true
}

need_jq

case "$cmd" in
  unit-metadata)
    metadata_json
    ;;
  status)
    if [ "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then status_json_fake; else status_json_real; fi
    ;;
  validate)
    validate_record
    ;;
  schedule)
    [ -n "$record" ] && [ -f "$record" ] || { echo "error: --record FILE is required" >&2; exit 2; }
    if [ "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then schedule_fake; else schedule_real; fi
    ;;
  remove)
    remove_scheduler
    ;;
  doctor)
    if [ "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then
      jq -cnS '{ok:true,mode:"fake"}'
    elif "$SYSTEMCTL" --user is-system-running >/dev/null 2>&1; then
      jq -cnS '{ok:true,mode:"systemd"}'
    else
      jq -cnS '{ok:false,mode:"systemd",reason:"user-manager-unavailable"}'
      exit 1
    fi
    ;;
  *)
    echo "error: unknown command: $cmd" >&2
    exit 2
    ;;
esac
