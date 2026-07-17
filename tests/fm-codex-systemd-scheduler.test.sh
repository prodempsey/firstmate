#!/usr/bin/env bash
# Tests for the Codex systemd user scheduler adapter: the fail-closed test-seam
# gate, fake-mode lifecycle, and the shipping real-mode branch driven through a
# stub systemctl with a scratch unit directory (never the real user manager).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCHED="$ROOT/bin/fm-codex-systemd-scheduler.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-systemd-scheduler)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

# fake_env <home> <cmd...>: run under the gated fake-mode test seam.
fake_env() {
  local home=$1
  shift
  FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$@"
}

# write_stub_systemctl <home>: install a deterministic systemctl stub that
# serves unit state from <home>/units and marker files from <home>/stub-state.
# It emulates systemd's EFFECTIVE property semantics the shipping validation
# depends on: `show -p Environment` reports the merged environment (a repeated
# assignment keeps only its last value, entries with spaces are whole-entry
# quoted), EnvironmentFiles/ExecStart lines are omitted when empty, drop-ins
# under <unit>.d/ are listed in DropInPaths and appended to `cat` output, and
# ExecStart uses the `{ path=... ; argv[]=... ; ignore_errors=... }` block.
# Attack seams: stub-state/override-<unit>-<prop> replaces one effective
# property (loaded state diverging from the visible source),
# stub-state/omit-<unit>-<prop> drops the property line (unsupported query),
# stub-state/fail-show-<unit> makes every show query for the unit fail, and
# stub-state/fail-show-contract-<unit> fails only the deep contract query.
write_stub_systemctl() {
  local home=$1 stub="$1/systemctl-stub"
  mkdir -p "$home/units" "$home/stub-state"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
set -u
UNITS=${STUB_UNITS:?}
MARKS=${STUB_MARKS:?}
[ "${1:-}" = --user ] && shift
cmd=${1:-}
shift || true
unit_file() { printf '%s/%s' "$UNITS" "$1"; }
unit_sources() {  # fragment then drop-ins, systemd load order
  local f=$1 d
  [ -f "$f" ] && printf '%s\n' "$f"
  for d in "$f.d"/*.conf; do
    [ -f "$d" ] && printf '%s\n' "$d"
  done
  return 0
}
directive_values() {  # <unit-file> <directive>: every value across sources
  local f=$1 directive=$2 src
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    sed -n "s/^$directive=//p" "$src"
  done < <(unit_sources "$f")
}
strip_entry_quotes() {
  local v=$1
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
  esac
  printf '%s' "$v"
}
merged_env() {  # last assignment wins, first-seen order, systemd-style quoting
  local f=$1 raw entry name out='' n
  declare -A env=()
  local order=()
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    entry=$(strip_entry_quotes "$raw")
    name=${entry%%=*}
    [ -n "${env[$name]+x}" ] || order+=("$name")
    env[$name]=${entry#*=}
  done < <(directive_values "$f" Environment)
  [ "${#order[@]}" -gt 0 ] || { printf ''; return 0; }
  for n in "${order[@]}"; do
    entry="$n=${env[$n]}"
    case "$entry" in
      *' '*) entry="\"$entry\"" ;;
    esac
    out="$out$entry "
  done
  printf '%s' "${out% }"
}
env_files() {
  local f=$1 raw out=''
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    case "$raw" in
      -*) out="$out${raw#-} (ignore_errors=yes) " ;;
      *) out="$out$raw (ignore_errors=no) " ;;
    esac
  done < <(directive_values "$f" EnvironmentFile)
  printf '%s' "${out% }"
}
list_values() {  # <unit-file> <directive>: space-joined merged list
  local f=$1 directive=$2 raw out=''
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    out="$out$raw "
  done < <(directive_values "$f" "$directive")
  printf '%s' "${out% }"
}
exec_blocks() {
  local f=$1 cmdline first out=''
  while IFS= read -r cmdline; do
    [ -n "$cmdline" ] || continue
    first=${cmdline%% *}
    out="$out{ path=$first ; argv[]=$cmdline ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 } "
  done < <(directive_values "$f" ExecStart)
  printf '%s' "${out% }"
}
drop_in_paths() {
  local f=$1 d out=''
  for d in "$f.d"/*.conf; do
    [ -f "$d" ] && out="$out$d "
  done
  printf '%s' "${out% }"
}
prop_value() {
  local unit=$1 prop=$2 f override
  override="$MARKS/override-$unit-$prop"
  if [ -f "$override" ]; then cat "$override"; return 0; fi
  f=$(unit_file "$unit")
  case "$prop" in
    LoadState) if [ -f "$f" ]; then printf 'loaded'; else printf 'not-found'; fi ;;
    ActiveState) if [ -f "$MARKS/active-$unit" ]; then printf 'active'; else printf 'inactive'; fi ;;
    UnitFileState) if [ -f "$MARKS/enabled-$unit" ]; then printf 'enabled'; else printf 'disabled'; fi ;;
    FragmentPath) printf '%s' "$f" ;;
    DropInPaths) drop_in_paths "$f" ;;
    Triggers) sed -n 's/^Unit=//p' "$f" 2>/dev/null | head -n 1 | tr -d '\n' ;;
    NextElapseUSecRealtime) sed -n 's/^OnCalendar=//p' "$f" 2>/dev/null | head -n 1 | tr -d '\n' ;;
    WorkingDirectory) directive_values "$f" WorkingDirectory | tail -n 1 | tr -d '\n' ;;
    Environment) merged_env "$f" ;;
    EnvironmentFiles) env_files "$f" ;;
    UnsetEnvironment) list_values "$f" UnsetEnvironment ;;
    PassEnvironment) list_values "$f" PassEnvironment ;;
    ExecStart) exec_blocks "$f" ;;
    *) : ;;
  esac
}
case "$cmd" in
  show)
    unit=${1:-}
    shift || true
    [ -f "$MARKS/fail-show-$unit" ] && exit 1
    if [ -f "$MARKS/fail-show-contract-$unit" ]; then
      # Fail only the deep contract query (it alone asks for WorkingDirectory
      # or DropInPaths), so the basic status query still answers and the
      # contract-query failure path is what gets exercised.
      for a in "$@"; do
        case "$a" in
          WorkingDirectory|DropInPaths) exit 1 ;;
        esac
      done
    fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p)
          if [ ! -f "$MARKS/omit-$unit-$2" ]; then
            v=$(prop_value "$unit" "$2")
            case "$2" in
              EnvironmentFiles|ExecStart) [ -z "$v" ] || printf '%s=%s\n' "$2" "$v" ;;
              *) printf '%s=%s\n' "$2" "$v" ;;
            esac
          fi
          shift 2
          ;;
        *) shift ;;
      esac
    done
    ;;
  cat)
    unit=${1:-}
    f=$(unit_file "$unit")
    [ -f "$f" ] || exit 1
    printf '# %s\n' "$f"
    cat "$f"
    for d in "$f.d"/*.conf; do
      [ -f "$d" ] || continue
      printf '# %s\n' "$d"
      cat "$d"
    done
    ;;
  enable)
    for a in "$@"; do
      case "$a" in
        --*) ;;
        *) : > "$MARKS/enabled-$a"; : > "$MARKS/active-$a" ;;
      esac
    done
    ;;
  disable)
    for a in "$@"; do
      case "$a" in
        --*) ;;
        *) rm -f "$MARKS/enabled-$a" "$MARKS/active-$a" ;;
      esac
    done
    ;;
  daemon-reload|stop|reset-failed) ;;
  is-system-running) printf 'running\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$stub"
}

# real_env <home> <cmd...>: run the SHIPPING real-mode branch against the stub
# systemctl and the scratch unit dir, still inside the test-seam gate.
real_env() {
  local home=$1
  shift
  FM_SUPERVISION_TEST_MODE=1 \
    FM_CODEX_SYSTEMD_SYSTEMCTL="$home/systemctl-stub" \
    FM_CODEX_SYSTEMD_UNIT_DIR="$home/units" \
    STUB_UNITS="$home/units" STUB_MARKS="$home/stub-state" \
    "$@"
}

# build_record <home> <metadata-json> <generation> <lease> [due-offset] [cadence]
# Writes a schedule record consistent with the given adapter metadata.
build_record() {
  local home=$1 meta=$2 generation=$3 lease=$4 due_offset=${5:-60} cadence=${6:-60}
  local now payload hash canon_home canon_state
  now=$(date +%s)
  canon_home=$(printf '%s' "$meta" | jq -r '.fm_home')
  canon_state=$(printf '%s' "$meta" | jq -r '.state_dir')
  payload=$(jq -cnS \
    --argjson scheduler "$meta" \
    --arg lease "$lease" \
    --arg home "$canon_home" \
    --arg state "$canon_state" \
    --argjson now "$now" \
    --argjson due_offset "$due_offset" \
    --argjson cadence "$cadence" \
    --argjson generation "$generation" \
    '{version:1,harness:"codex",owner:"codex:test:codex",primary_identity:"test:codex",
      fm_home:$home,state_dir:$state,previous_checkpoint_start:($now - 2),
      previous_checkpoint_end:($now - 1),previous_result:"quiet",
      next_checkpoint_due:($now + $due_offset),cadence_seconds:$cadence,max_lateness_seconds:60,
      generation:$generation,lease_id:$lease,mechanism:"codex-bounded-checkpoint",
      scheduling_mechanism:"systemd-user-timer",scheduler:$scheduler}') || fail "payload build failed"
  hash=$(printf '%s\n' "$payload" | sha256sum | awk '{print $1}')
  printf '%s\n' "$payload" | jq -cS --arg integrity "sha256:$hash" '. + {integrity:$integrity}' \
    > "$home/record.json" || fail "record write failed"
  printf '%s\n' "$home/record.json"
}

fake_record() {  # <home> <generation> <lease>
  local home=$1 meta
  meta=$(fake_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state") \
    || fail "fake unit metadata failed"
  build_record "$home" "$meta" "$2" "$3"
}

real_record() {  # <home> <generation> <lease> [due-offset] [cadence]
  local home=$1 meta
  meta=$(real_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state") \
    || fail "real unit metadata failed"
  build_record "$home" "$meta" "$2" "$3" "${4:-60}" "${5:-60}"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# expected_launcher_line <canon_home> <canon_state> <lease> <generation>
# <cadence> <exec_path>: the reviewed clean-launcher ExecStart the adapter must
# generate (review-r6-sol F-2), reconstructed independently here so a drifted
# adapter cannot vouch for itself.
LAUNCHER_SAFE_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
expected_launcher_line() {
  local uid home_dir
  uid=$(id -u)
  home_dir=$(getent passwd "$uid" | head -n 1 | cut -d: -f6)
  printf '/usr/bin/env -i HOME=%s PATH=%s XDG_RUNTIME_DIR=/run/user/%s DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus FM_HOME=%s FM_STATE_OVERRIDE=%s FM_SUPERVISION_HARNESS=codex FM_CODEX_SYSTEMD_SERVICE=1 FM_CODEX_SYSTEMD_LEASE=%s FM_CODEX_SYSTEMD_GENERATION=%s FM_CODEX_WATCH_CHECKPOINT=%s /bin/bash %s --seconds %s\n' \
    "$home_dir" "$LAUNCHER_SAFE_PATH" "$uid" "$uid" "$1" "$2" "$3" "$4" "$5" "$6" "$5"
}

# --- the fail-closed test-seam gate (review finding F-1) ---------------------

test_fake_dir_without_test_mode_fails_closed() {
  local home status out
  home=$(make_home gate-no-test-mode)
  for verb in unit-metadata status validate schedule; do
    status=0
    out=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" "$verb" --home "$home" --state "$home/state" --record "$home/record.json" --json 2>&1) || status=$?
    expect_code 2 "$status" "ambient FM_CODEX_SYSTEMD_FAKE_DIR without test mode must fail closed for $verb"
    assert_contains "$out" "test-override-without-test-mode" "gate refusal must name the ungated override for $verb"
  done
  out=$(FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-systemd" "$SCHED" validate --home "$home" --state "$home/state" --record "$home/record.json" --json 2>/dev/null || true)
  [ "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)" = false ] \
    || fail "gated validate --json did not report ok:false: $out"
  pass "fm-codex-systemd-scheduler: fake mode without FM_SUPERVISION_TEST_MODE=1 fails closed, never green"
}

test_stub_systemctl_without_test_unit_dir_fails_closed() {
  local home status out
  home=$(make_home gate-stub-no-unit-dir)
  write_stub_systemctl "$home"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_SYSTEMCTL="$home/systemctl-stub" \
    "$SCHED" status --home "$home" --state "$home/state" --json 2>&1) || status=$?
  expect_code 2 "$status" "stub systemctl without a test-owned unit dir must fail closed"
  assert_contains "$out" "stub-systemctl-without-test-unit-dir" "gate refusal must name the missing unit dir"
  pass "fm-codex-systemd-scheduler: a stubbed systemctl never writes into the real unit directory"
}

test_test_overrides_require_test_owned_home() {
  local home status out
  home=$(mktemp -d) || fail "mktemp failed"
  mkdir -p "$home/state"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$TMP_ROOT/stray-fake" \
    "$SCHED" status --home "$home" --state "$home/state" --json 2>&1) || status=$?
  rm -rf "$home"
  expect_code 2 "$status" "test overrides against a non-test-owned home must fail closed"
  assert_contains "$out" "test-override-home-not-test-owned" "gate refusal must name the non-test-owned home"
  pass "fm-codex-systemd-scheduler: test seams require a provably test-owned home"
}

# --- canonical gated-path aliases (review-r6-sol F-1) --------------------------
# The gate must judge what a path actually addresses, not its spelling: symlink
# and normalized-`..` aliases into non-test-owned space, ambiguous ancestry,
# and aliases of the real user unit directory all fail closed.

test_gate_rejects_home_and_state_aliases() {
  local home prod status out raw
  home=$(make_home alias-home)
  prod=$(mktemp -d) || fail "mktemp failed"
  FM_TEST_CLEANUP_DIRS+=("$prod")
  mkdir -p "$prod/state"
  ln -s "$prod" "$home/home-link"
  status=0
  out=$(fake_env "$home" "$SCHED" unit-metadata --home "$home/home-link" --state "$home/home-link/state" 2>&1) || status=$?
  expect_code 2 "$status" "a symlink alias of a non-test-owned home must fail closed"
  assert_contains "$out" "test-override-home-not-test-owned" "home symlink alias refusal must name the home gate"
  mkdir -p "$home/sub"
  raw="$home/sub/../../../$(basename "$prod")"
  status=0
  out=$(fake_env "$home" "$SCHED" unit-metadata --home "$raw" --state "$raw/state" 2>&1) || status=$?
  expect_code 2 "$status" "a ..-traversal alias of a non-test-owned home must fail closed"
  assert_contains "$out" "test-override-home-not-test-owned" "home traversal alias refusal must name the home gate"
  ln -s "$prod/state" "$home/state-link"
  status=0
  out=$(fake_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state-link" 2>&1) || status=$?
  expect_code 2 "$status" "a symlink alias of a non-test-owned state dir must fail closed"
  assert_contains "$out" "test-override-state-not-test-owned" "state symlink alias refusal must name the state gate"
  pass "fm-codex-systemd-scheduler: home and state symlink or traversal aliases into non-test-owned space fail closed"
}

test_gate_rejects_fake_dir_aliases_and_ambiguous_ancestry() {
  local home prod status out
  home=$(make_home alias-fake)
  prod=$(mktemp -d) || fail "mktemp failed"
  FM_TEST_CLEANUP_DIRS+=("$prod")
  mkdir -p "$prod/fake-systemd"
  ln -s "$prod/fake-systemd" "$home/fake-link"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/fake-link" \
    "$SCHED" unit-metadata --home "$home" --state "$home/state" 2>&1) || status=$?
  expect_code 2 "$status" "a symlink alias of a non-test-owned fake dir must fail closed"
  assert_contains "$out" "fake-dir-not-test-owned" "fake-dir symlink alias refusal must name the fake-dir gate"
  ln -s "$home/nonexistent" "$home/dangle"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/dangle/fake-systemd" \
    "$SCHED" unit-metadata --home "$home" --state "$home/state" 2>&1) || status=$?
  expect_code 2 "$status" "dangling-symlink ancestry under a fake dir must fail closed"
  assert_contains "$out" "fake-dir-unresolvable" "ambiguous fake-dir ancestry refusal must name the resolution failure"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_FAKE_DIR="$home/missing/../fake-systemd" \
    "$SCHED" unit-metadata --home "$home" --state "$home/state" 2>&1) || status=$?
  expect_code 2 "$status" "a ..-component in a not-yet-created fake-dir suffix must fail closed"
  assert_contains "$out" "fake-dir-unresolvable" "unnormalizable fake-dir suffix refusal must name the resolution failure"
  pass "fm-codex-systemd-scheduler: fake-dir aliases and ambiguous ancestry fail closed"
}

test_gate_rejects_unit_dir_alias_of_real_unit_dir() {
  local home status out
  home=$(make_home alias-unit)
  write_stub_systemctl "$home"
  mkdir -p "$home/xdg/systemd/user"
  ln -s "$home/xdg/systemd/user" "$home/unit-link"
  status=0
  out=$(XDG_CONFIG_HOME="$home/xdg" FM_SUPERVISION_TEST_MODE=1 \
    FM_CODEX_SYSTEMD_SYSTEMCTL="$home/systemctl-stub" FM_CODEX_SYSTEMD_UNIT_DIR="$home/unit-link" \
    STUB_UNITS="$home/units" STUB_MARKS="$home/stub-state" \
    "$SCHED" unit-metadata --home "$home" --state "$home/state" 2>&1) || status=$?
  expect_code 2 "$status" "a symlink alias of the real unit dir must fail closed"
  assert_contains "$out" "unit-dir-inside-real-unit-dir" "unit-dir symlink alias refusal must name the containment gate"
  mkdir -p "$home/xdg/systemd/other"
  status=0
  out=$(XDG_CONFIG_HOME="$home/xdg" FM_SUPERVISION_TEST_MODE=1 \
    FM_CODEX_SYSTEMD_SYSTEMCTL="$home/systemctl-stub" FM_CODEX_SYSTEMD_UNIT_DIR="$home/xdg/systemd/other/../user" \
    STUB_UNITS="$home/units" STUB_MARKS="$home/stub-state" \
    "$SCHED" unit-metadata --home "$home" --state "$home/state" 2>&1) || status=$?
  expect_code 2 "$status" "a ..-traversal alias of the real unit dir must fail closed"
  assert_contains "$out" "unit-dir-inside-real-unit-dir" "unit-dir traversal alias refusal must name the containment gate"
  pass "fm-codex-systemd-scheduler: unit-dir aliases of the real user unit directory fail closed"
}

test_gate_rejects_untrusted_stub_systemctl() {
  local home prod status out
  home=$(make_home alias-stub)
  mkdir -p "$home/units"
  prod=$(mktemp -d) || fail "mktemp failed"
  FM_TEST_CLEANUP_DIRS+=("$prod")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$prod/rogue-systemctl"
  chmod +x "$prod/rogue-systemctl"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_SYSTEMCTL="$prod/rogue-systemctl" \
    FM_CODEX_SYSTEMD_UNIT_DIR="$home/units" \
    "$SCHED" status --home "$home" --state "$home/state" --json 2>&1) || status=$?
  expect_code 2 "$status" "a stub systemctl outside test ownership must fail closed"
  assert_contains "$out" "stub-systemctl-not-test-owned" "untrusted stub refusal must name the stub gate"
  write_stub_systemctl "$home"
  ln -s "$home/systemctl-stub" "$home/stub-link"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_SYSTEMCTL="$home/stub-link" \
    FM_CODEX_SYSTEMD_UNIT_DIR="$home/units" \
    "$SCHED" status --home "$home" --state "$home/state" --json 2>&1) || status=$?
  expect_code 2 "$status" "a symlink stub systemctl must fail closed"
  assert_contains "$out" "stub-systemctl-unresolvable" "symlink stub refusal must name the resolution failure"
  pass "fm-codex-systemd-scheduler: the stub systemctl must be a canonical test-owned regular file"
}

test_schedule_never_writes_through_unit_dir_alias() {
  local home target record status out
  home=$(make_home alias-write)
  write_stub_systemctl "$home"
  target=$(mktemp -d) || fail "mktemp failed"
  FM_TEST_CLEANUP_DIRS+=("$target")
  record=$(real_record "$home" 1 lease-one)
  ln -s "$target" "$home/unit-alias"
  status=0
  out=$(FM_SUPERVISION_TEST_MODE=1 FM_CODEX_SYSTEMD_SYSTEMCTL="$home/systemctl-stub" \
    FM_CODEX_SYSTEMD_UNIT_DIR="$home/unit-alias" \
    STUB_UNITS="$home/units" STUB_MARKS="$home/stub-state" \
    "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" 2>&1) || status=$?
  expect_code 2 "$status" "a mutating schedule through a unit-dir alias must fail closed"
  assert_contains "$out" "unit-dir-not-test-owned" "aliased mutating schedule refusal must name the unit-dir gate"
  [ -z "$(find "$target" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || fail "a refused aliased schedule still wrote through the alias target"
  pass "fm-codex-systemd-scheduler: mutating operations never write through a rejected unit-dir alias"
}

# --- fake-mode lifecycle ------------------------------------------------------

test_metadata_is_deterministic_and_home_scoped() {
  local home other a b c
  home=$(make_home metadata-a)
  other=$(make_home metadata-b)
  a=$(fake_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state")
  b=$(fake_env "$home" "$SCHED" unit-metadata --home "$home" --state "$home/state")
  c=$(fake_env "$other" "$SCHED" unit-metadata --home "$other" --state "$other/state")
  [ "$(printf '%s' "$a" | jq -r '.timer_name')" = "$(printf '%s' "$b" | jq -r '.timer_name')" ] \
    || fail "unit metadata is not deterministic for the same home"
  [ "$(printf '%s' "$a" | jq -r '.timer_name')" != "$(printf '%s' "$c" | jq -r '.timer_name')" ] \
    || fail "unit metadata did not vary by canonical home"
  pass "fm-codex-systemd-scheduler: metadata is deterministic and scoped by home"
}

test_schedule_query_validate_disable_remove() {
  local home record status validation
  home=$(make_home lifecycle)
  record=$(fake_record "$home" 1 lease-one)
  fake_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" \
    || fail "schedule command failed"
  status=$(fake_env "$home" "$SCHED" query --home "$home" --state "$home/state" --json) \
    || fail "query command failed"
  [ "$(printf '%s' "$status" | jq -r '.registered')" = true ] || fail "query did not report registered timer: $status"
  validation=$(fake_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$record" --json) \
    || fail "validate command failed"
  [ "$(printf '%s' "$validation" | jq -r '.ok')" = true ] || fail "validate did not report ok: $validation"
  fake_env "$home" "$SCHED" disable --home "$home" --state "$home/state" \
    || fail "disable command failed"
  if fake_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$record" --json >/dev/null 2>&1; then
    fail "disabled scheduler still validated healthy"
  fi
  fake_env "$home" "$SCHED" remove --home "$home" --state "$home/state" \
    || fail "remove command failed"
  status=$(fake_env "$home" "$SCHED" status --home "$home" --state "$home/state" --json) \
    || fail "status command failed after remove"
  [ "$(printf '%s' "$status" | jq -r '.registered')" = false ] || fail "remove left scheduler registered: $status"
  pass "fm-codex-systemd-scheduler: schedule/query/validate/disable/remove lifecycle works in fake mode"
}

test_alias_verbs_replace_generation() {
  local home record status
  home=$(make_home aliases)
  record=$(fake_record "$home" 1 lease-one)
  fake_env "$home" "$SCHED" install --home "$home" --state "$home/state" --record "$record" \
    || fail "install alias failed"
  record=$(fake_record "$home" 2 lease-two)
  fake_env "$home" "$SCHED" controlled-replacement --home "$home" --state "$home/state" --record "$record" \
    || fail "controlled-replacement alias failed"
  status=$(fake_env "$home" "$SCHED" status --home "$home" --state "$home/state" --json)
  [ "$(printf '%s' "$status" | jq -r '.generation')" = 2 ] || fail "replacement did not publish generation 2: $status"
  [ "$(printf '%s' "$status" | jq -r '.lease_id')" = lease-two ] || fail "replacement did not publish lease-two: $status"
  pass "fm-codex-systemd-scheduler: install and controlled-replacement aliases publish one active generation"
}

# --- the shipping real-mode branch, driven through the stub (F-3/F-5) ---------

real_home_with_schedule() {  # <name> -> prints "<home>"; record at $home/record.json
  local name=$1 home record
  home=$(make_home "$name")
  write_stub_systemctl "$home"
  record=$(real_record "$home" 1 lease-one)
  real_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" \
    || fail "real-mode schedule failed for $name"
  printf '%s\n' "$home"
}

real_meta() {  # <home>
  real_env "$1" "$SCHED" unit-metadata --home "$1" --state "$1/state"
}

real_validate_reason() {  # <home> - prints the (possibly empty) failure reason
  local home=$1 out
  out=$(real_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$home/record.json" --json 2>/dev/null || true)
  printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null
}

test_real_mode_schedule_generates_exact_unit_contract() {
  local home meta service_path timer_path exec_path due calendar validation canon_home canon_state expected_exec
  home=$(real_home_with_schedule real-lifecycle)
  meta=$(real_meta "$home")
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  exec_path=$(printf '%s' "$meta" | jq -r '.exec_path')
  canon_home=$(printf '%s' "$meta" | jq -r '.fm_home')
  canon_state=$(printf '%s' "$meta" | jq -r '.state_dir')
  assert_present "$service_path" "real-mode schedule did not write the service unit"
  assert_present "$timer_path" "real-mode schedule did not write the timer unit"
  [ "$(file_mode "$service_path")" = 600 ] || fail "service unit was not written with restrictive 0600 mode"
  [ "$(file_mode "$timer_path")" = 600 ] || fail "timer unit was not written with restrictive 0600 mode"
  expected_exec=$(expected_launcher_line "$canon_home" "$canon_state" lease-one 1 60 "$exec_path")
  grep -qFx "ExecStart=$expected_exec" "$service_path" \
    || fail "service ExecStart is not the exact clean-launcher command: $(sed -n 's/^ExecStart=//p' "$service_path")"
  [ "$(grep -c '^ExecStart=' "$service_path")" = 1 ] || fail "service unit carries more than one ExecStart"
  assert_grep 'Environment="FM_CODEX_SYSTEMD_SERVICE=1"' "$service_path" "service unit lost the clean-environment service marker line"
  assert_grep 'Environment="FM_CODEX_SYSTEMD_LEASE=lease-one"' "$service_path" "service unit lost the lease environment line"
  assert_grep 'Environment="FM_CODEX_SYSTEMD_GENERATION=1"' "$service_path" "service unit lost the generation environment line"
  assert_grep 'Environment="FM_CODEX_WATCH_CHECKPOINT=60"' "$service_path" "service unit lost the cadence environment line"
  due=$(jq -r '.next_checkpoint_due' "$home/record.json")
  calendar=$(date -u -d "@$due" '+%Y-%m-%d %H:%M:%S UTC')
  assert_grep "OnCalendar=$calendar" "$timer_path" "timer OnCalendar does not match the record due time"
  [ -f "$home/stub-state/enabled-$(printf '%s' "$meta" | jq -r '.timer_name')" ] \
    || fail "real-mode schedule did not enable the timer"
  validation=$(real_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$home/record.json" --json) \
    || fail "real-mode validate failed on a freshly armed contract"
  [ "$(printf '%s' "$validation" | jq -r '.ok')" = true ] || fail "real-mode validate did not report ok: $validation"
  real_env "$home" "$SCHED" remove --home "$home" --state "$home/state" || fail "real-mode remove failed"
  assert_absent "$service_path" "remove left the service unit behind"
  assert_absent "$timer_path" "remove left the timer unit behind"
  if real_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$home/record.json" --json >/dev/null 2>&1; then
    fail "removed scheduler still validated healthy"
  fi
  pass "fm-codex-systemd-scheduler: real mode writes, arms, validates, and removes the exact unit contract"
}

test_real_mode_rejects_altered_exec_start() {
  local home meta service_path reason
  home=$(real_home_with_schedule real-exec-tamper)
  meta=$(real_meta "$home")
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  sed -i 's|^ExecStart=.*|ExecStart=/bin/true|' "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "exec-start-mismatch" "altered ExecStart must fail validation"
  pass "fm-codex-systemd-scheduler: real mode reads back and rejects an altered service command"
}

test_real_mode_rejects_disabled_timer() {
  local home meta timer reason
  home=$(real_home_with_schedule real-disabled)
  meta=$(real_meta "$home")
  timer=$(printf '%s' "$meta" | jq -r '.timer_name')
  rm -f "$home/stub-state/enabled-$timer"
  printf 'active' > "$home/stub-state/override-$timer-ActiveState"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "timer-not-enabled" "a disabled-but-active timer must fail validation"
  pass "fm-codex-systemd-scheduler: real mode rejects a timer that would not survive re-login"
}

test_real_mode_rejects_missing_timer() {
  local home meta timer_path reason
  home=$(real_home_with_schedule real-missing-timer)
  meta=$(real_meta "$home")
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  rm -f "$timer_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "timer-not-registered" "a missing timer must fail validation"
  pass "fm-codex-systemd-scheduler: real mode rejects a missing timer"
}

test_real_mode_rejects_next_elapse_disagreement() {
  local home meta timer_path reason
  home=$(real_home_with_schedule real-next-elapse)
  meta=$(real_meta "$home")
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  sed -i 's|^OnCalendar=.*|OnCalendar=2036-01-01 00:00:00 UTC|' "$timer_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "calendar-mismatch" "a decade-off timer trigger must fail validation"
  assert_contains "$reason" "next-elapse-mismatch" "the timer real next-elapse must be compared to the record due time"
  pass "fm-codex-systemd-scheduler: real mode compares the timer's real next trigger to the record due time"
}

test_real_mode_rejects_trigger_mismatch() {
  local home meta timer reason
  home=$(real_home_with_schedule real-trigger)
  meta=$(real_meta "$home")
  timer=$(printf '%s' "$meta" | jq -r '.timer_name')
  printf 'someone-elses.service' > "$home/stub-state/override-$timer-Triggers"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "trigger-mismatch" "a timer triggering another service must fail validation"
  pass "fm-codex-systemd-scheduler: real mode requires the timer to trigger the expected service"
}

test_real_mode_rejects_duplicate_unit_for_home() {
  local home meta service_path reason
  home=$(real_home_with_schedule real-duplicate-unit)
  meta=$(real_meta "$home")
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  cp "$service_path" "$home/units/fm-codex-checkpoint-feedbeefdeadbeef.service"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "duplicate-unit" "a second unit claiming this home must fail validation"
  pass "fm-codex-systemd-scheduler: real mode refuses duplicate unit ownership of one home"
}

# --- loaded-service-contract exactness (review-r4 F-1) -------------------------
# Expected-line presence is never authority: every case below keeps all the
# expected lines present and proves the added or diverged directive still
# fails validation with a deterministic reason.

test_real_mode_rejects_duplicate_controlled_env() {
  local home service_path pristine line name reason
  home=$(real_home_with_schedule real-dup-env)
  service_path=$(real_meta "$home" | jq -r '.service_path')
  pristine="$home/pristine.service"
  cp "$service_path" "$pristine"
  # A same-value duplicate collapses in systemd's merged effective view, so
  # only the per-variable source assignment count can catch it.
  line=$(grep '^Environment="FM_HOME=' "$pristine")
  printf '%s\n' "$line" >> "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "env-duplicate:FM_HOME" "a same-value duplicate FM_HOME assignment must fail validation"
  # A conflicting duplicate wins at exec time (later assignment overrides), so
  # the effective merged value must also be reported wrong.
  cp "$pristine" "$service_path"
  printf 'Environment="FM_HOME=%s"\n' "$home/evil" >> "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "env-duplicate:FM_HOME" "a conflicting duplicate FM_HOME assignment must fail validation"
  assert_contains "$reason" "home-env-mismatch" "the effective merged FM_HOME must be compared, not line presence"
  for name in FM_STATE_OVERRIDE FM_SUPERVISION_HARNESS FM_CODEX_SYSTEMD_SERVICE FM_CODEX_SYSTEMD_LEASE FM_CODEX_SYSTEMD_GENERATION FM_CODEX_WATCH_CHECKPOINT; do
    cp "$pristine" "$service_path"
    printf 'Environment="%s=evil-conflict"\n' "$name" >> "$service_path"
    reason=$(real_validate_reason "$home")
    assert_contains "$reason" "env-duplicate:$name" "a conflicting duplicate $name assignment must fail validation"
  done
  pass "fm-codex-systemd-scheduler: same-value and conflicting duplicate controlled assignments fail validation"
}

test_real_mode_rejects_environment_indirection() {
  local home service_path pristine reason
  home=$(real_home_with_schedule real-env-indirection)
  service_path=$(real_meta "$home" | jq -r '.service_path')
  pristine="$home/pristine.service"
  cp "$service_path" "$pristine"
  printf 'EnvironmentFile=%s\n' "$home/evil.env" >> "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "environment-file-present" "a loaded EnvironmentFile must fail effective validation"
  assert_contains "$reason" "source-environment-file" "a loaded EnvironmentFile must fail source validation"
  cp "$pristine" "$service_path"
  printf 'EnvironmentFile=-%s\n' "$home/optional.env" >> "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "environment-file-present" "an optional EnvironmentFile must fail validation too"
  cp "$pristine" "$service_path"
  printf 'UnsetEnvironment=FM_HOME FM_STATE_OVERRIDE FM_CODEX_WATCH_CHECKPOINT\n' >> "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "unset-environment-present" "UnsetEnvironment must fail effective validation"
  assert_contains "$reason" "source-unset-environment" "UnsetEnvironment must fail source validation"
  cp "$pristine" "$service_path"
  printf 'PassEnvironment=FM_HOME\n' >> "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "pass-environment-present" "PassEnvironment must fail effective validation"
  assert_contains "$reason" "source-pass-environment" "PassEnvironment must fail source validation"
  pass "fm-codex-systemd-scheduler: environment indirection and removal directives fail validation"
}

test_real_mode_rejects_wrong_working_directory() {
  local home service_path reason
  home=$(real_home_with_schedule real-workdir)
  service_path=$(real_meta "$home" | jq -r '.service_path')
  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=$home/evil|" "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "workdir-mismatch" "a tampered WorkingDirectory must fail effective validation"
  assert_contains "$reason" "workdir-source-mismatch" "a tampered WorkingDirectory must fail source validation"
  pass "fm-codex-systemd-scheduler: a WorkingDirectory that is not the canonical home fails validation"
}

test_real_mode_rejects_drop_ins() {
  local home meta service_path timer_path reason
  home=$(real_home_with_schedule real-drop-ins)
  meta=$(real_meta "$home")
  service_path=$(printf '%s' "$meta" | jq -r '.service_path')
  timer_path=$(printf '%s' "$meta" | jq -r '.timer_path')
  mkdir -p "$service_path.d"
  printf '[Service]\nEnvironment="FM_HOME=%s"\n' "$home/evil" > "$service_path.d/override.conf"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "service-drop-in" "a service drop-in must fail validation"
  rm -rf "$service_path.d"
  mkdir -p "$timer_path.d"
  printf '[Timer]\nOnCalendar=2036-01-01 00:00:00 UTC\n' > "$timer_path.d/override.conf"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "timer-drop-in" "a timer drop-in must fail validation"
  pass "fm-codex-systemd-scheduler: drop-ins on the service or timer fail validation"
}

test_real_mode_rejects_unexpected_env_vars() {
  local home service_path pristine reason
  home=$(real_home_with_schedule real-unexpected-env)
  service_path=$(real_meta "$home" | jq -r '.service_path')
  pristine="$home/pristine.service"
  cp "$service_path" "$pristine"
  printf 'Environment="FM_CODEX_EXTRA=1"\n' >> "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "env-unexpected:FM_CODEX_EXTRA" "an unexpected FM_CODEX_* variable must fail validation"
  assert_contains "$reason" "env-line-count-mismatch" "the source assignment count must be exact"
  cp "$pristine" "$service_path"
  printf 'Environment="LD_PRELOAD=%s"\n' "$home/evil.so" >> "$service_path"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "env-unexpected:LD_PRELOAD" "any unexpected variable must fail validation"
  pass "fm-codex-systemd-scheduler: unexpected environment variables fail validation"
}

test_real_mode_rejects_each_missing_required_variable() {
  local home service_path pristine name reason
  home=$(real_home_with_schedule real-missing-env)
  service_path=$(real_meta "$home" | jq -r '.service_path')
  pristine="$home/pristine.service"
  cp "$service_path" "$pristine"
  for name in FM_HOME FM_STATE_OVERRIDE FM_SUPERVISION_HARNESS FM_CODEX_SYSTEMD_SERVICE FM_CODEX_SYSTEMD_LEASE FM_CODEX_SYSTEMD_GENERATION FM_CODEX_WATCH_CHECKPOINT; do
    grep -v "^Environment=\"$name=" "$pristine" > "$service_path"
    reason=$(real_validate_reason "$home")
    assert_contains "$reason" "env-missing:$name" "a missing $name assignment must fail validation"
  done
  pass "fm-codex-systemd-scheduler: each missing required environment variable fails validation"
}

test_real_mode_rejects_effective_source_divergence() {
  local home meta service reason canon_state
  home=$(real_home_with_schedule real-divergence)
  meta=$(real_meta "$home")
  service=$(printf '%s' "$meta" | jq -r '.service_name')
  canon_state=$(printf '%s' "$meta" | jq -r '.state_dir')
  # The visible unit file stays byte-for-byte pristine; only systemd's loaded
  # state diverges. Line-presence validation would stay green here.
  printf 'FM_HOME=%s FM_STATE_OVERRIDE=%s FM_SUPERVISION_HARNESS=codex FM_CODEX_SYSTEMD_SERVICE=1 FM_CODEX_SYSTEMD_LEASE=lease-one FM_CODEX_SYSTEMD_GENERATION=1 FM_CODEX_WATCH_CHECKPOINT=60' \
    "$home/evil" "$canon_state" > "$home/stub-state/override-$service-Environment"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "home-env-mismatch" "a loaded environment diverging from the visible source must fail validation"
  rm -f "$home/stub-state/override-$service-Environment"
  printf '%s' "$home/evil" > "$home/stub-state/override-$service-WorkingDirectory"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "workdir-mismatch" "a loaded WorkingDirectory diverging from the visible source must fail validation"
  rm -f "$home/stub-state/override-$service-WorkingDirectory"
  reason=$(real_validate_reason "$home")
  [ -z "$reason" ] || [ "$reason" = valid ] || fail "pristine contract no longer validates after divergence probes: $reason"
  pass "fm-codex-systemd-scheduler: effective state diverging from the visible source fails validation"
}

test_real_mode_fails_closed_on_property_query_problems() {
  local home service reason
  home=$(real_home_with_schedule real-query-problems)
  service=$(real_meta "$home" | jq -r '.service_name')
  : > "$home/stub-state/fail-show-contract-$service"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "service-property-query-failed" "a failed contract property query must fail closed"
  rm -f "$home/stub-state/fail-show-contract-$service"
  : > "$home/stub-state/omit-$service-WorkingDirectory"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "service-property-missing:WorkingDirectory" "an unanswered required property must fail closed"
  rm -f "$home/stub-state/omit-$service-WorkingDirectory"
  printf 'FM_HOME="unterminated' > "$home/stub-state/override-$service-Environment"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "environment-parse-ambiguous" "an unparseable effective environment must fail closed"
  rm -f "$home/stub-state/override-$service-Environment"
  : > "$home/stub-state/override-$service-Environment"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "env-missing:FM_HOME" "an empty effective environment must fail closed"
  rm -f "$home/stub-state/override-$service-Environment"
  pass "fm-codex-systemd-scheduler: failed, unanswered, malformed, or empty property queries fail closed"
}

# --- clean-launcher ExecStart contract (review-r6-sol F-2) ---------------------
# The launcher line is the environment boundary, so every mutation class the
# review names must fail with its own deterministic reason: wrong environment
# executable, missing clean flag, pass-through, unexpected/missing/duplicate
# values, changed safe runtime values, and changed checkpoint arguments.

test_real_mode_rejects_launcher_mutations() {
  local home service_path pristine orig reason name
  home=$(real_home_with_schedule real-launcher-mutations)
  service_path=$(real_meta "$home" | jq -r '.service_path')
  pristine="$home/pristine.service"
  cp "$service_path" "$pristine"
  orig=$(sed -n 's/^ExecStart=//p' "$pristine" | head -n 1)
  set_exec() {  # <line>: replace the pristine ExecStart with <line>
    grep -v '^ExecStart=' "$pristine" > "$service_path"
    printf 'ExecStart=%s\n' "$1" >> "$service_path"
  }
  # Launcher tokens are whitespace-free by contract, so token-wise rewriting of
  # $orig is exact.
  replace_token() {  # <old> <new>
    local old=$1 new=$2 out='' tok
    for tok in $orig; do
      [ "$tok" = "$old" ] && tok=$new
      out="$out$tok "
    done
    printf '%s' "${out% }"
  }
  drop_token() {  # <exact-token-or-NAME=*-glob>
    local drop=$1 out='' tok
    for tok in $orig; do
      # shellcheck disable=SC2254  # $drop is a deliberate NAME=* glob
      case "$tok" in
        $drop) continue ;;
      esac
      out="$out$tok "
    done
    printf '%s' "${out% }"
  }
  insert_after_flag() {  # <token>: insert right after the -i clean flag
    local ins=$1 out='' tok
    for tok in $orig; do
      out="$out$tok "
      [ "$tok" = -i ] && out="$out$ins "
    done
    printf '%s' "${out% }"
  }
  mutate_env_value() {  # <name> <newvalue>
    local name=$1 val=$2 out='' tok
    for tok in $orig; do
      case "$tok" in
        "$name="*) tok="$name=$val" ;;
      esac
      out="$out$tok "
    done
    printf '%s' "${out% }"
  }
  set_exec "$(replace_token /usr/bin/env /opt/rogue-env)"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "exec-launcher-mismatch" "a wrong environment executable must fail validation"
  set_exec "$(drop_token -i)"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "exec-clean-flag-missing" "a missing ignore-environment flag must fail validation"
  set_exec "$(insert_after_flag "LD_PRELOAD=$home/evil.so")"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "launcher-env-unexpected:LD_PRELOAD" "a passed-through extra variable must fail validation"
  for name in PATH HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; do
    set_exec "$(mutate_env_value "$name" "evil-value")"
    reason=$(real_validate_reason "$home")
    assert_contains "$reason" "launcher-env-mismatch:$name" "a changed safe runtime value $name must fail validation"
  done
  for name in FM_HOME FM_STATE_OVERRIDE FM_SUPERVISION_HARNESS FM_CODEX_SYSTEMD_SERVICE FM_CODEX_SYSTEMD_LEASE FM_CODEX_SYSTEMD_GENERATION FM_CODEX_WATCH_CHECKPOINT; do
    set_exec "$(mutate_env_value "$name" "evil-value")"
    reason=$(real_validate_reason "$home")
    assert_contains "$reason" "launcher-env-mismatch:$name" "a changed supervision value $name must fail validation"
  done
  set_exec "$(drop_token 'HOME=*')"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "launcher-env-missing:HOME" "a missing safe HOME must fail validation"
  set_exec "$(insert_after_flag "FM_HOME=$home/evil")"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "launcher-env-duplicate:FM_HOME" "a duplicate launcher assignment must fail validation"
  set_exec "$(replace_token /bin/bash /bin/sh)"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "exec-command-mismatch" "a changed fixed interpreter must fail validation"
  set_exec "$(replace_token 60 1)"
  reason=$(real_validate_reason "$home")
  assert_contains "$reason" "exec-command-mismatch" "a changed checkpoint argument must fail validation"
  cp "$pristine" "$service_path"
  reason=$(real_validate_reason "$home")
  [ -z "$reason" ] || [ "$reason" = valid ] || fail "pristine launcher contract no longer validates: $reason"
  pass "fm-codex-systemd-scheduler: every clean-launcher mutation class fails validation with its own reason"
}

# The adapter-generated polluted-parent execution proof: run the EXACT loaded
# ExecStart command from a parent carrying hostile supervision, loader, and
# PATH pollution, and prove the checkpoint's first observable environment
# (/proc/self/environ at exec) is byte-identical to the reviewed allowlist.
test_launcher_delivers_exact_clean_environment_from_polluted_parent() {
  local home service_path execline decoy status tok
  local -a argv
  home=$(real_home_with_schedule real-clean-launch)
  service_path=$(real_meta "$home" | jq -r '.service_path')
  execline=$(sed -n 's/^ExecStart=//p' "$service_path" | head -n 1)
  : > "$home/state/.codex-env-capture"
  decoy="$TMP_ROOT/clean-launch-decoy"
  mkdir -p "$decoy/state"
  read -r -a argv <<<"$execline"
  [ "${argv[0]}" = /usr/bin/env ] || fail "loaded ExecStart does not start with the fixed environment executable: $execline"
  [ "${argv[1]}" = -i ] || fail "loaded ExecStart does not carry the ignore-environment flag: $execline"
  status=0
  env FM_ROOT_OVERRIDE="$decoy" FM_SUPERVISION_TEST_MODE=1 \
    FM_CODEX_WATCH_CHECKPOINT_MAX_LATENESS=999999 FM_CODEX_PRIMARY_IDENTITY=forged-parent-identity \
    FM_CODEX_SYSTEMD_FAKE_DIR="$decoy/fake-systemd" LD_PRELOAD="$decoy/evil.so" PATH="$decoy/evil-bin:$PATH" \
    "${argv[@]}" >"$home/launch-out.txt" 2>"$home/launch-err.txt" || status=$?
  [ -f "$home/state/.codex-env-capture.out" ] \
    || fail "the launched checkpoint did not capture its first observable environment (exit $status): $(cat "$home/launch-err.txt")"
  for ((i = 2; i < ${#argv[@]}; i++)); do
    tok=${argv[i]}
    case "$tok" in
      [A-Za-z_]*=*) printf '%s\n' "$tok" ;;
      *) break ;;
    esac
  done | LC_ALL=C sort > "$home/expected-env.txt"
  diff -u "$home/expected-env.txt" "$home/state/.codex-env-capture.out" >"$home/env-diff.txt" 2>&1 \
    || fail "checkpoint first observable environment is not exactly the reviewed allowlist: $(cat "$home/env-diff.txt")"
  [ -z "$(find "$decoy/state" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || fail "polluted parent FM_ROOT_OVERRIDE leaked into the launched checkpoint"
  [ -e "$decoy/fake-systemd" ] \
    && fail "polluted parent fake-scheduler seam was honored by the launched checkpoint"
  pass "fm-codex-systemd-scheduler: the loaded launcher delivers exactly the reviewed environment from a polluted parent"
}

# --- unit-file injection (review finding F-4) ----------------------------------

test_real_mode_rejects_directive_injection_in_lease() {
  local home record status out
  home=$(make_home real-inject-lease)
  write_stub_systemctl "$home"
  record=$(real_record "$home" 1 safe-lease)
  jq -c --arg lease $'ok\nExecStart=/bin/sh -c "id > /tmp/fm-INJECTED-PROOF.txt"' \
    '.lease_id = $lease' "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  status=0
  out=$(real_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "schedule accepted a lease with an embedded unit directive"
  assert_contains "$out" "bad-lease" "injection refusal must name the invalid lease"
  if grep -r "INJECTED" "$home/units" >/dev/null 2>&1; then
    fail "an injected directive reached a generated unit file"
  fi
  status=0
  real_env "$home" "$SCHED" validate --home "$home" --state "$home/state" --record "$record" --json >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "validate accepted a lease with an embedded unit directive"
  pass "fm-codex-systemd-scheduler: record fields with embedded directives never reach a unit file"
}

test_real_mode_rejects_non_numeric_cadence() {
  local home record status out
  home=$(make_home real-inject-cadence)
  write_stub_systemctl "$home"
  record=$(real_record "$home" 1 lease-one)
  jq -c '.cadence_seconds = "60 --seconds 1"' "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  status=0
  out=$(real_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "schedule accepted a non-numeric cadence"
  assert_contains "$out" "bad-cadence" "cadence refusal must name the invalid field"
  pass "fm-codex-systemd-scheduler: only validated numeric cadence reaches the service command"
}

test_fake_mode_rejects_invalid_record_fields() {
  local home record status
  home=$(make_home fake-bad-fields)
  record=$(fake_record "$home" 1 lease-one)
  jq -c '.lease_id = "bad lease with spaces"' "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  status=0
  fake_env "$home" "$SCHED" schedule --home "$home" --state "$home/state" --record "$record" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] || fail "fake schedule accepted an invalid lease"
  pass "fm-codex-systemd-scheduler: fake mode applies the same record-field validation"
}

test_fake_dir_without_test_mode_fails_closed
test_stub_systemctl_without_test_unit_dir_fails_closed
test_test_overrides_require_test_owned_home
test_gate_rejects_home_and_state_aliases
test_gate_rejects_fake_dir_aliases_and_ambiguous_ancestry
test_gate_rejects_unit_dir_alias_of_real_unit_dir
test_gate_rejects_untrusted_stub_systemctl
test_schedule_never_writes_through_unit_dir_alias
test_metadata_is_deterministic_and_home_scoped
test_schedule_query_validate_disable_remove
test_alias_verbs_replace_generation
test_real_mode_schedule_generates_exact_unit_contract
test_real_mode_rejects_altered_exec_start
test_real_mode_rejects_disabled_timer
test_real_mode_rejects_missing_timer
test_real_mode_rejects_next_elapse_disagreement
test_real_mode_rejects_trigger_mismatch
test_real_mode_rejects_duplicate_unit_for_home
test_real_mode_rejects_duplicate_controlled_env
test_real_mode_rejects_environment_indirection
test_real_mode_rejects_wrong_working_directory
test_real_mode_rejects_drop_ins
test_real_mode_rejects_unexpected_env_vars
test_real_mode_rejects_each_missing_required_variable
test_real_mode_rejects_effective_source_divergence
test_real_mode_fails_closed_on_property_query_problems
test_real_mode_rejects_launcher_mutations
test_launcher_delivers_exact_clean_environment_from_polluted_parent
test_real_mode_rejects_directive_injection_in_lease
test_real_mode_rejects_non_numeric_cadence
test_fake_mode_rejects_invalid_record_fields
