#!/usr/bin/env bash
# Behavior tests for the class/profile dispatch shim bin/fm-spawn-profile.sh and
# the routing resolver bin/fm-profile.sh it drives (the "hybrid" convergence:
# local routing brain, stock upstream fm-spawn.sh launcher).
#
# Two groups:
#   RESOLVER  - invoke fm-profile.sh directly against a seeded crew-profiles.json
#               + state/crew-profile-bindings.json (no terminal involved).
#   SHIM      - drive fm-spawn-profile.sh through meta writing and launch
#               construction with a fake tmux pane and a real isolated git
#               worktree, exactly as tests/fm-spawn-dispatch-profile.test.sh does
#               for the concrete-axis path. The fake tmux captures the literal
#               launch command sent with `tmux send-keys -l`, so the shim never
#               starts a real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE="$ROOT/bin/fm-profile.sh"
SHIM="$ROOT/bin/fm-spawn-profile.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-profile)

require_jq() {
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
}

# Synthetic runtime bindings with placeholder model names (never real model IDs).
write_bindings() {
  cat > "$1" <<'JSON'
{
  "scout_fast": {
    "harness": "codex",
    "model": "model-scout",
    "backups": [{ "harness": "grok", "model": "model-scout-backup", "effort": "medium" }]
  },
  "implementer_balanced": {
    "harness": "claude",
    "model": "model-impl",
    "effort": "high",
    "backups": [{ "harness": "grok", "model": "model-impl-backup", "effort": "high" }]
  },
  "reviewer_deep":        { "harness": "claude", "model": "model-reviewdeep", "effort": "xhigh" },
  "grok_build":           { "harness": "grok", "model": "model-grok-build", "effort": "high" },
  "reviewer_independent": {
    "counterpart": {
      "anthropic": { "harness": "codex",  "model": "model-review-openai", "effort": "xhigh" },
      "openai": {
        "harness": "claude",
        "model": "model-review-anthropic",
        "effort": "high",
        "backups": [{ "harness": "grok", "model": "model-review-xai", "effort": "high" }]
      }
    }
  }
}
JSON
}

# --- RESOLVER group -----------------------------------------------------------

# make_profile_home <name>: a sandbox home with the committed class map, a
# deterministic legacy crew harness, and seeded runtime bindings.
make_profile_home() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  fakebin="$home/fakebin"
  mkdir -p "$home/config" "$home/state" "$fakebin"
  fm_fake_exit0 "$fakebin" claude codex grok
  cp "$ROOT/docs/examples/crew-profiles.json" "$home/config/crew-profiles.json"
  printf 'claude\n' > "$home/config/crew-harness"
  write_bindings "$home/state/crew-profile-bindings.json"
  printf '%s\n' "$home"
}

run_profile() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$home/fakebin:$PATH" \
    "$PROFILE" "$@" 2>&1
}

test_class_to_profile_lookup() {
  local home out
  require_jq
  home=$(make_profile_home class-to-profile)

  out=$(run_profile "$home" architecture_review) \
    || fail "architecture_review resolution failed"$'\n'"$out"
  assert_contains "$out" "CLASS=architecture_review" "class not echoed for architecture_review"
  assert_contains "$out" "PROFILE=reviewer_deep" "architecture_review must map to reviewer_deep"

  out=$(run_profile "$home" normal_code_change) || fail "normal_code_change resolution failed"
  assert_contains "$out" "PROFILE=implementer_balanced" "normal_code_change must map to implementer_balanced"

  out=$(run_profile "$home" not_a_real_class) && fail "unknown class should fail"
  assert_contains "$out" "unknown task class or profile" "unknown class did not error clearly"
  pass "class -> profile lookup maps committed task classes and rejects unknown ones"
}

test_grok_build_class_mapping_is_preserved() {
  local home out
  require_jq
  home=$(make_profile_home grok-build-class)

  out=$(run_profile "$home" grok_build) || fail "grok_build class resolution failed"$'\n'"$out"
  assert_contains "$out" "CLASS=grok_build" "grok_build class was not recognized"
  assert_contains "$out" "PROFILE=grok_build" "grok_build class mapping was not preserved"
  assert_contains "$out" "HARNESS=grok" "grok_build binding did not resolve to the Grok harness"
  assert_contains "$out" "PROVIDER=xai" "grok_build provider did not resolve to xAI"
  pass "grok_build task class remains mapped to its runtime profile"
}

test_state_binding_lookup() {
  local home out
  require_jq
  home=$(make_profile_home state-binding)

  out=$(run_profile "$home" normal_code_change) || fail "state binding resolution failed"
  assert_contains "$out" "HARNESS=claude" "state binding harness wrong"
  assert_contains "$out" "MODEL=model-impl" "state binding model wrong"
  assert_contains "$out" "EFFORT=high" "state binding effort wrong"
  assert_contains "$out" "BINDING_SOURCE=state" "binding source should be state"
  assert_contains "$out" "PROVIDER=anthropic" "claude provider should be anthropic"
  assert_contains "$out" "CANDIDATE_INDEX=0" "healthy primary should report candidate zero"
  assert_contains "$out" "FALLBACK_FROM=" "healthy primary should not report fallback origin"
  pass "profile -> harness/model/effort resolves from state bindings"
}

test_no_failover_state_preserves_primary() {
  local home out
  require_jq
  home=$(make_profile_home no-failover-state)
  rm -f "$home/state/provider-failover.json"

  out=$(run_profile "$home" file_discovery) || fail "resolution without failover state failed"
  assert_contains "$out" "HARNESS=codex" "absent failover state changed the primary harness"
  assert_contains "$out" "MODEL=model-scout" "absent failover state changed the primary model"
  assert_contains "$out" "CANDIDATE_INDEX=0" "absent failover state should keep candidate zero"
  pass "absent provider-failover state preserves primary selection"
}

test_disabled_primary_provider_selects_backup() {
  local home out
  require_jq
  home=$(make_profile_home disabled-provider)
  printf '%s\n' '{"version":1,"providers":{"openai":{"disabled":true,"reason":"usage limit"}},"harnesses":{}}' \
    > "$home/state/provider-failover.json"

  out=$(run_profile "$home" file_discovery) || fail "provider failover resolution failed"$'\n'"$out"
  assert_contains "$out" "HARNESS=grok" "disabled OpenAI provider should select the Grok backup"
  assert_contains "$out" "MODEL=model-scout-backup" "provider failover selected the wrong backup model"
  assert_contains "$out" "CANDIDATE_INDEX=1" "provider failover should report backup index one"
  assert_contains "$out" "FALLBACK_FROM=codex" "provider failover should report the primary harness"
  assert_contains "$out" "provider 'openai' disabled: usage limit" "provider failover reason missing"
  pass "disabled primary provider selects the first healthy backup"
}

test_missing_primary_harness_selects_backup() {
  local home out bindings
  require_jq
  home=$(make_profile_home missing-harness)
  bindings="$home/state/crew-profile-bindings.json"
  jq '.scout_fast.harness = "missing-harness-command"' "$bindings" > "$bindings.tmp"
  mv "$bindings.tmp" "$bindings"

  out=$(run_profile "$home" file_discovery) || fail "missing harness failover resolution failed"$'\n'"$out"
  assert_contains "$out" "HARNESS=grok" "missing primary harness command should select the backup"
  assert_contains "$out" "CANDIDATE_INDEX=1" "missing harness failover should report backup index one"
  assert_contains "$out" "harness command 'missing-harness-command' not found" "missing harness reason missing"
  pass "unavailable primary harness command selects the first healthy backup"
}

test_expired_provider_disable_selects_primary() {
  local home out
  require_jq
  home=$(make_profile_home expired-provider)
  printf '%s\n' '{"version":1,"providers":{"openai":{"disabled":true,"reason":"old limit","until":"2020-01-01T00:00:00Z"}},"harnesses":{}}' \
    > "$home/state/provider-failover.json"

  out=$(FM_FAILOVER_NOW_EPOCH=2000000000 run_profile "$home" file_discovery) \
    || fail "expired provider circuit resolution failed"$'\n'"$out"
  assert_contains "$out" "HARNESS=codex" "expired provider circuit should leave the primary enabled"
  assert_contains "$out" "CANDIDATE_INDEX=0" "expired provider circuit should select candidate zero"
  pass "expired until no longer disables a provider"
}

test_env_override_precedence() {
  local home out
  require_jq
  home=$(make_profile_home env-override)

  # FM_HARNESS__/FM_MODEL__/FM_EFFORT__ beat the state binding wholesale.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_HARNESS__IMPLEMENTER_BALANCED=grok \
    FM_MODEL__IMPLEMENTER_BALANCED=grok-4 \
    FM_EFFORT__IMPLEMENTER_BALANCED=medium \
    "$PROFILE" normal_code_change 2>&1) || fail "env override resolution failed"$'\n'"$out"
  assert_contains "$out" "HARNESS=grok" "FM_HARNESS__ override ignored"
  assert_contains "$out" "MODEL=grok-4" "FM_MODEL__ override ignored"
  assert_contains "$out" "EFFORT=medium" "FM_EFFORT__ override ignored"
  assert_contains "$out" "BINDING_SOURCE=env" "env override must report source=env, not state"

  # FM_PROFILE__<CLASS> remaps the class to a different profile.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROFILE__NORMAL_CODE_CHANGE=reviewer_deep \
    "$PROFILE" normal_code_change 2>&1) || fail "FM_PROFILE__ remap failed"
  assert_contains "$out" "PROFILE=reviewer_deep" "FM_PROFILE__ class remap ignored"
  assert_contains "$out" "MODEL=model-reviewdeep" "remapped profile binding not applied"
  pass "env overrides beat state bindings and remap classes with correct precedence"
}

test_counterpart_selection_both_directions() {
  local home out
  require_jq
  home=$(make_profile_home counterpart)

  out=$(run_profile "$home" final_governance_review --implementer-provider openai) \
    || fail "openai-implementer counterpart resolution failed"$'\n'"$out"
  assert_contains "$out" "HARNESS=claude" "openai implementer must route to the anthropic counterpart (claude)"
  assert_contains "$out" "MODEL=model-review-anthropic" "openai implementer counterpart model wrong"
  assert_contains "$out" "PROVIDER=anthropic" "openai implementer counterpart provider wrong"

  out=$(run_profile "$home" final_governance_review --implementer-provider anthropic) \
    || fail "anthropic-implementer counterpart resolution failed"
  assert_contains "$out" "HARNESS=codex" "anthropic implementer must route to the openai counterpart (codex)"
  assert_contains "$out" "MODEL=model-review-openai" "anthropic implementer counterpart model wrong"
  assert_contains "$out" "PROVIDER=openai" "anthropic implementer counterpart provider wrong"
  pass "counterpart bindings select the provider-independent reviewer in both directions"
}

test_counterpart_backup_preserves_independence() {
  local home out
  require_jq
  home=$(make_profile_home counterpart-backup)
  printf '%s\n' '{"version":1,"providers":{"anthropic":{"disabled":true,"reason":"usage limit"}},"harnesses":{}}' \
    > "$home/state/provider-failover.json"

  out=$(run_profile "$home" final_governance_review --implementer-provider openai) \
    || fail "counterpart backup resolution failed"$'\n'"$out"
  assert_contains "$out" "HARNESS=grok" "disabled counterpart primary should select its Grok backup"
  assert_contains "$out" "PROVIDER=xai" "counterpart backup provider should be xAI"
  assert_contains "$out" "CANDIDATE_INDEX=1" "counterpart backup should report candidate index one"
  assert_not_contains "$out" "PROVIDER=openai" "counterpart backup must not use the implementer's provider"
  pass "counterpart entry backups fail over without weakening provider independence"
}

test_same_provider_hard_fail_resolver() {
  local home out
  require_jq
  home=$(make_profile_home same-provider)

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_HARNESS__REVIEWER_INDEPENDENT=codex \
    "$PROFILE" final_governance_review --implementer-provider openai 2>&1) \
    && fail "same-provider governance resolution should hard-fail"
  assert_contains "$out" "requires a provider independent of the implementer" \
    "same-provider failure message missing"
  pass "provider-independent class hard-fails when it resolves to the implementer's provider"
}

test_missing_implementer_fails_for_counterpart() {
  local home out
  require_jq
  home=$(make_profile_home missing-implementer)

  out=$(run_profile "$home" final_governance_review) \
    && fail "counterpart profile with no implementer context should fail"
  assert_contains "$out" "implementer provider is unknown" \
    "missing-implementer failure message missing"
  pass "counterpart profile with no implementer provider fails loudly"
}

# --- SHIM group ---------------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # fm-spawn leases the worktree via `treehouse get --lease`, whose stdout is the
  # leased path; echo the pool worktree the case advertises via FM_FAKE_PANE_PATH.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" claude codex grok
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <id...>: a sandbox home with the committed class map,
# seeded runtime bindings, a fake tmux/treehouse, and a real isolated worktree.
make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/.treehouse/pool/1/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  cp "$ROOT/docs/examples/crew-profiles.json" "$home/config/crew-profiles.json"
  write_bindings "$home/state/crew-profile-bindings.json"
  mkdir -p "$case_dir/.treehouse/pool/1"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  # CASE_DIR is kept in the record for parity with tests/fm-spawn-dispatch-profile.test.sh
  # even though these cases do not reference it.
  # shellcheck disable=SC2034
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_shim() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SHIM" "$@" 2>&1
}

assert_meta_axes() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_shim_normal_code_change_passes_concrete_axes() {
  local rec id out status meta launch meta_text
  require_jq
  id=shim-normal-z1
  rec=$(make_spawn_case shim-normal "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --class normal_code_change)
  status=$?
  expect_code 0 "$status" "normal_code_change dispatch should succeed with no new flags"
  assert_contains "$out" "spawned $id harness=claude" "shim did not spawn the resolved claude harness"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_axes "$meta" claude model-impl high
  assert_grep "class=normal_code_change" "$meta" "meta missing class provenance"
  assert_grep "profile=implementer_balanced" "$meta" "meta missing profile provenance"
  assert_grep "provider=anthropic" "$meta" "meta missing provider provenance"
  assert_grep "binding_source=state" "$meta" "meta missing binding_source provenance"
  meta_text=$(cat "$meta")
  assert_not_contains "$meta_text" "implementer_provider=" "unused implementer_provider should not be recorded"
  assert_not_contains "$meta_text" "implementer_task=" "unused implementer_task should not be recorded"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'model-impl' --effort 'high'" \
    "shim did not thread the resolved concrete axes into the upstream launch"
  pass "normal_code_change resolves to concrete axes, launches, and records provenance"
}

test_shim_records_failover_provenance() {
  local rec id out status meta launch
  require_jq
  id=shim-failover-z12
  rec=$(make_spawn_case shim-failover "$id")
  read_case_record "$rec"
  printf '%s\n' '{"version":1,"providers":{"anthropic":{"disabled":true,"reason":"usage limit"}},"harnesses":{}}' \
    > "$HOME_DIR/state/provider-failover.json"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class normal_code_change)
  status=$?
  expect_code 0 "$status" "profile failover spawn should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_axes "$meta" grok model-impl-backup high
  assert_grep "candidate_index=1" "$meta" "meta missing selected backup index"
  assert_grep "fallback_from=claude" "$meta" "meta missing primary failover origin"
  assert_grep "fallback_reason=claude: provider 'anthropic' disabled: usage limit" "$meta" \
    "meta missing provider failover reason"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'model-impl-backup' --reasoning-effort 'high'" \
    "shim did not launch the resolved backup axes"
  pass "fm-spawn-profile records backup selection provenance in task meta"
}

test_shim_profile_flag_resolves() {
  local rec id out status meta
  require_jq
  id=shim-profile-z2
  rec=$(make_spawn_case shim-profile "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --profile implementer_balanced)
  status=$?
  expect_code 0 "$status" "--profile dispatch should succeed"
  assert_contains "$out" "spawned $id harness=claude" "--profile did not resolve the binding harness"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_axes "$meta" claude model-impl high
  assert_grep "profile=implementer_balanced" "$meta" "meta missing profile provenance for --profile path"
  assert_grep "class=" "$meta" "meta should record an (empty) class line for a bare --profile spawn"
  pass "--profile resolves a profile name directly"
}

test_shim_governance_openai_routes_anthropic() {
  local rec id out status meta launch
  require_jq
  id=shim-gov-openai-z3
  rec=$(make_spawn_case shim-gov-openai "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class final_governance_review --implementer-provider openai)
  status=$?
  expect_code 0 "$status" "openai implementer should route to the anthropic counterpart"
  assert_contains "$out" "spawned $id harness=claude" "governance review did not route to claude"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_axes "$meta" claude model-review-anthropic high
  assert_grep "class=final_governance_review" "$meta" "meta missing governance class"
  assert_grep "profile=reviewer_independent" "$meta" "meta missing reviewer_independent profile"
  assert_grep "provider=anthropic" "$meta" "meta missing anthropic reviewer provider"
  assert_grep "implementer_provider=openai" "$meta" "meta missing implementer provider"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'model-review-anthropic' --effort 'high'" \
    "openai implementer did not thread the anthropic counterpart model into the launch"
  pass "governance review with an openai implementer routes to the anthropic counterpart via the shim"
}

test_shim_governance_anthropic_routes_openai() {
  local rec id out status meta launch
  require_jq
  id=shim-gov-anthropic-z4
  rec=$(make_spawn_case shim-gov-anthropic "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class final_governance_review --implementer-provider anthropic)
  status=$?
  expect_code 0 "$status" "anthropic implementer should route to the openai counterpart"
  assert_contains "$out" "spawned $id harness=codex" "governance review did not route to codex"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_axes "$meta" codex model-review-openai xhigh
  assert_grep "provider=openai" "$meta" "meta missing openai reviewer provider"
  assert_grep "implementer_provider=anthropic" "$meta" "meta missing implementer provider"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'model-review-openai' -c 'model_reasoning_effort=\"xhigh\"' --dangerously-bypass-approvals-and-sandbox" \
    "anthropic implementer did not thread the openai counterpart model into the launch"
  pass "governance review with an anthropic implementer routes to the openai counterpart via the shim"
}

test_shim_same_provider_hard_fails() {
  local rec id out status
  require_jq
  id=shim-same-provider-z5
  rec=$(make_spawn_case shim-same-provider "$id")
  read_case_record "$rec"

  out=$(FM_HARNESS__REVIEWER_INDEPENDENT=codex \
    run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --class final_governance_review --implementer-provider openai)
  status=$?
  expect_code 1 "$status" "same-provider governance review should hard-fail through the shim"
  assert_contains "$out" "requires a provider independent of the implementer" \
    "shim did not surface fm-profile's same-provider error"
  assert_absent "$HOME_DIR/state/$id.meta" "same-provider failure must not spawn or write meta"
  pass "same-provider governance review hard-fails through the shim and spawns nothing"
}

test_shim_missing_implementer_fails() {
  local rec id out status
  require_jq
  id=shim-missing-impl-z6
  rec=$(make_spawn_case shim-missing-impl "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class final_governance_review)
  status=$?
  expect_code 1 "$status" "counterpart profile with no implementer context should fail through the shim"
  assert_contains "$out" "implementer provider is unknown" \
    "shim did not surface fm-profile's missing-implementer error"
  assert_absent "$HOME_DIR/state/$id.meta" "missing implementer context must not spawn or write meta"
  pass "governance review with no implementer context fails through the shim and spawns nothing"
}

test_shim_implementer_task_routes_and_records() {
  local rec id impl out status meta
  require_jq
  id=shim-for-task-z7
  impl=shim-impl-z7
  rec=$(make_spawn_case shim-for-task "$id")
  read_case_record "$rec"
  printf 'provider=openai\n' > "$HOME_DIR/state/$impl.meta"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class final_governance_review --implementer-task "$impl")
  status=$?
  expect_code 0 "$status" "implementer task meta should route the governance review"
  assert_contains "$out" "spawned $id harness=claude" "--implementer-task did not route to the anthropic counterpart"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_axes "$meta" claude model-review-anthropic high
  assert_grep "implementer_task=$impl" "$meta" "meta missing implementer task reference"
  pass "--implementer-task forwards to fm-profile --for-task and records the task reference"
}

test_shim_explicit_model_overrides_binding() {
  local rec id out status meta launch
  require_jq
  id=shim-model-override-z8
  rec=$(make_spawn_case shim-model-override "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class normal_code_change --model custom-model)
  status=$?
  expect_code 0 "$status" "explicit --model alongside --class should succeed"
  meta="$HOME_DIR/state/$id.meta"
  # Harness/effort still from the binding; model overridden per-axis.
  assert_meta_axes "$meta" claude custom-model high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'custom-model' --effort 'high'" \
    "explicit --model did not override the binding model in the launch"
  pass "explicit --model overrides the binding model per axis while harness/effort stay resolved"
}

test_shim_explicit_harness_drops_binding_model_effort() {
  local rec id out status meta launch
  require_jq
  id=shim-harness-override-z9
  rec=$(make_spawn_case shim-harness-override "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class normal_code_change --harness codex)
  status=$?
  expect_code 0 "$status" "explicit --harness alongside --class should succeed"
  assert_contains "$out" "explicit harness 'codex' overrides profile" "shim did not warn about the harness override"
  assert_contains "$out" "spawned $id harness=codex" "explicit harness override did not launch codex"
  meta="$HOME_DIR/state/$id.meta"
  # The binding's model/effort belong to claude, so they are dropped for codex.
  assert_grep "harness=codex" "$meta" "meta missing overridden harness"
  assert_grep "model=default" "$meta" "overridden harness must drop the binding model"
  assert_grep "effort=default" "$meta" "overridden harness must drop the binding effort"
  assert_grep "provider=openai" "$meta" "provider must be re-derived from the overriding harness"
  grep -qx 'binding_source=' "$meta" || fail "binding_source must be empty on an explicit-harness override"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "model_reasoning_effort" "dropped effort must not reach the codex launch"
  pass "explicit --harness override drops the binding model/effort and re-derives the provider"
}

test_shim_requires_class_or_profile() {
  local rec id out status
  id=shim-noflag-z10
  rec=$(make_spawn_case shim-noflag "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "shim without --class/--profile should fail"
  assert_contains "$out" "requires --class" "shim did not explain the required class/profile flag"
  assert_absent "$HOME_DIR/state/$id.meta" "a rejected dispatch must not write meta"
  pass "shim requires --class or --profile and refuses a bare concrete-axis spawn"
}

test_shim_class_and_profile_mutually_exclusive() {
  local rec id out status
  id=shim-both-z11
  rec=$(make_spawn_case shim-both "$id")
  read_case_record "$rec"

  out=$(run_shim "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --class normal_code_change --profile implementer_balanced)
  status=$?
  expect_code 1 "$status" "--class and --profile together should fail"
  assert_contains "$out" "mutually exclusive" "shim did not reject --class + --profile"
  assert_absent "$HOME_DIR/state/$id.meta" "a rejected dispatch must not write meta"
  pass "shim rejects --class and --profile together"
}

test_class_to_profile_lookup
test_grok_build_class_mapping_is_preserved
test_state_binding_lookup
test_no_failover_state_preserves_primary
test_disabled_primary_provider_selects_backup
test_missing_primary_harness_selects_backup
test_expired_provider_disable_selects_primary
test_env_override_precedence
test_counterpart_selection_both_directions
test_counterpart_backup_preserves_independence
test_same_provider_hard_fail_resolver
test_missing_implementer_fails_for_counterpart
test_shim_normal_code_change_passes_concrete_axes
test_shim_records_failover_provenance
test_shim_profile_flag_resolves
test_shim_governance_openai_routes_anthropic
test_shim_governance_anthropic_routes_openai
test_shim_same_provider_hard_fails
test_shim_missing_implementer_fails
test_shim_implementer_task_routes_and_records
test_shim_explicit_model_overrides_binding
test_shim_explicit_harness_drops_binding_model_effort
test_shim_requires_class_or_profile
test_shim_class_and_profile_mutually_exclusive

echo "# all fm-spawn-profile tests passed"
