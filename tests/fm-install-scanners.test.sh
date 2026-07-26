#!/usr/bin/env bash
# Static supply-chain and offline-runtime guards for the scanner installation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-scanners.sh"
DB_INSTALLER="$ROOT/bin/fm-install-osv-db.sh"
RUNNER="$ROOT/bin/fm-scanner.sh"
LOCK="$ROOT/docs/scanner/package-lock.json"
POLICY="$ROOT/docs/scanner/blocking-policy.json"

for version in 8.30.1 1.75.0 2.4.0 1.7.12 0.16.0 1.7.1; do
  assert_grep "$version" "$INSTALLER" "scanner installer is missing pin $version"
done
# shellcheck disable=SC2016  # the assertion matches a literal installer variable
[ "$(grep -Fc 'sha256sum "$output"' "$INSTALLER")" -eq 1 ] ||
  fail "standalone scanner downloads must share one checksum-verifying fetch path"
assert_grep 'npm ci' "$INSTALLER" "Node scanner bundle must install from the lockfile"
assert_grep 'firstmate/scanner-tools-ready/1' "$INSTALLER" "tool provisioning must publish a closed readiness manifest"
assert_grep 'firstmate/scanner-provisioned/1' "$DB_INSTALLER" "OSV provisioning must publish the final adoption manifest"
# shellcheck disable=SC2016  # assertions intentionally match literal script variables
assert_grep 'rm -f "$DESTINATION/tools-ready.json" "$DESTINATION/provisioned.json"' "$INSTALLER" \
  "a reinstall must invalidate prior readiness before provisioning"
# shellcheck disable=SC2016  # assertion intentionally matches a literal script variable
assert_grep 'rm -f "$SCANNER_DIR/provisioned.json"' "$DB_INSTALLER" \
  "an OSV refresh must invalidate prior readiness before provisioning"
jq -e '
  .lockfileVersion==3
  and .packages[""].dependencies.eslint=="9.39.5"
  and .packages[""].dependencies["eslint-plugin-n"]=="18.2.2"
  and .packages[""].dependencies["eslint-plugin-sonarjs"]=="4.2.0"
  and .packages[""].dependencies["eslint-plugin-security"]=="4.0.1"
  and .packages[""].dependencies.ajv=="8.17.1"
' "$LOCK" >/dev/null || fail "Node scanner direct dependencies are not exactly pinned"
pass "scanner installers pin binaries by checksum and Node tools by lockfile"

jq -e '
  .schema=="firstmate/scanner-blocking-policy/1"
  and ([.scanners[].budget_s]|add)<30
  and ([.scanners[].scanner]|length)==8
  and any(.scanners[];
    .scanner=="eslint"
    and (.blocking_severities|index("error"))!=null
    and (.report_only_rule_prefixes|index("security/"))!=null)
' "$POLICY" >/dev/null ||
  fail "committed scanner policy must reserve time and keep eslint-plugin-security report-only"
pass "scanner policy closes blocking thresholds and fair per-scanner budgets"

assert_no_grep 'trufflehog' "$RUNNER" "trufflehog must never enter the runtime battery"
assert_no_grep 'trufflehog' "$INSTALLER" "trufflehog must never enter the pinned installer"
assert_grep 'OSV_ARGS=(--offline ' "$RUNNER" "OSV runtime scan must use fully offline mode"
assert_no_grep 'download-offline-databases' "$RUNNER" "the verification runtime must never update or download the OSV DB"
assert_grep 'download-offline-databases' "$DB_INSTALLER" "OSV DB network refresh belongs only in the explicit provisioning helper"
pass "runtime battery excludes trufflehog and prevents scanner network access"

echo "# all fm-install-scanners tests passed"
