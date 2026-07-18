#!/usr/bin/env bash
# Behavior tests for the deterministic template->runtime deployment mechanism:
# bin/fm-runtime-deploy.sh, bin/fm-runtime-drift.sh, and the shared
# bin/fm-runtime-manifest-lib.sh.
#
# Fully sandboxed: deploys FROM this template checkout INTO a throwaway target
# FM_HOME built under a mktemp root. Never runs against a real runtime, never
# touches any live path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEPLOY="$ROOT/bin/fm-runtime-deploy.sh"
DRIFT="$ROOT/bin/fm-runtime-drift.sh"
MANIFEST="$ROOT/docs/model-economy/bindings-deploy-manifest.json"
TMP_ROOT=$(fm_test_tmproot fm-runtime-deploy)

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
command -v sha256sum >/dev/null 2>&1 || fail "test host must provide sha256sum"

# A valid live bindings + metadata sidecar for the throwaway runtime's state/.
# Profiles are known to the repo's docs/examples/crew-profiles.json (the
# fallback the pre-deploy validator consults). Placeholder model strings only.
write_fake_runtime_state() {
  local state=$1
  mkdir -p "$state"
  cat > "$state/crew-profile-bindings.json" <<'JSON'
{
  "_comment": "throwaway runtime bindings - production-local, never deployed",
  "scout_fast":     { "harness": "codex", "model": "gpt-model-a", "effort": "high" },
  "implementer_balanced": { "harness": "claude", "model": "claude-opus-model", "effort": "high" }
}
JSON
  cat > "$state/crew-profile-bindings.meta.json" <<'JSON'
{
  "schema_version": 1,
  "config_role": "crew-profile-bindings-live",
  "environment": "throwaway-runtime",
  "authority": "deploy mechanism tests",
  "owner": "throwaway runtime",
  "source_example": "docs/examples/crew-profile-bindings.json",
  "commit_policy": "never committed",
  "description": "throwaway runtime bindings for deploy mechanism checks"
}
JSON
}

# make_fake_home <name>: a throwaway FM_HOME with bin/, data/, and a state/ that
# already holds a valid bindings+meta pair (as a production runtime would).
make_fake_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin" "$home/data"
  write_fake_runtime_state "$home/state"
  printf '%s\n' "$home"
}

sha() { sha256sum "$1" | awk '{print $1}'; }

# --- deploy succeeds, verifies checksums, and records provenance --------------

test_deploy_installs_manifested_artifacts_only() {
  local home out rc
  home=$(make_fake_home deploy-ok)

  out=$("$DEPLOY" --target "$home" 2>&1)
  rc=$?
  expect_code 0 "$rc" "deploy into a clean throwaway home should succeed"$'\n'"$out"

  # Every manifested artifact is installed with a matching checksum and exec bit.
  local src dest
  while IFS=$'\t' read -r src dest; do
    assert_present "$home/$dest" "manifested artifact $dest was not deployed"
    [ "$(sha "$ROOT/$src")" = "$(sha "$home/$dest")" ] || fail "deployed $dest checksum differs from source"
    if [ -x "$ROOT/$src" ]; then
      [ -x "$home/$dest" ] || fail "deployed $dest lost its executable bit"
    fi
  done < <(jq -r '.artifacts[] | [.source, .dest] | @tsv' "$MANIFEST")

  pass "deploy installs every manifested artifact with a verified checksum and exec bit"
}

test_deploy_never_touches_state() {
  local home before_bind before_meta
  home=$(make_fake_home deploy-state)
  before_bind=$(sha "$home/state/crew-profile-bindings.json")
  before_meta=$(sha "$home/state/crew-profile-bindings.meta.json")

  "$DEPLOY" --target "$home" >/dev/null 2>&1 || fail "deploy should succeed"

  [ "$before_bind" = "$(sha "$home/state/crew-profile-bindings.json")" ] \
    || fail "deploy modified the production-local bindings file"
  [ "$before_meta" = "$(sha "$home/state/crew-profile-bindings.meta.json")" ] \
    || fail "deploy modified the production-local metadata sidecar"
  # The deploy must not write a fingerprint sidecar into state/.
  assert_absent "$home/state/crew-profile-bindings.fingerprint" \
    "deploy wrote a fingerprint sidecar into state/ (state must be untouched)"
  pass "deploy never touches production-local state/ files"
}

test_deploy_writes_provenance_record() {
  local home rec head
  home=$(make_fake_home deploy-record)
  "$DEPLOY" --target "$home" >/dev/null 2>&1 || fail "deploy should succeed"

  rec="$home/data/model-economy/deploy-manifest.json"
  assert_present "$rec" "deploy did not write the provenance record"
  jq -e . "$rec" >/dev/null 2>&1 || fail "deploy record is not valid JSON"

  head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
  [ "$(jq -r '.source_repo_head' "$rec")" = "$head" ] || fail "record source_repo_head wrong"
  [ "$(jq -r '.artifacts | length' "$rec")" = "$(jq -r '.artifacts | length' "$MANIFEST")" ] \
    || fail "record artifact count differs from the manifest"
  # Each record entry names artifact, canonical sha, dest, installed sha.
  jq -e 'all(.artifacts[]; has("artifact") and has("canonical_sha256") and has("dest") and has("installed_sha256"))' \
    "$rec" >/dev/null 2>&1 || fail "record artifacts missing required fields"
  # Canonical == installed for every recorded artifact.
  jq -e 'all(.artifacts[]; .canonical_sha256 == .installed_sha256)' "$rec" >/dev/null 2>&1 \
    || fail "record shows a canonical/installed checksum mismatch"
  pass "deploy records artifact, canonical/installed sha, source HEAD, and timestamp"
}

# --- drift: clean after deploy, then detects a corrupted artifact ------------

test_drift_clean_after_deploy_then_detects_corruption() {
  local home out rc
  home=$(make_fake_home drift)
  "$DEPLOY" --target "$home" >/dev/null 2>&1 || fail "deploy should succeed"

  out=$("$DRIFT" --target "$home" 2>&1)
  rc=$?
  expect_code 0 "$rc" "drift should be clean immediately after a deploy"$'\n'"$out"
  assert_contains "$out" "clean" "drift did not report clean after deploy"

  # Corrupt the deployed validator; drift must now fail and flag it.
  printf '\n# corruption\n' >> "$home/bin/fm-bindings-validate.sh"
  out=$("$DRIFT" --target "$home" 2>&1)
  rc=$?
  expect_code 1 "$rc" "drift should exit nonzero once an artifact is corrupted"
  assert_contains "$out" "differs" "drift did not flag the corrupted validator as differing"
  pass "drift is clean after deploy and detects a corrupted artifact"
}

test_drift_reports_missing_artifact_and_record() {
  local home out rc
  # A never-deployed home: no manifested artifacts, no deploy record.
  home="$TMP_ROOT/drift-missing"
  mkdir -p "$home/bin" "$home/state" "$home/data"
  write_fake_runtime_state "$home/state"

  out=$("$DRIFT" --target "$home" 2>&1)
  rc=$?
  expect_code 1 "$rc" "drift on an un-deployed home should exit nonzero"
  assert_contains "$out" "missing" "drift did not report the un-deployed artifacts as missing"
  assert_contains "$out" "no-record" "drift did not report the missing deploy record"
  pass "drift reports missing artifacts and a missing deploy record"
}

# --- safety: state/ destinations are refused; dry-run copies nothing ----------

test_deploy_refuses_state_destination() {
  local home badmanifest out rc
  home=$(make_fake_home refuse-state)
  badmanifest="$TMP_ROOT/bad-manifest.json"
  cat > "$badmanifest" <<'JSON'
{
  "manifest_version": 1,
  "artifacts": [
    { "source": "bin/fm-bindings-validate.sh", "dest": "state/crew-profile-bindings.json" }
  ]
}
JSON
  out=$("$DEPLOY" --target "$home" --manifest "$badmanifest" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "deploy must refuse a manifest that targets state/"
  assert_contains "$out" "state/" "deploy did not explain the state/ refusal"
  assert_absent "$home/data/model-economy/deploy-manifest.json" \
    "a refused deploy must not write a provenance record"
  pass "deploy refuses any manifest destination under state/"
}

test_dry_run_changes_nothing() {
  local home out rc
  home=$(make_fake_home dry-run)
  out=$("$DEPLOY" --target "$home" --dry-run 2>&1)
  rc=$?
  expect_code 0 "$rc" "--dry-run should succeed"$'\n'"$out"
  assert_contains "$out" "DRY would deploy" "--dry-run did not report the planned deploy"
  assert_absent "$home/bin/fm-bindings-validate.sh" "--dry-run must not copy any artifact"
  assert_absent "$home/data/model-economy/deploy-manifest.json" "--dry-run must not write a record"
  pass "--dry-run reports the plan and changes nothing"
}

test_deploy_installs_manifested_artifacts_only
test_deploy_never_touches_state
test_deploy_writes_provenance_record
test_drift_clean_after_deploy_then_detects_corruption
test_drift_reports_missing_artifact_and_record
test_deploy_refuses_state_destination
test_dry_run_changes_nothing

echo "# all fm-runtime-deploy tests passed"
