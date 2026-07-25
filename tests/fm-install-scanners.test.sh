#!/usr/bin/env bash
# Static supply-chain and offline-runtime guards for the scanner installation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-scanners.sh"
DB_INSTALLER="$ROOT/bin/fm-install-osv-db.sh"
RUNNER="$ROOT/bin/fm-scanner.sh"
LOCK="$ROOT/docs/scanner/package-lock.json"

for version in 8.30.1 1.75.0 2.4.0 1.7.12 0.16.0 1.7.1; do
  assert_grep "$version" "$INSTALLER" "scanner installer is missing pin $version"
done
# shellcheck disable=SC2016  # the assertion matches a literal installer variable
[ "$(grep -Fc 'sha256sum "$output"' "$INSTALLER")" -eq 1 ] ||
  fail "standalone scanner downloads must share one checksum-verifying fetch path"
assert_grep 'npm ci' "$INSTALLER" "Node scanner bundle must install from the lockfile"
jq -e '
  .lockfileVersion==3
  and .packages[""].dependencies.eslint=="9.39.5"
  and .packages[""].dependencies["eslint-plugin-n"]=="18.2.2"
  and .packages[""].dependencies["eslint-plugin-sonarjs"]=="4.2.0"
  and .packages[""].dependencies["eslint-plugin-security"]=="4.0.1"
  and .packages[""].dependencies.ajv=="8.17.1"
' "$LOCK" >/dev/null || fail "Node scanner direct dependencies are not exactly pinned"
pass "scanner installers pin binaries by checksum and Node tools by lockfile"

assert_no_grep 'trufflehog' "$RUNNER" "trufflehog must never enter the runtime battery"
assert_no_grep 'trufflehog' "$INSTALLER" "trufflehog must never enter the pinned installer"
assert_grep 'OSV_ARGS=(--offline ' "$RUNNER" "OSV runtime scan must use fully offline mode"
assert_no_grep 'download-offline-databases' "$RUNNER" "the verification runtime must never update or download the OSV DB"
assert_grep 'download-offline-databases' "$DB_INSTALLER" "OSV DB network refresh belongs only in the explicit provisioning helper"
pass "runtime battery excludes trufflehog and prevents scanner network access"

echo "# all fm-install-scanners tests passed"
