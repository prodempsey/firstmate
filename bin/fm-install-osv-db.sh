#!/usr/bin/env bash
# fm-install-osv-db.sh - explicitly refresh OSV-Scanner's local vulnerability DB.
#
# The verification gate never downloads or updates this database. Operators run
# this bounded helper when provisioning or refreshing a scanner installation.
#
# Usage:
#   fm-install-osv-db.sh <scanner-directory>
set -eu

SCANNER_DIR=${1:?usage: fm-install-osv-db.sh <scanner-directory>}
OSV="$SCANNER_DIR/bin/osv-scanner"
JQ="$SCANNER_DIR/bin/jq"
DB="$SCANNER_DIR/osv-db"
[ -x "$OSV" ] || {
  printf 'fm-install-osv-db.sh: pinned osv-scanner is missing under %s\n' "$SCANNER_DIR" >&2
  exit 1
}
if [ ! -x "$JQ" ] || ! "$JQ" -e '
    .schema=="firstmate/scanner-tools-ready/1"
    and .status=="ready"
    and (keys == ["schema","status","versions"])
  ' "$SCANNER_DIR/tools-ready.json" >/dev/null 2>&1; then
  printf 'fm-install-osv-db.sh: complete pinned tool provisioning is not proven under %s\n' "$SCANNER_DIR" >&2
  exit 1
fi
mkdir -p "$DB"
rm -f "$SCANNER_DIR/provisioned.json"

TIMEOUT_BIN=""
for candidate in timeout gtimeout; do
  if command -v "$candidate" >/dev/null 2>&1; then TIMEOUT_BIN=$candidate; break; fi
done
[ -n "$TIMEOUT_BIN" ] || {
  printf 'fm-install-osv-db.sh: timeout or gtimeout is required for the bounded refresh\n' >&2
  exit 1
}

EMPTY=$(mktemp -d "${TMPDIR:-/tmp}/fm-osv-db.XXXXXX")
trap 'rm -rf "$EMPTY"' EXIT
OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="$DB" \
  "$TIMEOUT_BIN" -k 5 300 "$OSV" --offline --download-offline-databases scan source "$EMPTY"

PROVISIONED_TMP="$SCANNER_DIR/provisioned.json.tmp.$$"
printf '%s\n' '{"schema":"firstmate/scanner-provisioned/1","status":"ready"}' > "$PROVISIONED_TMP"
mv -f "$PROVISIONED_TMP" "$SCANNER_DIR/provisioned.json"
