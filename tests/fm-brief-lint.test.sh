#!/usr/bin/env bash
# Behavior tests for bin/fm-brief-lint.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-brief-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-lint)

write_brief() {
  local file=$1
  mkdir -p "$(dirname "$file")"
  cat > "$file"
}

test_clean_default_home_brief_exits_zero() {
  local home brief out status
  home="$TMP_ROOT/clean-home"
  brief="$home/data/clean-a1/brief.md"
  write_brief "$brief" <<'EOF'
# Task
Route this request by capability and existing project context.
EOF

  out=$(FM_HOME="$home" "$LINT" 2>&1)
  status=$?
  expect_code 0 "$status" "clean default FM_HOME brief should exit 0"
  [ -z "$out" ] || fail "clean default FM_HOME brief should produce no output"$'\n'"--- output ---"$'\n'"$out"
  pass "fm-brief-lint: clean default FM_HOME brief exits 0"
}

test_gpt_model_id_is_flagged() {
  local brief out status
  brief="$TMP_ROOT/gpt-home/data/gpt-a1/brief.md"
  write_brief "$brief" <<'EOF'
# Task
Run this on gpt-5.5 for best results.
EOF

  out=$("$LINT" "$brief" 2>&1)
  status=$?
  expect_code 1 "$status" "gpt-* model id should fail lint"
  assert_contains "$out" "$brief:2:gpt-5.5" "gpt-* finding did not include path, line, and token"
  pass "fm-brief-lint: gpt-* model id is flagged"
}

test_bare_opus_word_is_flagged() {
  local brief out status
  brief="$TMP_ROOT/opus-home/data/opus-a1/brief.md"
  write_brief "$brief" <<'EOF'
# Task
Use Opus because this needs deeper reasoning.
EOF

  out=$("$LINT" "$brief" 2>&1)
  status=$?
  expect_code 1 "$status" "bare opus word should fail lint"
  assert_contains "$out" "$brief:2:Opus" "bare opus finding did not include path, line, and token"
  pass "fm-brief-lint: bare opus word is flagged"
}

test_claude_product_names_are_not_flagged() {
  local brief out status
  brief="$TMP_ROOT/claude-product-home/data/claude-product-a1/brief.md"
  write_brief "$brief" <<'EOF'
# Task
Use claude-code with the claude-api skill, then test claude-login and the claude-orange theme.
EOF

  out=$("$LINT" "$brief" 2>&1)
  status=$?
  expect_code 0 "$status" "claude product and skill names should not fail lint"
  [ -z "$out" ] || fail "claude product and skill names should produce no output"$'\n'"--- output ---"$'\n'"$out"
  pass "fm-brief-lint: claude product and skill names are not flagged"
}

test_claude_model_ids_are_still_flagged() {
  local brief out status
  brief="$TMP_ROOT/claude-model-home/data/claude-model-a1/brief.md"
  write_brief "$brief" <<'EOF'
# Task
Run one pass on claude-opus-4-8 and another on claude-sonnet-5.
EOF

  out=$("$LINT" "$brief" 2>&1)
  status=$?
  expect_code 1 "$status" "claude commercial model ids should fail lint"
  assert_contains "$out" "$brief:2:claude-opus-4-8" \
    "claude-opus finding did not include path, line, and token"
  assert_contains "$out" "$brief:2:claude-sonnet-5" \
    "claude-sonnet finding did not include path, line, and token"
  assert_not_contains "$out" "$brief:2:claude-sonnet-5." \
    "claude model token should not include sentence punctuation"
  pass "fm-brief-lint: claude commercial model ids are still flagged"
}

test_model_names_ok_frontmatter_skips_file() {
  local brief out status
  brief="$TMP_ROOT/skip-home/data/skip-a1/brief.md"
  write_brief "$brief" <<'EOF'
---
model-names-ok: model routing fixture
---
# Task
Compare gpt-5 and opus for routing behavior.
EOF

  out=$("$LINT" "$brief" 2>&1)
  status=$?
  expect_code 0 "$status" "model-names-ok frontmatter should skip file"
  assert_contains "$out" "$brief: skipped (model-names-ok: model routing fixture)" \
    "skip output did not report the model-names-ok reason"
  assert_not_contains "$out" "$brief:5:gpt-5" "skipped file should not emit findings"
  pass "fm-brief-lint: model-names-ok frontmatter skips file"
}

test_no_files_and_empty_glob_exit_zero() {
  local home out status
  home="$TMP_ROOT/no-briefs-home"
  mkdir -p "$home/data"

  out=$(FM_HOME="$home" "$LINT" 2>&1)
  status=$?
  expect_code 0 "$status" "no default briefs should exit 0"
  [ -z "$out" ] || fail "no default briefs should produce no output"$'\n'"--- output ---"$'\n'"$out"

  out=$("$LINT" "$TMP_ROOT/missing/*/brief.md" 2>&1)
  status=$?
  expect_code 0 "$status" "empty explicit glob should exit 0"
  [ -z "$out" ] || fail "empty explicit glob should produce no output"$'\n'"--- output ---"$'\n'"$out"
  pass "fm-brief-lint: no files and empty globs exit 0"
}

test_clean_default_home_brief_exits_zero
test_gpt_model_id_is_flagged
test_bare_opus_word_is_flagged
test_claude_product_names_are_not_flagged
test_claude_model_ids_are_still_flagged
test_model_names_ok_frontmatter_skips_file
test_no_files_and_empty_glob_exit_zero
