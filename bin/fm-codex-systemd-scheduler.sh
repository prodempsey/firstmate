#!/usr/bin/env bash
# FirstMate-owned Codex checkpoint scheduler adapter.
#
# This is the only approved managed scheduler for Codex bounded checkpoints on
# Linux/WSL homes with a working systemd --user manager.
# It never backgrounds a shell process.
# Production mode writes one deterministic user service/timer pair for the
# canonical FM_HOME and controls it through systemctl --user.
#
# Test seams are FAIL-CLOSED (review finding F-1): FM_CODEX_SYSTEMD_FAKE_DIR,
# FM_CODEX_SYSTEMD_SYSTEMCTL, and FM_CODEX_SYSTEMD_UNIT_DIR are honored only
# under FM_SUPERVISION_TEST_MODE=1, and only when the evaluated home, state
# dir, and overridden directories are provably test-owned: each must sit under
# a root carrying the .fm-test-owner marker written by tests/lib.sh (the same
# marker bin/fm-test-tmp-sweep.sh reclaims by), and never inside the real user
# unit directory. Any override set without that full gate is an error, never a
# fallback to fake or real mode, so no ambient environment variable can
# substitute a file for a real `systemctl --user` query in production.
# Every gated path is CANONICALIZED before ownership and containment are
# judged and before any use (review-r6-sol F-1): symlink and `..` aliases
# resolve to what they actually address, ambiguous ancestry (a dangling
# symlink or an existing non-directory in a not-yet-created suffix) is
# rejected outright, and the canonical form replaces the alias for the rest
# of the run so mutating operations never write through an accepted alias.
#
# Every record field that reaches a unit file is validated first (review
# finding F-4): leases against a safe charset, numbers as bounded digits, paths
# against control characters. The service command is constructed only from this
# adapter's own computed metadata plus the validated numeric cadence, never
# from free-form record text.
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
  install        Register and start the user timer described by --record.
  register       Register and start the user timer described by --record.
  arm            Register and start the user timer described by --record.
  schedule       Register and start the user timer described by --record.
  status         Print scheduler status as JSON.
  query          Print scheduler status as JSON.
  validate       Verify --record agrees with the loaded scheduler contract.
  disable        Disable the deterministic timer but leave unit files inspectable.
  remove         Disable and remove the deterministic timer/service.
  doctor         Report whether a systemd --user manager is available.

Test seams (FM_CODEX_SYSTEMD_FAKE_DIR, FM_CODEX_SYSTEMD_SYSTEMCTL,
FM_CODEX_SYSTEMD_UNIT_DIR) require FM_SUPERVISION_TEST_MODE=1 and test-owned
directories; any of them set without that gate fails closed with exit 2.
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

# refuse <reason>: fail closed with a machine-readable reason. Under --json the
# reason lands on stdout as the same {ok:false,reason} shape validate emits, so
# callers surface it instead of a generic failure.
refuse() {
  local reason=$1
  [ "$json" -eq 1 ] && printf '{"ok":false,"reason":"%s"}\n' "$reason"
  echo "error: $reason" >&2
  exit 2
}

real_default_unit_dir() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s/systemd/user\n' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config/systemd/user\n' "$HOME"
  fi
}

path_inside() {  # <path> <root> - true when <path> is <root> or inside it
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}

# canon_gated_dir <path>: print the fully canonical form of a gated directory
# path (review-r6-sol F-1). The deepest existing prefix is resolved with
# cd/pwd -P, so symlink and normalized-`..` aliases become the path they
# actually address before any ownership or containment judgment. A
# not-yet-created suffix is allowed only as plain child components: never '.',
# '..', or empty, and never an existing non-directory or dangling symlink,
# which a later mkdir -p would follow somewhere else. Ambiguous ancestry fails
# instead of falling back to the raw string.
# bin/fm-supervision-lib.sh carries the same walk as fm_sup_canon_gated_path
# for its own boundary; this adapter deliberately does not source that library.
canon_gated_dir() {
  local p=$1 rest='' c canon
  case "$p" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$p" in
    *[![:print:]]*) return 1 ;;
  esac
  while [ "$p" != / ] && [ ! -d "$p" ]; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      return 1
    fi
    c=${p##*/}
    case "$c" in
      .|..|'') return 1 ;;
    esac
    rest="/$c$rest"
    p=${p%/*}
    [ -n "$p" ] || p=/
  done
  canon=$(cd "$p" 2>/dev/null && pwd -P) || return 1
  [ "$canon" = / ] && canon=
  if [ -z "$canon" ] && [ -z "$rest" ]; then
    printf '/\n'
  else
    printf '%s%s\n' "$canon" "$rest"
  fi
}

# canon_gated_file <path>: canonical form of a gated executable path. The file
# must exist as a regular non-symlink file, and its parent directory is
# canonicalized like any other gated path.
canon_gated_file() {
  local p=$1 dir base
  case "$p" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -L "$p" ] && return 1
  [ -f "$p" ] || return 1
  base=${p##*/}
  case "$base" in
    .|..|'') return 1 ;;
  esac
  dir=$(canon_gated_dir "${p%/*}") || return 1
  [ "$dir" = / ] && dir=
  printf '%s/%s\n' "$dir" "$base"
}

# path_test_owned <path>: true when <path> sits under a root that carries the
# .fm-test-owner marker written by tests/lib.sh - the repo's one durable proof
# that a directory belongs to a test fixture, the same marker
# bin/fm-test-tmp-sweep.sh reclaims by. The walk uses the path string, so a
# not-yet-created fixture subdirectory still proves ownership through its
# existing marker-carrying ancestor.
path_test_owned() {
  local p=$1
  case "$p" in
    /*) ;;
    *) return 1 ;;
  esac
  while [ -n "$p" ] && [ "$p" != / ]; do
    [ -f "$p/.fm-test-owner" ] && return 0
    p=$(dirname "$p")
  done
  return 1
}

# --- fail-closed test-seam gate (F-1, canonicalized per review-r6-sol F-1) -----
# Runs before any command dispatch. Production (no FM_SUPERVISION_TEST_MODE=1)
# refuses every test override outright; test mode additionally requires the
# evaluated home, state dir, and overridden paths to be provably test-owned
# and outside the real user unit directory. Every judgment runs on the
# CANONICAL path, and the canonical form replaces the supplied value for the
# rest of the run, so a symlink or `..` alias that survives the gate cannot
# later be written through: what was judged is what is used.
GATE_ENGAGED=0
test_seam_gate() {
  local overrides='' real_units canon
  [ -n "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ] && overrides="$overrides FM_CODEX_SYSTEMD_FAKE_DIR"
  [ -n "${FM_CODEX_SYSTEMD_SYSTEMCTL:-}" ] && overrides="$overrides FM_CODEX_SYSTEMD_SYSTEMCTL"
  [ -n "${FM_CODEX_SYSTEMD_UNIT_DIR:-}" ] && overrides="$overrides FM_CODEX_SYSTEMD_UNIT_DIR"
  [ -n "$overrides" ] || return 0
  if [ "${FM_SUPERVISION_TEST_MODE:-}" != 1 ]; then
    refuse "test-override-without-test-mode:${overrides# }"
  fi
  real_units=$(canon_gated_dir "$(real_default_unit_dir)") || refuse 'real-unit-dir-unresolvable'
  canon=$(canon_gated_dir "$FM_HOME") || refuse 'test-override-home-unresolvable'
  FM_HOME=$canon
  path_test_owned "$FM_HOME" || refuse 'test-override-home-not-test-owned'
  canon=$(canon_gated_dir "$STATE") || refuse 'test-override-state-unresolvable'
  STATE=$canon
  path_test_owned "$STATE" || refuse 'test-override-state-not-test-owned'
  if [ -n "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then
    canon=$(canon_gated_dir "$FM_CODEX_SYSTEMD_FAKE_DIR") || refuse 'fake-dir-unresolvable'
    FM_CODEX_SYSTEMD_FAKE_DIR=$canon
    path_test_owned "$FM_CODEX_SYSTEMD_FAKE_DIR" || refuse 'fake-dir-not-test-owned'
    path_inside "$FM_CODEX_SYSTEMD_FAKE_DIR" "$real_units" && refuse 'fake-dir-inside-real-unit-dir'
  fi
  if [ -n "${FM_CODEX_SYSTEMD_SYSTEMCTL:-}" ]; then
    canon=$(canon_gated_file "$FM_CODEX_SYSTEMD_SYSTEMCTL") || refuse 'stub-systemctl-unresolvable'
    FM_CODEX_SYSTEMD_SYSTEMCTL=$canon
    SYSTEMCTL=$canon
    path_test_owned "$FM_CODEX_SYSTEMD_SYSTEMCTL" || refuse 'stub-systemctl-not-test-owned'
    if [ -z "${FM_CODEX_SYSTEMD_UNIT_DIR:-}" ]; then
      # A stubbed systemctl with the real unit dir would write test units into
      # the real user manager's directory.
      refuse 'stub-systemctl-without-test-unit-dir'
    fi
  fi
  if [ -n "${FM_CODEX_SYSTEMD_UNIT_DIR:-}" ]; then
    canon=$(canon_gated_dir "$FM_CODEX_SYSTEMD_UNIT_DIR") || refuse 'unit-dir-unresolvable'
    FM_CODEX_SYSTEMD_UNIT_DIR=$canon
    path_test_owned "$FM_CODEX_SYSTEMD_UNIT_DIR" || refuse 'unit-dir-not-test-owned'
    path_inside "$FM_CODEX_SYSTEMD_UNIT_DIR" "$real_units" && refuse 'unit-dir-inside-real-unit-dir'
  fi
  GATE_ENGAGED=1
  return 0
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
  elif [ -n "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then
    # Fake mode never touches the real user unit dir, not even in metadata.
    printf '%s/units\n' "$FM_CODEX_SYSTEMD_FAKE_DIR"
  else
    real_default_unit_dir
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

# --- record-field validation (F-4) --------------------------------------------
# Every value below can end up inside a systemd unit file, which is
# line-oriented: an embedded newline terminates the current directive and
# starts an attacker-chosen one (ExecStart injection). Validation is therefore
# charset-allowlisting per field, never quoting alone.

valid_lease() {
  local s=$1
  [ -n "$s" ] || return 1
  [ "${#s}" -le 128 ] || return 1
  case "$s" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

valid_number() {
  local s=$1
  [ -n "$s" ] || return 1
  [ "${#s}" -le 12 ] || return 1
  case "$s" in
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

# Absolute path with no control characters and none of the characters that are
# unsafe inside a quoted systemd value. Spaces are allowed (paths may carry
# them and every path lands quoted); quotes, backslashes, percent specifiers,
# and all non-printables are not.
valid_unit_path() {
  local s=$1 LC_ALL=C
  [ -n "$s" ] || return 1
  case "$s" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$s" in
    *[![:print:]]*|*'"'*|*\\*|*%*) return 1 ;;
  esac
  return 0
}

# The exec path additionally forbids whitespace so the ExecStart line can be
# compared back byte-for-byte against the loaded unit.
valid_exec_path() {
  local s=$1
  valid_unit_path "$s" || return 1
  case "$s" in
    *[[:space:]]*) return 1 ;;
  esac
  return 0
}

systemd_quote() {
  local s=$1 LC_ALL=C
  case "$s" in
    *[![:print:]]*) return 1 ;;
  esac
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//%/%%}
  printf '"%s"' "$s"
}

record_field() {
  jq -r "$1 // empty" "$record" 2>/dev/null
}

# validate_record_fields: shared pre-flight for schedule and validate. Sets
# FIELD_REASON on failure. Reads lease/generation/cadence/due plus the paths
# the record claims, and refuses anything outside the allowlists above.
FIELD_REASON=
validate_record_fields() {
  local lease generation cadence due home state exec_rec
  FIELD_REASON=
  lease=$(record_field '.lease_id')
  generation=$(record_field '.generation')
  cadence=$(record_field '.cadence_seconds')
  due=$(record_field '.next_checkpoint_due')
  home=$(record_field '.fm_home')
  state=$(record_field '.state_dir')
  exec_rec=$(record_field '.scheduler.exec_path')
  valid_lease "$lease" || { FIELD_REASON=bad-lease; return 1; }
  valid_number "$generation" || { FIELD_REASON=bad-generation; return 1; }
  valid_number "$cadence" || { FIELD_REASON=bad-cadence; return 1; }
  [ "$cadence" -gt 0 ] || { FIELD_REASON=bad-cadence; return 1; }
  valid_number "$due" || { FIELD_REASON=bad-due; return 1; }
  valid_unit_path "$home" || { FIELD_REASON=bad-home-path; return 1; }
  valid_unit_path "$state" || { FIELD_REASON=bad-state-path; return 1; }
  valid_exec_path "$exec_rec" || { FIELD_REASON=bad-exec-path; return 1; }
  return 0
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
    jq -cS --argjson meta "$meta" '. + {mode:"fake",registered:(.registered == true),metadata:$meta}' "$file"
  else
    jq -cnS --argjson meta "$meta" '{mode:"fake",registered:false,metadata:$meta,reason:"not-registered"}'
  fi
}

# unit_property <show-output> <name>
unit_property() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# loaded_unit_value <cat-output> <directive>: the value of one directive in the
# LOADED unit content (systemctl cat), first occurrence.
loaded_unit_value() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# --- effective loaded-contract validation (review-r4 F-1) ----------------------
# Expected-line presence alone is never validation authority: a unit can carry
# every expected line and still be overridden by a later directive, a drop-in,
# EnvironmentFile=, or UnsetEnvironment= (systemd.exec(5): a later Environment=
# wins, EnvironmentFile= overrides Environment=, UnsetEnvironment= is a final
# removal). Health therefore requires TWO views to match the contract exactly:
# systemd's merged effective view (systemctl show) catches loaded state that
# diverged from the visible file, and the loaded source (systemctl cat) catches
# duplicate assignments the effective view collapses to a single last value.
# Empirical show formats are recorded in docs/codex-systemd-scheduler.md.

SHOW_PROPS_OUT=
SHOW_PROPS_REASON=
# show_required_props <unit> <prop>...: one systemctl show query whose output
# may contain only requested `Prop=` lines, each at most once. A failed query,
# an unexpected line, or a duplicated property fails closed; a missing line is
# judged per property by the caller (systemd omits some properties when empty).
show_required_props() {
  local unit=$1 out line name p ok seen
  shift
  local args=()
  for p in "$@"; do args+=(-p "$p"); done
  SHOW_PROPS_OUT=
  SHOW_PROPS_REASON=
  out=$("$SYSTEMCTL" --user show "$unit" "${args[@]}" 2>/dev/null) || {
    SHOW_PROPS_REASON='property-query-failed'
    return 1
  }
  seen=' '
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%=*}
    [ "$name" != "$line" ] || { SHOW_PROPS_REASON='property-output-unexpected'; return 1; }
    ok=0
    for p in "$@"; do
      [ "$p" = "$name" ] && { ok=1; break; }
    done
    [ "$ok" -eq 1 ] || { SHOW_PROPS_REASON='property-output-unexpected'; return 1; }
    case "$seen" in
      *" $name "*) SHOW_PROPS_REASON="property-duplicate:$name"; return 1 ;;
    esac
    seen="$seen$name "
  done <<<"$out"
  SHOW_PROPS_OUT=$out
  return 0
}

shown_prop_present() {
  printf '%s\n' "$SHOW_PROPS_OUT" | grep -q "^$1="
}

shown_prop() {
  printf '%s\n' "$SHOW_PROPS_OUT" | sed -n "s/^$1=//p" | head -n 1
}

# parse_env_entries <raw>: split systemd's merged Environment property into one
# NAME=VALUE line per entry. systemd joins entries with single spaces and wraps
# an entry containing spaces in double quotes ("NAME=value with space").
# Expected values are charset-validated to exclude quotes and backslashes, so
# any escape, unterminated quote, empty token, or token without a NAME= shape
# is parser ambiguity and fails closed. Record text never reaches this parser's
# syntax: it splits only systemd's own reported value against a fixed grammar.
parse_env_entries() {
  local rest=$1 entry
  while [ -n "$rest" ]; do
    case "$rest" in
      \"*)
        rest=${rest#\"}
        entry=${rest%%\"*}
        [ "$entry" != "$rest" ] || return 1
        rest=${rest#"$entry"\"}
        case "$rest" in
          '') ;;
          ' '*) rest=${rest#' '} ;;
          *) return 1 ;;
        esac
        ;;
      *)
        entry=${rest%% *}
        if [ "$entry" = "$rest" ]; then rest=; else rest=${rest#"$entry" }; fi
        ;;
    esac
    case "$entry" in
      *\\*|*\"*) return 1 ;;
      *=*) ;;
      *) return 1 ;;
    esac
    case "${entry%%=*}" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    printf '%s\n' "$entry"
  done
  return 0
}

# The exact controlled environment the generated service carries - the single
# reviewed source both validation views compare against.
# FM_CODEX_SYSTEMD_SERVICE=1 (review-r5 F-1) marks the managed service run so
# bin/fm-watch-checkpoint.sh establishes its deterministic clean process
# environment before reading any configuration; a user service inherits the
# user manager's environment, which no unit-file validation can bound.
expected_env_entries() {  # <home> <state> <lease> <generation> <cadence>
  printf 'FM_HOME=%s\n' "$1"
  printf 'FM_STATE_OVERRIDE=%s\n' "$2"
  printf 'FM_SUPERVISION_HARNESS=codex\n'
  printf 'FM_CODEX_SYSTEMD_SERVICE=1\n'
  printf 'FM_CODEX_SYSTEMD_LEASE=%s\n' "$3"
  printf 'FM_CODEX_SYSTEMD_GENERATION=%s\n' "$4"
  printf 'FM_CODEX_WATCH_CHECKPOINT=%s\n' "$5"
}

env_mismatch_reason() {
  case "$1" in
    FM_HOME) printf 'home-env-mismatch' ;;
    FM_STATE_OVERRIDE) printf 'state-env-mismatch' ;;
    FM_SUPERVISION_HARNESS) printf 'harness-env-mismatch' ;;
    FM_CODEX_SYSTEMD_SERVICE) printf 'service-marker-mismatch' ;;
    FM_CODEX_SYSTEMD_LEASE) printf 'lease-mismatch' ;;
    FM_CODEX_SYSTEMD_GENERATION) printf 'generation-mismatch' ;;
    FM_CODEX_WATCH_CHECKPOINT) printf 'cadence-mismatch' ;;
    *) printf 'env-value-mismatch:%s' "$1" ;;
  esac
}

# --- fixed clean checkpoint launcher (review-r6-sol F-2) -----------------------
# A user service inherits the user manager's whole environment underneath its
# unit Environment= lines (systemd.exec(5)), so the checkpoint's actual process
# environment can only be bounded by the launch itself. The generated ExecStart
# is therefore a CLEAN LAUNCH: a fixed trusted absolute environment executable
# with ignore-environment semantics rebuilds the checkpoint's entire
# environment from the reviewed allowlist below, before any behaviorally
# relevant interpreter or program runs. Only reviewed constants and
# adapter-validated fields appear in the argv. The in-script FM_* scrub in
# bin/fm-watch-checkpoint.sh remains behind this boundary as defense in depth,
# not as the boundary.
LAUNCHER_ENV_EXEC=/usr/bin/env
LAUNCHER_CLEAN_FLAG=-i
LAUNCHER_INTERP=/bin/bash
# The minimal safe runtime values the checkpoint needs to find standard tools
# and reach the user manager: a fixed system PATH, the account database's home,
# and the conventional /run/user/<uid> runtime dir and session bus address the
# user manager serves (empirically confirmed against the real manager's own
# environment block; docs/codex-systemd-scheduler.md).
LAUNCHER_SAFE_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

# account_home_dir: the account's home directory from the account database,
# never ambient $HOME, validated launcher-argv safe (absolute, no whitespace,
# no unit-unsafe characters).
account_home_dir() {
  local d
  d=$(getent passwd "$(id -u)" 2>/dev/null | head -n 1 | cut -d: -f6)
  valid_exec_path "$d" || return 1
  printf '%s\n' "$d"
}

# expected_launcher_argv <home> <state> <lease> <generation> <cadence>
# <exec-path> <home-dir> <uid>: one argv element per line - the single
# reviewed source every launcher validation view compares against. Every value
# is whitespace-free by validation, so the space-joined ExecStart line and the
# argv are byte-equivalent representations.
expected_launcher_argv() {
  printf '%s\n' "$LAUNCHER_ENV_EXEC"
  printf '%s\n' "$LAUNCHER_CLEAN_FLAG"
  printf 'HOME=%s\n' "$7"
  printf 'PATH=%s\n' "$LAUNCHER_SAFE_PATH"
  printf 'XDG_RUNTIME_DIR=/run/user/%s\n' "$8"
  printf 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus\n' "$8"
  expected_env_entries "$1" "$2" "$3" "$4" "$5"
  printf '%s\n' "$LAUNCHER_INTERP"
  printf '%s\n' "$6"
  printf -- '--seconds\n'
  printf '%s\n' "$5"
}

expected_execstart_line() {  # same arguments as expected_launcher_argv
  local line='' tok
  while IFS= read -r tok; do
    line="$line$tok "
  done < <(expected_launcher_argv "$@")
  printf '%s\n' "${line% }"
}

is_env_assignment() {  # <token>: NAME=VALUE with a plain variable name
  local tok=$1 name
  case "$tok" in
    *=*) ;;
    *) return 1 ;;
  esac
  name=${tok%%=*}
  case "$name" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# classify_launcher_argv <actual-line> <expected-line>: name which part of the
# clean-launcher command diverged, appended to CONTRACT_REASONS. Tokens are
# whitespace-free by construction, so word splitting is exact. Reason names
# only ever carry validated variable names, never raw token text.
classify_launcher_argv() {
  local actual=$1 expected=$2 i tok name exp_line seen in_cmd
  local -a a e
  local act_env='' exp_env='' act_cmd='' exp_cmd=''
  read -r -a a <<<"$actual"
  read -r -a e <<<"$expected"
  [ "${a[0]:-}" = "${e[0]:-}" ] || CONTRACT_REASONS="$CONTRACT_REASONS exec-launcher-mismatch"
  [ "${a[1]:-}" = "${e[1]:-}" ] || CONTRACT_REASONS="$CONTRACT_REASONS exec-clean-flag-missing"
  in_cmd=0
  for ((i = 2; i < ${#a[@]}; i++)); do
    tok=${a[i]}
    if [ "$in_cmd" -eq 0 ] && is_env_assignment "$tok"; then
      act_env="$act_env$tok"$'\n'
    else
      in_cmd=1
      act_cmd="$act_cmd$tok "
    fi
  done
  in_cmd=0
  for ((i = 2; i < ${#e[@]}; i++)); do
    tok=${e[i]}
    if [ "$in_cmd" -eq 0 ] && is_env_assignment "$tok"; then
      exp_env="$exp_env$tok"$'\n'
    else
      in_cmd=1
      exp_cmd="$exp_cmd$tok "
    fi
  done
  seen=' '
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    name=${tok%%=*}
    case "$seen" in
      *" $name "*) CONTRACT_REASONS="$CONTRACT_REASONS launcher-env-duplicate:$name"; continue ;;
    esac
    seen="$seen$name "
    if ! exp_line=$(printf '%s' "$exp_env" | grep -m 1 "^$name="); then
      CONTRACT_REASONS="$CONTRACT_REASONS launcher-env-unexpected:$name"
      continue
    fi
    [ "$tok" = "$exp_line" ] || CONTRACT_REASONS="$CONTRACT_REASONS launcher-env-mismatch:$name"
  done <<<"$act_env"
  while IFS= read -r exp_line; do
    [ -n "$exp_line" ] || continue
    name=${exp_line%%=*}
    case "$seen" in
      *" $name "*) ;;
      *) CONTRACT_REASONS="$CONTRACT_REASONS launcher-env-missing:$name" ;;
    esac
  done <<<"$exp_env"
  [ "$act_cmd" = "$exp_cmd" ] || CONTRACT_REASONS="$CONTRACT_REASONS exec-command-mismatch"
}

# classify_exec_effective <exec-show-block> <expected-line>: applied when the
# effective ExecStart block did not match exactly; guarantees at least one
# deterministic reason lands.
classify_exec_effective() {
  local shown=$1 expected_line=$2 argv_str before=$CONTRACT_REASONS
  argv_str=${shown#*"argv[]="}
  if [ "$argv_str" = "$shown" ]; then
    CONTRACT_REASONS="$CONTRACT_REASONS exec-effective-mismatch"
    return 0
  fi
  argv_str=${argv_str%% ; ignore_errors=*}
  classify_launcher_argv "$argv_str" "$expected_line"
  [ "$CONTRACT_REASONS" != "$before" ] || CONTRACT_REASONS="$CONTRACT_REASONS exec-effective-mismatch"
}

CONTRACT_REASONS=
# validate_effective_service <service> <service-path> <home> <state> <lease>
# <generation> <cadence> <exec-path>: the merged contract systemd will actually
# execute, appended to CONTRACT_REASONS (each reason carries a leading space).
validate_effective_service() {
  local service=$1 service_path=$2 canon_home=$3 canon_state=$4 lease=$5 generation=$6 cadence=$7 exec_path=$8
  local p entries entry name exp_line seen expected env_raw exec_show argv_count home_dir expected_exec
  CONTRACT_REASONS=
  home_dir=$(account_home_dir) || {
    CONTRACT_REASONS=' launcher-home-dir-underivable'
    return 1
  }
  expected_exec=$(expected_execstart_line "$canon_home" "$canon_state" "$lease" "$generation" "$cadence" "$exec_path" "$home_dir" "$(id -u)")
  if ! show_required_props "$service" FragmentPath DropInPaths WorkingDirectory Environment EnvironmentFiles UnsetEnvironment PassEnvironment ExecStart; then
    CONTRACT_REASONS=" service-$SHOW_PROPS_REASON"
    return 1
  fi
  # systemd prints these even when empty, so a missing line means the query did
  # not answer this property and fails closed. EnvironmentFiles and ExecStart
  # are omitted when empty, so absence there means none are loaded.
  for p in FragmentPath DropInPaths WorkingDirectory Environment UnsetEnvironment PassEnvironment; do
    if ! shown_prop_present "$p"; then
      CONTRACT_REASONS=" service-property-missing:$p"
      return 1
    fi
  done
  [ "$(shown_prop FragmentPath)" = "$service_path" ] || CONTRACT_REASONS="$CONTRACT_REASONS service-fragment-mismatch"
  [ -z "$(shown_prop DropInPaths)" ] || CONTRACT_REASONS="$CONTRACT_REASONS service-drop-in"
  [ "$(shown_prop WorkingDirectory)" = "$canon_home" ] || CONTRACT_REASONS="$CONTRACT_REASONS workdir-mismatch"
  [ -z "$(shown_prop EnvironmentFiles)" ] || CONTRACT_REASONS="$CONTRACT_REASONS environment-file-present"
  [ -z "$(shown_prop UnsetEnvironment)" ] || CONTRACT_REASONS="$CONTRACT_REASONS unset-environment-present"
  [ -z "$(shown_prop PassEnvironment)" ] || CONTRACT_REASONS="$CONTRACT_REASONS pass-environment-present"
  exec_show=$(shown_prop ExecStart)
  case "$exec_show" in
    "{ path=$LAUNCHER_ENV_EXEC ; argv[]=$expected_exec ; ignore_errors="*) ;;
    *) classify_exec_effective "$exec_show" "$expected_exec" ;;
  esac
  argv_count=$(printf '%s\n' "$exec_show" | grep -o 'argv\[\]=' | wc -l)
  [ "$argv_count" -eq 1 ] || CONTRACT_REASONS="$CONTRACT_REASONS exec-effective-count"
  env_raw=$(shown_prop Environment)
  if ! entries=$(parse_env_entries "$env_raw"); then
    CONTRACT_REASONS="$CONTRACT_REASONS environment-parse-ambiguous"
    return 1
  fi
  expected=$(expected_env_entries "$canon_home" "$canon_state" "$lease" "$generation" "$cadence")
  seen=' '
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name=${entry%%=*}
    case "$seen" in
      *" $name "*) CONTRACT_REASONS="$CONTRACT_REASONS env-duplicate:$name"; continue ;;
    esac
    seen="$seen$name "
    if ! exp_line=$(printf '%s\n' "$expected" | grep -m 1 "^$name="); then
      CONTRACT_REASONS="$CONTRACT_REASONS env-unexpected:$name"
      continue
    fi
    [ "$entry" = "$exp_line" ] || CONTRACT_REASONS="$CONTRACT_REASONS $(env_mismatch_reason "$name")"
  done <<<"$entries"
  while IFS= read -r exp_line; do
    name=${exp_line%%=*}
    case "$seen" in
      *" $name "*) ;;
      *) CONTRACT_REASONS="$CONTRACT_REASONS env-missing:$name" ;;
    esac
  done <<<"$expected"
  [ -z "$CONTRACT_REASONS" ]
}

# validate_effective_timer <timer> <timer-path>
validate_effective_timer() {
  local timer=$1 timer_path=$2 p
  CONTRACT_REASONS=
  if ! show_required_props "$timer" FragmentPath DropInPaths; then
    CONTRACT_REASONS=" timer-$SHOW_PROPS_REASON"
    return 1
  fi
  for p in FragmentPath DropInPaths; do
    if ! shown_prop_present "$p"; then
      CONTRACT_REASONS=" timer-property-missing:$p"
      return 1
    fi
  done
  [ "$(shown_prop FragmentPath)" = "$timer_path" ] || CONTRACT_REASONS="$CONTRACT_REASONS timer-fragment-mismatch"
  [ -z "$(shown_prop DropInPaths)" ] || CONTRACT_REASONS="$CONTRACT_REASONS timer-drop-in"
  [ -z "$CONTRACT_REASONS" ]
}

# validate_source_contract <service-cat> <home> <state> <lease> <generation>
# <cadence>: the loaded on-disk source as an exact allowlist. The effective
# view above collapses a repeated assignment to its last value, so same-value
# and conflicting duplicates are caught here by per-variable assignment counts.
validate_source_contract() {
  local cat_out=$1 canon_home=$2 canon_state=$3 lease=$4 generation=$5 cadence=$6
  local total name value exp_line prefix_count exact_count wd_count
  CONTRACT_REASONS=
  printf '%s\n' "$cat_out" | grep -q '^EnvironmentFile=' && CONTRACT_REASONS="$CONTRACT_REASONS source-environment-file"
  printf '%s\n' "$cat_out" | grep -q '^UnsetEnvironment=' && CONTRACT_REASONS="$CONTRACT_REASONS source-unset-environment"
  printf '%s\n' "$cat_out" | grep -q '^PassEnvironment=' && CONTRACT_REASONS="$CONTRACT_REASONS source-pass-environment"
  total=$(printf '%s\n' "$cat_out" | grep -c '^Environment=')
  [ "$total" -eq 7 ] || CONTRACT_REASONS="$CONTRACT_REASONS env-line-count-mismatch"
  while IFS= read -r exp_line; do
    name=${exp_line%%=*}
    value=${exp_line#*=}
    prefix_count=$(printf '%s\n' "$cat_out" | grep -cE "^Environment=\"?$name=")
    exact_count=$(printf '%s\n' "$cat_out" | grep -cFx "Environment=$(systemd_quote "$name=$value")")
    if [ "$prefix_count" -gt 1 ]; then
      CONTRACT_REASONS="$CONTRACT_REASONS env-duplicate:$name"
    elif [ "$exact_count" -ne 1 ]; then
      CONTRACT_REASONS="$CONTRACT_REASONS $(env_mismatch_reason "$name")"
    fi
  done <<<"$(expected_env_entries "$canon_home" "$canon_state" "$lease" "$generation" "$cadence")"
  wd_count=$(printf '%s\n' "$cat_out" | grep -c '^WorkingDirectory=')
  [ "$wd_count" -eq 1 ] || CONTRACT_REASONS="$CONTRACT_REASONS workdir-line-count-mismatch"
  printf '%s\n' "$cat_out" | grep -qFx "WorkingDirectory=$canon_home" || CONTRACT_REASONS="$CONTRACT_REASONS workdir-source-mismatch"
  [ -z "$CONTRACT_REASONS" ]
}

status_json_real() {
  local meta timer service timer_show service_show timer_load timer_active timer_unit_file triggers
  local service_load service_active service_cat timer_cat exec_start on_calendar next realtime exec_count
  meta=$(metadata_json) || return 1
  timer=$(printf '%s' "$meta" | jq -r '.timer_name')
  service=$(printf '%s' "$meta" | jq -r '.service_name')
  timer_show=$("$SYSTEMCTL" --user show "$timer" \
    -p LoadState -p ActiveState -p UnitFileState -p FragmentPath -p Triggers -p NextElapseUSecRealtime 2>/dev/null || true)
  service_show=$("$SYSTEMCTL" --user show "$service" \
    -p LoadState -p ActiveState -p UnitFileState -p FragmentPath 2>/dev/null || true)
  timer_load=$(unit_property "$timer_show" LoadState)
  timer_active=$(unit_property "$timer_show" ActiveState)
  timer_unit_file=$(unit_property "$timer_show" UnitFileState)
  triggers=$(unit_property "$timer_show" Triggers)
  service_load=$(unit_property "$service_show" LoadState)
  service_active=$(unit_property "$service_show" ActiveState)
  realtime=$(unit_property "$timer_show" NextElapseUSecRealtime)
  # The LOADED contract, read back from systemd itself - never only from the
  # file this adapter wrote (F-3).
  service_cat=$("$SYSTEMCTL" --user cat "$service" 2>/dev/null || true)
  timer_cat=$("$SYSTEMCTL" --user cat "$timer" 2>/dev/null || true)
  exec_start=$(loaded_unit_value "$service_cat" ExecStart)
  exec_count=$(printf '%s\n' "$service_cat" | grep -c '^ExecStart=' 2>/dev/null || true)
  on_calendar=$(loaded_unit_value "$timer_cat" OnCalendar)
  next=
  if [ -n "$realtime" ] && command -v date >/dev/null 2>&1; then
    next=$(date -d "$realtime" +%s 2>/dev/null || true)
  fi
  jq -cnS \
    --argjson meta "$meta" \
    --arg timer_load "${timer_load:-not-found}" \
    --arg timer_active "${timer_active:-inactive}" \
    --arg timer_unit_file "${timer_unit_file:-unknown}" \
    --arg triggers "${triggers:-}" \
    --arg service_load "${service_load:-not-found}" \
    --arg service_active "${service_active:-inactive}" \
    --arg exec_start "${exec_start:-}" \
    --argjson exec_count "${exec_count:-0}" \
    --arg on_calendar "${on_calendar:-}" \
    --arg next_raw "$realtime" \
    --arg next_epoch "$next" \
    '{mode:"systemd",registered:($timer_load == "loaded"),metadata:$meta,
      timer:{load:$timer_load,active:$timer_active,unit_file:$timer_unit_file,
             triggers:$triggers,on_calendar:$on_calendar,next_raw:$next_raw,next_epoch:$next_epoch},
      service:{load:$service_load,active:$service_active,exec_start:$exec_start,exec_count:$exec_count}}'
}

validate_record() {
  local status meta adapter uid expected_uid lease generation cadence due exec_rec home state reasons
  local timer_active timer_load timer_unit_file service_load triggers exec_start exec_count on_calendar next_epoch
  local expected_service expected_timer expected_exec_line expected_calendar service_cat timer_cat tolerance diff f
  local canon_home canon_state service_path timer_path_meta exec_path_meta home_dir
  [ -n "$record" ] && [ -f "$record" ] || { printf 'missing-record\n'; return 1; }
  jq -e 'type == "object"' "$record" >/dev/null 2>&1 || { printf 'malformed-record\n'; return 1; }
  if ! validate_record_fields; then
    [ "$json" -eq 1 ] && printf '{"ok":false,"reason":"%s"}\n' "$FIELD_REASON"
    [ "$json" -eq 1 ] || printf '%s\n' "$FIELD_REASON"
    return 1
  fi
  status=$("$SCRIPT_SELF" status --home "$FM_HOME" --state "$STATE" --json) || { printf 'scheduler-status-failed\n'; return 1; }
  meta=$(metadata_json) || { printf 'metadata-failed\n'; return 1; }
  adapter=$(record_field '.scheduler.adapter')
  uid=$(record_field '.scheduler.uid')
  expected_uid=$(id -u)
  lease=$(record_field '.lease_id')
  generation=$(record_field '.generation')
  cadence=$(record_field '.cadence_seconds')
  due=$(record_field '.next_checkpoint_due')
  exec_rec=$(record_field '.scheduler.exec_path')
  home=$(record_field '.fm_home')
  state=$(record_field '.state_dir')
  reasons=
  [ "$adapter" = systemd-user-timer ] || reasons="${reasons} adapter-mismatch"
  [ "$uid" = "$expected_uid" ] || reasons="${reasons} uid-mismatch"
  [ "$exec_rec" = "$(printf '%s' "$meta" | jq -r '.exec_path')" ] || reasons="${reasons} exec-mismatch"
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
    timer_load=$(printf '%s' "$status" | jq -r '.timer.load // empty')
    timer_active=$(printf '%s' "$status" | jq -r '.timer.active // empty')
    timer_unit_file=$(printf '%s' "$status" | jq -r '.timer.unit_file // empty')
    triggers=$(printf '%s' "$status" | jq -r '.timer.triggers // empty')
    on_calendar=$(printf '%s' "$status" | jq -r '.timer.on_calendar // empty')
    next_epoch=$(printf '%s' "$status" | jq -r '.timer.next_epoch // empty')
    service_load=$(printf '%s' "$status" | jq -r '.service.load // empty')
    exec_start=$(printf '%s' "$status" | jq -r '.service.exec_start // empty')
    exec_count=$(printf '%s' "$status" | jq -r '.service.exec_count // 0')
    expected_service=$(printf '%s' "$meta" | jq -r '.service_name')
    expected_timer=$(printf '%s' "$meta" | jq -r '.timer_name')
    service_path=$(printf '%s' "$meta" | jq -r '.service_path')
    timer_path_meta=$(printf '%s' "$meta" | jq -r '.timer_path')
    exec_path_meta=$(printf '%s' "$meta" | jq -r '.exec_path')
    canon_home=$(printf '%s' "$meta" | jq -r '.fm_home')
    canon_state=$(printf '%s' "$meta" | jq -r '.state_dir')
    [ "$timer_load" = loaded ] || reasons="${reasons} timer-not-registered"
    [ "$timer_active" = active ] || reasons="${reasons} timer-not-active"
    [ "$timer_unit_file" = enabled ] || reasons="${reasons} timer-not-enabled"
    [ "$service_load" = loaded ] || reasons="${reasons} service-not-loaded"
    [ "$triggers" = "$expected_service" ] || reasons="${reasons} trigger-mismatch"
    # The service command systemd will actually run, compared byte-for-byte
    # against the clean-launcher line this adapter constructs from reviewed
    # constants plus its own metadata (F-3, review-r6-sol F-2).
    if home_dir=$(account_home_dir); then
      expected_exec_line=$(expected_execstart_line "$canon_home" "$canon_state" "$lease" "$generation" "$cadence" "$exec_path_meta" "$home_dir" "$expected_uid")
      [ "$exec_start" = "$expected_exec_line" ] || reasons="${reasons} exec-start-mismatch"
    else
      reasons="${reasons} launcher-home-dir-underivable"
    fi
    [ "$exec_count" = 1 ] || reasons="${reasons} exec-start-duplicated"
    # The full loaded contract (review-r4 F-1): systemd's merged effective view
    # plus the loaded source, both matched exactly. A unit that is not even
    # loaded is already red above, so the contract checks run on loaded units.
    if [ "$service_load" = loaded ]; then
      validate_effective_service "$expected_service" "$service_path" "$canon_home" "$canon_state" "$lease" "$generation" "$cadence" "$exec_path_meta" || true
      reasons="${reasons}${CONTRACT_REASONS}"
      if service_cat=$("$SYSTEMCTL" --user cat "$expected_service" 2>/dev/null); then
        validate_source_contract "$service_cat" "$canon_home" "$canon_state" "$lease" "$generation" "$cadence" || true
        reasons="${reasons}${CONTRACT_REASONS}"
      else
        reasons="${reasons} service-source-unreadable"
      fi
    fi
    if [ "$timer_load" = loaded ]; then
      validate_effective_timer "$expected_timer" "$timer_path_meta" || true
      reasons="${reasons}${CONTRACT_REASONS}"
      if timer_cat=$("$SYSTEMCTL" --user cat "$expected_timer" 2>/dev/null); then
        [ "$(printf '%s\n' "$timer_cat" | grep -c '^OnCalendar=')" -eq 1 ] || reasons="${reasons} calendar-line-count-mismatch"
      else
        reasons="${reasons} timer-source-unreadable"
      fi
    fi
    # The timer's real next trigger, compared against the record's due time.
    expected_calendar=$(date -u -d "@$due" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || true)
    [ -n "$expected_calendar" ] && [ "$on_calendar" = "$expected_calendar" ] || reasons="${reasons} calendar-mismatch"
    if [ -n "$next_epoch" ]; then
      tolerance=60
      diff=$((next_epoch - due))
      [ "$diff" -lt 0 ] && diff=$((-diff))
      [ "$diff" -le "$tolerance" ] || reasons="${reasons} next-elapse-mismatch"
    fi
    # Exactly one unit pair may claim this home (duplicate detection).
    for f in "$(printf '%s' "$meta" | jq -r '.unit_dir')"/fm-codex-checkpoint-*.service; do
      [ -e "$f" ] || continue
      [ "$f" = "$service_path" ] && continue
      if grep -Fx "Environment=$(systemd_quote "FM_HOME=$canon_home")" "$f" >/dev/null 2>&1; then
        reasons="${reasons} duplicate-unit"
        break
      fi
    done
  fi
  if [ -n "$reasons" ]; then
    reasons=${reasons# }
    [ "$json" -eq 1 ] && jq -cnS --arg reason "$reasons" --argjson status "$status" '{ok:false,reason:$reason,status:$status}'
    [ "$json" -eq 1 ] || printf '%s\n' "$reasons"
    return 1
  fi
  [ "$json" -eq 1 ] && jq -cnS --argjson status "$status" '{ok:true,reason:"valid",status:$status}'
  [ "$json" -eq 1 ] || printf 'valid\n'
  return 0
}

schedule_fake() {
  local root file meta recheck
  root=$(fake_root)
  file=$(fake_registration)
  meta=$(metadata_json) || return 1
  validate_record_fields || { echo "error: $FIELD_REASON" >&2; return 1; }
  mkdir -p "$root/timers" || return 1
  # Race-safe creation (review-r6-sol F-1): fake mode is always gated, so the
  # created registration dir must still be the judged canonical test-owned path.
  if ! recheck=$(canon_gated_dir "$root/timers") || [ "$recheck" != "$root/timers" ] || ! path_test_owned "$recheck"; then
    echo "error: fake-dir-changed-after-create" >&2
    return 1
  fi
  ( umask 077
    jq -cS --argjson meta "$meta" \
      '{registered:true,lease_id:.lease_id,generation:.generation,cadence_seconds:.cadence_seconds,
        next_checkpoint_due:.next_checkpoint_due,previous_result:.previous_result,
        fm_home:.fm_home,state_dir:.state_dir,harness:.harness,metadata:$meta}' "$record" > "$file.tmp.$$"
  ) || { rm -f "$file.tmp.$$"; return 1; }
  mv -f "$file.tmp.$$" "$file"
}

disable_scheduler() {
  local meta timer file
  if [ "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then
    file=$(fake_registration)
    [ -f "$file" ] || return 0
    jq -cS '.registered=false | .disabled=true' "$file" > "$file.tmp.$$" || return 1
    mv -f "$file.tmp.$$" "$file"
    return 0
  fi
  meta=$(metadata_json) || return 1
  timer=$(printf '%s' "$meta" | jq -r '.timer_name')
  "$SYSTEMCTL" --user disable --now "$timer" >/dev/null 2>&1 || true
  "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1 || true
}

schedule_real() {
  local meta dir service_path timer_path exec_path canon_home canon_state lease generation cadence due calendar
  local home_dir exec_line recheck
  meta=$(metadata_json) || return 1
  validate_record_fields || { echo "error: $FIELD_REASON" >&2; return 1; }
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
  # The command line is constructed only from this adapter's own computed
  # metadata, the reviewed launcher constants, and the numeric cadence
  # validated above; record text never reaches ExecStart unvalidated (F-4).
  # Every ExecStart value must additionally be whitespace-free so the launcher
  # argv and its space-joined line are byte-equivalent (review-r6-sol F-2).
  valid_exec_path "$exec_path" || { echo "error: computed exec path is not unit-safe: $exec_path" >&2; return 1; }
  valid_exec_path "$canon_home" || { echo "error: computed home path is not launcher-safe" >&2; return 1; }
  valid_exec_path "$canon_state" || { echo "error: computed state path is not launcher-safe" >&2; return 1; }
  [ -x "$LAUNCHER_ENV_EXEC" ] || { echo "error: fixed environment executable missing: $LAUNCHER_ENV_EXEC" >&2; return 1; }
  [ -x "$LAUNCHER_INTERP" ] || { echo "error: fixed interpreter missing: $LAUNCHER_INTERP" >&2; return 1; }
  home_dir=$(account_home_dir) || { echo "error: account home directory is not launcher-safe" >&2; return 1; }
  exec_line=$(expected_execstart_line "$canon_home" "$canon_state" "$lease" "$generation" "$cadence" "$exec_path" "$home_dir" "$(id -u)")
  # The record must describe THIS home's contract, not another home's.
  [ "$(record_field '.fm_home')" = "$canon_home" ] || { echo "error: record home does not match this home" >&2; return 1; }
  [ "$(record_field '.state_dir')" = "$canon_state" ] || { echo "error: record state dir does not match this home" >&2; return 1; }
  [ "$(record_field '.scheduler.exec_path')" = "$exec_path" ] || { echo "error: record exec path does not match this adapter" >&2; return 1; }
  calendar=$(date -u -d "@$due" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null) || return 1
  mkdir -p "$dir" || return 1
  # Race-safe creation for a gated unit dir (review-r6-sol F-1): the gate
  # judged the canonical path, so the created path must still BE that judged
  # canonical path before anything is written through it.
  if [ "$GATE_ENGAGED" -eq 1 ]; then
    if ! recheck=$(canon_gated_dir "$dir") || [ "$recheck" != "$dir" ] || ! path_test_owned "$recheck"; then
      echo "error: unit-dir-changed-after-create" >&2
      return 1
    fi
  fi
  ( umask 077
    {
      printf '[Unit]\nDescription=FirstMate Codex checkpoint for %s\n\n' "$canon_home"
      # WorkingDirectory is a PATH directive: systemd takes the raw value after
      # '=' and does no quote-unescaping, so quoting it makes the unit fatally
      # invalid ("path is not absolute"). The path is charset-validated above;
      # write it raw. (Found by the disposable real-systemd proof - the quoted
      # form armed nothing, ever.)
      printf '[Service]\nType=oneshot\nWorkingDirectory=%s\n' "$canon_home"
      # The Environment= lines remain the validated unit-level declaration of
      # the supervision binding (review-r4); the clean-launcher ExecStart below
      # is what actually bounds the checkpoint's process environment, because
      # its ignore-environment launch discards everything inherited from the
      # user manager, unit assignments included (review-r6-sol F-2).
      printf 'Environment=%s\n' "$(systemd_quote "FM_HOME=$canon_home")"
      printf 'Environment=%s\n' "$(systemd_quote "FM_STATE_OVERRIDE=$canon_state")"
      printf 'Environment=%s\n' "$(systemd_quote 'FM_SUPERVISION_HARNESS=codex')"
      printf 'Environment=%s\n' "$(systemd_quote 'FM_CODEX_SYSTEMD_SERVICE=1')"
      printf 'Environment=%s\n' "$(systemd_quote "FM_CODEX_SYSTEMD_LEASE=$lease")"
      printf 'Environment=%s\n' "$(systemd_quote "FM_CODEX_SYSTEMD_GENERATION=$generation")"
      printf 'Environment=%s\n' "$(systemd_quote "FM_CODEX_WATCH_CHECKPOINT=$cadence")"
      printf 'ExecStart=%s\n' "$exec_line"
    } > "$service_path.tmp.$$"
  ) || { rm -f "$service_path.tmp.$$"; return 1; }
  chmod 600 "$service_path.tmp.$$" 2>/dev/null || { rm -f "$service_path.tmp.$$"; return 1; }
  mv -f "$service_path.tmp.$$" "$service_path" || return 1
  ( umask 077
    {
      printf '[Unit]\nDescription=FirstMate Codex next checkpoint timer for %s\n\n' "$canon_home"
      printf '[Timer]\nOnCalendar=%s\nAccuracySec=1s\nPersistent=true\nUnit=%s\n\n' "$calendar" "$(printf '%s' "$meta" | jq -r '.service_name')"
      printf '[Install]\nWantedBy=timers.target\n'
    } > "$timer_path.tmp.$$"
  ) || { rm -f "$timer_path.tmp.$$"; return 1; }
  chmod 600 "$timer_path.tmp.$$" 2>/dev/null || { rm -f "$timer_path.tmp.$$"; return 1; }
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
test_seam_gate

case "$cmd" in
  unit-metadata)
    metadata_json
    ;;
  status|query)
    if [ "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then status_json_fake; else status_json_real; fi
    ;;
  validate)
    validate_record
    ;;
  install|register|arm|schedule|controlled-replacement)
    [ -n "$record" ] && [ -f "$record" ] || { echo "error: --record FILE is required" >&2; exit 2; }
    if [ "${FM_CODEX_SYSTEMD_FAKE_DIR:-}" ]; then schedule_fake; else schedule_real; fi
    ;;
  disable)
    disable_scheduler
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
