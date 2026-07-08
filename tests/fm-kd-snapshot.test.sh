#!/usr/bin/env bash
# Behavior tests for bin/fm-kd-snapshot.sh.
#
# fm-kd-snapshot.sh is a thin wrapper: it drives a render engine
# (chrome-devtools-axi by default, or an --engine / FM_KD_SNAPSHOT_ENGINE
# override) to produce ONE self-contained HTML artifact, verifies the output,
# and optionally registers it with krakendesign. These tests stub both external
# tools and pin the orchestration: argument validation, which engine runs, that
# registration happens only when asked, and that an empty render fails loudly.
# They do not exercise real headless rendering, which needs a browser.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAP="$ROOT/bin/fm-kd-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-kd-snapshot)

# make_stubs <dir>: a fakebin with a chrome-devtools-axi that logs its subcommand
# to cda.log (and any eval JS to cda-eval.log) and echoes CDA_EVAL_HTML on eval,
# plus a krakendesign that logs its args to kd.log. Echoes the fakebin dir.
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/chrome-devtools-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$dir/cda.log"
if [ "\$1" = eval ]; then
  printf '%s\n' "\$2" >> "$dir/cda-eval.log"
  printf '%s' "\${CDA_EVAL_HTML-<!DOCTYPE html><html><body>snap</body></html>}"
fi
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  cat > "$fakebin/krakendesign" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/kd.log"
printf '%s\n' 'registered: http://127.0.0.1:8787/helm.html?kd=deadbeef'
exit 0
SH
  chmod +x "$fakebin/krakendesign"
  printf '%s\n' "$fakebin"
}

test_script_parses() {
  bash -n "$SNAP" 2>&1 || fail "fm-kd-snapshot.sh fails bash -n"
  pass "fm-kd-snapshot.sh: bash -n succeeds"
}

test_requires_url_and_output() {
  local dir fakebin out status
  dir="$TMP_ROOT/args"; mkdir -p "$dir"
  fakebin=$(make_stubs "$dir")
  out=$(PATH="$fakebin:$PATH" "$SNAP" 2>&1); status=$?
  expect_code 2 "$status" "no args should exit 2"
  assert_contains "$out" "need <url> and <output.kd.html>" "missing-args error should name the required positionals"

  out=$(PATH="$fakebin:$PATH" "$SNAP" http://only-url 2>&1); status=$?
  expect_code 2 "$status" "url without output should exit 2"
  pass "fm-kd-snapshot.sh: requires url and output path"
}

test_builtin_render_writes_and_does_not_register() {
  local dir fakebin outfile status
  dir="$TMP_ROOT/builtin"; mkdir -p "$dir"
  fakebin=$(make_stubs "$dir")
  outfile="$dir/render.kd.html"
  PATH="$fakebin:$PATH" "$SNAP" http://127.0.0.1:8787/helm.html "$outfile" >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "built-in render should exit 0"
  assert_present "$outfile" "artifact was not written"
  assert_grep "snap" "$outfile" "artifact missing the rendered snapshot body"
  assert_grep "open" "$dir/cda.log" "chrome engine open was not invoked"
  assert_grep "eval" "$dir/cda.log" "chrome engine eval (inliner) was not invoked"
  assert_absent "$dir/kd.log" "krakendesign must not run without --title/--register"
  pass "fm-kd-snapshot.sh: built-in render writes a self-contained artifact and skips registration"
}

test_title_registers_with_krakendesign() {
  local dir fakebin outfile status
  dir="$TMP_ROOT/register"; mkdir -p "$dir"
  fakebin=$(make_stubs "$dir")
  outfile="$dir/render.kd.html"
  PATH="$fakebin:$PATH" "$SNAP" http://x "$outfile" --title "Bridge Watch Floor" >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--title render should exit 0"
  assert_present "$dir/kd.log" "krakendesign was not invoked for --title"
  assert_grep "$outfile" "$dir/kd.log" "krakendesign was not passed the artifact path"
  assert_grep "--title Bridge Watch Floor" "$dir/kd.log" "krakendesign was not passed the title"
  pass "fm-kd-snapshot.sh: --title registers the artifact with krakendesign"
}

test_engine_override_bypasses_chrome() {
  local dir fakebin engine outfile status
  dir="$TMP_ROOT/engine"; mkdir -p "$dir"
  fakebin=$(make_stubs "$dir")
  engine="$dir/engine.sh"
  cat > "$engine" <<'SH'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  [ "$1" = --out ] && { out="$2"; shift; }
  shift
done
printf '%s\n' '<html>engine-produced</html>' > "$out"
SH
  chmod +x "$engine"
  outfile="$dir/render.kd.html"
  FM_KD_SNAPSHOT_ENGINE="$engine" PATH="$fakebin:$PATH" "$SNAP" http://y "$outfile" >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "engine-override render should exit 0"
  assert_grep "engine-produced" "$outfile" "engine override did not produce the artifact"
  assert_absent "$dir/cda.log" "chrome engine must not run when an engine override is set"
  pass "fm-kd-snapshot.sh: engine override renders without chrome-devtools-axi"
}

test_freeze_js_runs_before_capture() {
  local dir fakebin outfile freeze status
  dir="$TMP_ROOT/freeze"; mkdir -p "$dir"
  fakebin=$(make_stubs "$dir")
  freeze="$dir/freeze.js"
  printf '%s\n' 'window.__FM_FROZEN_BOARD__ = 42;' > "$freeze"
  outfile="$dir/render.kd.html"
  PATH="$fakebin:$PATH" "$SNAP" http://z "$outfile" --freeze-js "$freeze" >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--freeze-js render should exit 0"
  assert_grep "__FM_FROZEN_BOARD__" "$dir/cda-eval.log" "freeze snippet was not eval'd in-page"
  pass "fm-kd-snapshot.sh: --freeze-js snippet is evaluated before capture"

  local out2 status2
  out2=$(PATH="$fakebin:$PATH" "$SNAP" http://z "$dir/x.kd.html" --freeze-js "$dir/nope.js" 2>&1); status2=$?
  expect_code 2 "$status2" "missing --freeze-js file should exit 2"
  assert_contains "$out2" "--freeze-js file not found" "missing freeze file should be named in the error"
  pass "fm-kd-snapshot.sh: a missing --freeze-js file is rejected"
}

test_empty_render_fails() {
  local dir fakebin outfile status
  dir="$TMP_ROOT/empty"; mkdir -p "$dir"
  fakebin=$(make_stubs "$dir")
  outfile="$dir/render.kd.html"
  CDA_EVAL_HTML="" PATH="$fakebin:$PATH" "$SNAP" http://x "$outfile" >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "an empty render should fail with exit 1"
  pass "fm-kd-snapshot.sh: an empty render fails loudly"
}

test_script_parses
test_requires_url_and_output
test_builtin_render_writes_and_does_not_register
test_title_registers_with_krakendesign
test_engine_override_bypasses_chrome
test_freeze_js_runs_before_capture
test_empty_render_fails
