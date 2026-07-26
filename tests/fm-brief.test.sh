#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" \
    FM_FC_LEDGER="$ROOT/docs/failure-classes/ledger.jsonl" \
    "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

# Ship and scout briefs must carry every current standing failure-class
# invariant from the ledger's proven folded snapshot. FC-001 and FC-002 remain
# pinned verbatim as an additional regression guard.
test_builder_standing_invariants_block() {
  local home id brief snapshot cid invariant
  home="$TMP_ROOT/standing-invariants-home"
  write_registry "$home"

  local fc001 fc002
  fc001='A conclusion may be drawn only from ONE atomic pass that positively proves conformance to a single declared, closed schema; authority defaults to none and is NEVER inferred from the absence of a failing check.'
  fc002='An obligation is cleared ONLY by positive proof from a fresh, structurally-complete, authoritative snapshot that provably enumerates that obligation'\''s status; absent/stale/corrupt/partial coverage RETAINS the prior fact unchanged (fail-open when CREATING a block, fail-closed when DISCHARGING one).'

  snapshot=$("$ROOT/bin/fm-failure-class.sh" list --json) \
    || fail "failure-class authority refused the committed ledger"
  assert_contains "$snapshot" "$fc001" "ledger FC-001 invariant text drifted from the expected string"
  assert_contains "$snapshot" "$fc002" "ledger FC-002 invariant text drifted from the expected string"

  for id_proj in "brief-inv-nomistakes:no-registry-proj" "brief-inv-directpr:direct-proj" "brief-inv-localonly:local-proj"; do
    id=${id_proj%%:*}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "${id_proj##*:}" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Standing invariants" "$brief" "$id: ship brief missing the Standing invariants block"
    while IFS=$'\t' read -r cid invariant; do
      assert_grep "- $cid: $invariant" "$brief" \
        "$id: ship brief missing current invariant $cid verbatim"
    done < <(printf '%s' "$snapshot" | jq -r '.[] | [.id, .invariant] | @tsv')
    assert_grep "docs/failure-classes/ledger.jsonl" "$brief" "$id: ship brief missing the full-ledger pointer"
  done

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-inv-scout no-registry-proj --scout >/dev/null 2>&1
  brief="$home/data/brief-inv-scout/brief.md"
  assert_grep "# Standing invariants" "$brief" "scout brief missing the Standing invariants block"
  while IFS=$'\t' read -r cid invariant; do
    assert_grep "- $cid: $invariant" "$brief" \
      "scout brief missing current invariant $cid verbatim"
  done < <(printf '%s' "$snapshot" | jq -r '.[] | [.id, .invariant] | @tsv')
  assert_grep "docs/failure-classes/ledger.jsonl" "$brief" \
    "scout brief missing the full-ledger pointer"
  pass "fm-brief.sh: ship and scout briefs embed every current invariant from the proven ledger snapshot"
}

test_builder_brief_refuses_unavailable_or_empty_ledger() {
  local home ledger empty kind id out status=0
  home="$TMP_ROOT/unreadable-ledger-home"
  ledger="$TMP_ROOT/unreadable-ledger.jsonl"
  mkdir -p "$home/data"
  cp "$ROOT/docs/failure-classes/ledger.jsonl" "$ledger"
  chmod 000 "$ledger"

  out=$(FM_HOME="$home" FM_FC_LEDGER="$ledger" \
    "$ROOT/bin/fm-brief.sh" brief-unreadable someproj 2>&1) || status=$?
  expect_code 1 "$status" "ship scaffold must refuse an unreadable failure-class ledger"
  assert_contains "$out" "refusing to scaffold ship brief" \
    "ship scaffold's unreadable-ledger refusal was not loud"
  assert_absent "$home/data/brief-unreadable/brief.md" \
    "ship scaffold emitted a brief after the ledger authority refused"

  status=0
  FM_HOME="$home" FM_FC_LEDGER="$ledger" FM_SECONDMATE_CHARTER=ops \
    "$ROOT/bin/fm-brief.sh" secondmate-unreadable --secondmate --no-projects \
    >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "secondmate charter must not depend on the failure-class ledger"
  assert_present "$home/data/secondmate-unreadable/brief.md" \
    "secondmate charter was not scaffolded independently of the ledger"
  chmod 600 "$ledger"

  empty="$TMP_ROOT/empty-ledger.jsonl"
  : > "$empty"
  for kind in ship scout; do
    id="brief-empty-$kind"
    status=0
    if [ "$kind" = scout ]; then
      out=$(FM_HOME="$home" FM_FC_LEDGER="$empty" \
        "$ROOT/bin/fm-brief.sh" "$id" someproj --scout 2>&1) || status=$?
    else
      out=$(FM_HOME="$home" FM_FC_LEDGER="$empty" \
        "$ROOT/bin/fm-brief.sh" "$id" someproj 2>&1) || status=$?
    fi
    expect_code 1 "$status" "$kind scaffold must refuse a zero-byte failure-class ledger"
    assert_contains "$out" "proven failure-class snapshot contains zero invariants" \
      "$kind scaffold's zero-invariant refusal was not loud"
    assert_absent "$home/data/$id/brief.md" \
      "$kind scaffold emitted a brief from a zero-byte ledger"
  done
  pass "fm-brief.sh: builder scaffolds fail closed on unavailable or empty ledgers without changing secondmate charters"
}

test_cue_lint_done_contract_and_qa_rerun() {
  local home id brief invocation
  home="$TMP_ROOT/cue-lint-contract-home"
  invocation="$ROOT/bin/fm-failure-class.sh cue-lint"
  write_registry "$home"

  for id_proj in "brief-cue-nomistakes:no-registry-proj" "brief-cue-directpr:direct-proj" "brief-cue-localonly:local-proj"; do
    id=${id_proj%%:*}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "${id_proj##*:}" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "Before appending any \`done:\` status, run \`$invocation\`" "$brief" \
      "$id: ship Definition of done missing the exact cue-lint invocation"
    assert_grep "explicitly list each remaining hit with a one-line justification in the \`done:\` line" "$brief" \
      "$id: ship Definition of done missing the justified-hit requirement"
    assert_grep "An unexplained cue hit is a contract violation." "$brief" \
      "$id: ship Definition of done does not make unexplained hits a contract violation"
  done

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-cue-qa-bundle someproj --scout \
    --gauntlet-bundle "$home/data/candidate/verify-bundle.json" >/dev/null 2>&1
  assert_grep "re-run \`$invocation\` from the candidate worktree" \
    "$home/data/brief-cue-qa-bundle/brief.md" \
    "bundle-backed QA brief missing the exact cue-lint rerun"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-cue-qa-waived someproj --scout \
    --gauntlet-waived "fixture waiver" >/dev/null 2>&1
  assert_grep "Run \`$invocation\` from the candidate worktree" \
    "$home/data/brief-cue-qa-waived/brief.md" \
    "waived QA brief missing the exact cue-lint rerun"
  pass "fm-brief.sh: all ship modes self-check cue hits and QA briefs rerun the same entrypoint"
}

# Scout/QA briefs must carry the Review practice block: neutral software-QA
# framing (no adversarial/attack vocabulary that trips provider filters) and the
# fleet-bridge headless-Chrome rig guidance in place of chrome-devtools-axi.
test_scout_review_practice_block() {
  local home brief
  home="$TMP_ROOT/review-practice-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-review-scout someproj --scout >/dev/null 2>&1
  brief="$home/data/brief-review-scout/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "# Review practice" "$brief" "scout brief missing the Review practice block"
  assert_grep "software quality assurance" "$brief" "Review practice block lost the neutral-QA framing"
  assert_grep "not adversarial or attack framing" "$brief" "Review practice block lost the no-adversarial-vocabulary guidance"
  assert_grep "For fleet-bridge rendered verification" "$brief" "Review practice block lost the fleet-bridge browser guidance"
  # shellcheck disable=SC2016 # Literal backticks must remain in the brief text.
  assert_grep 'set `CHROME_BIN` per the header of `test/bridge-card-open.mjs`' "$brief" \
    "Review practice block lost the CHROME_BIN headless-Chrome rig recipe pointer"
  assert_grep "never chrome-devtools-axi" "$brief" "Review practice block must steer fleet-bridge verification off chrome-devtools-axi"

  # Ship briefs get their own invariants block, not this scout/QA guidance.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-review-ship someproj >/dev/null 2>&1
  assert_no_grep "# Review practice" "$home/data/brief-review-ship/brief.md" \
    "ship brief must not carry the scout-only Review practice block"
  pass "fm-brief.sh: scout briefs carry neutral-QA framing and the fleet-bridge headless-Chrome recipe"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_builder_standing_invariants_block
test_builder_brief_refuses_unavailable_or_empty_ledger
test_cue_lint_done_contract_and_qa_rerun
test_scout_review_practice_block
test_pause_verb_override_renders_all_brief_scaffolds
