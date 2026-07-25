#!/usr/bin/env bash
# fm-install-scanners.sh - install the pinned Phase 1 scanner battery.
#
# Every standalone release asset is checksum-verified before installation.
# npm runs with lifecycle scripts, audit, and funding calls disabled and consumes
# the committed lockfile under docs/scanner, so direct and transitive JS scanner
# versions are exact. This installer performs network downloads; the installed
# scanners themselves are invoked offline by bin/fm-scanner.sh.
#
# Supported platform: Linux x86_64, matching the fleet's current scanner hosts.
#
# Usage:
#   fm-install-scanners.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION=${1:?usage: fm-install-scanners.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-scanners.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  printf 'fm-install-scanners.sh: only Linux x86_64 is currently pinned\n' >&2
  exit 1
}
for tool in curl sha256sum tar npm; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'fm-install-scanners.sh: required installer tool missing: %s\n' "$tool" >&2
    exit 1
  }
done

mkdir -p "$DESTINATION/bin" "$DESTINATION/node"
rm -f "$DESTINATION/tools-ready.json" "$DESTINATION/provisioned.json"

fetch() {
  local url=$1 checksum=$2 output=$3 actual
  curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"
  actual=$(sha256sum "$output" | awk '{print $1}')
  [ "$actual" = "$checksum" ] || {
    printf 'fm-install-scanners.sh: checksum mismatch for %s\n' "$(basename "$output")" >&2
    exit 1
  }
}

GITLEAKS_VERSION=8.30.1
GITLEAKS_ARCHIVE="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
fetch \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${GITLEAKS_ARCHIVE}" \
  551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb \
  "$TMP/$GITLEAKS_ARCHIVE"
tar -xzf "$TMP/$GITLEAKS_ARCHIVE" -C "$TMP" gitleaks
install -m 0755 "$TMP/gitleaks" "$DESTINATION/bin/gitleaks"

OXLINT_VERSION=1.75.0
OXLINT_ARCHIVE=oxlint-x86_64-unknown-linux-gnu.tar.gz
fetch \
  "https://github.com/oxc-project/oxc/releases/download/apps_v${OXLINT_VERSION}/${OXLINT_ARCHIVE}" \
  a059ed00b7248086d093f331f28183f7696ec379f9da28a342903aa63cbe4d07 \
  "$TMP/$OXLINT_ARCHIVE"
tar -xzf "$TMP/$OXLINT_ARCHIVE" -C "$TMP"
install -m 0755 "$TMP/oxlint-x86_64-unknown-linux-gnu" "$DESTINATION/bin/oxlint"

OSV_VERSION=2.4.0
OSV_ASSET=osv-scanner_linux_amd64
fetch \
  "https://github.com/google/osv-scanner/releases/download/v${OSV_VERSION}/${OSV_ASSET}" \
  15314940c10d26af9c6649f150b8a47c1262e8fc7e17b1d1029b0e479e8ed8a0 \
  "$TMP/$OSV_ASSET"
install -m 0755 "$TMP/$OSV_ASSET" "$DESTINATION/bin/osv-scanner"

ACTIONLINT_VERSION=1.7.12
ACTIONLINT_ARCHIVE="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
fetch \
  "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${ACTIONLINT_ARCHIVE}" \
  8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 \
  "$TMP/$ACTIONLINT_ARCHIVE"
tar -xzf "$TMP/$ACTIONLINT_ARCHIVE" -C "$TMP" actionlint
install -m 0755 "$TMP/actionlint" "$DESTINATION/bin/actionlint"

RUFF_VERSION=0.16.0
RUFF_ARCHIVE=ruff-x86_64-unknown-linux-gnu.tar.gz
fetch \
  "https://github.com/astral-sh/ruff/releases/download/${RUFF_VERSION}/${RUFF_ARCHIVE}" \
  98001c995a134d95f9bc83106a7f94b552971b583f1c0ab75fb656a881e13865 \
  "$TMP/$RUFF_ARCHIVE"
tar -xzf "$TMP/$RUFF_ARCHIVE" -C "$TMP"
install -m 0755 "$TMP/ruff-x86_64-unknown-linux-gnu/ruff" "$DESTINATION/bin/ruff"

JQ_VERSION=1.7.1
JQ_ASSET=jq-linux-amd64
fetch \
  "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${JQ_ASSET}" \
  5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5 \
  "$TMP/$JQ_ASSET"
install -m 0755 "$TMP/$JQ_ASSET" "$DESTINATION/bin/jq"

"$ROOT/bin/fm-install-shellcheck.sh" "$DESTINATION/bin" >/dev/null

install -m 0644 "$ROOT/docs/scanner/package.json" "$DESTINATION/node/package.json"
install -m 0644 "$ROOT/docs/scanner/package-lock.json" "$DESTINATION/node/package-lock.json"
npm ci --prefix "$DESTINATION/node" --ignore-scripts --no-audit --no-fund

"$DESTINATION/bin/gitleaks" --version
"$DESTINATION/bin/oxlint" --version
"$DESTINATION/bin/osv-scanner" --version
"$DESTINATION/bin/actionlint" --version
"$DESTINATION/bin/ruff" --version
"$DESTINATION/bin/jq" --version
"$DESTINATION/bin/shellcheck" --version
FM_SCANNER_NODE_DIR="$DESTINATION/node" node "$ROOT/bin/fm-eslint-scanner.mjs" --version
FM_SCANNER_NODE_DIR="$DESTINATION/node" node "$ROOT/bin/fm-json-schema-scanner.mjs" --version

TOOLS_READY_TMP="$DESTINATION/tools-ready.json.tmp.$$"
printf '%s\n' \
  '{"schema":"firstmate/scanner-tools-ready/1","status":"ready","versions":{"actionlint":"1.7.12","ajv":"8.17.1","eslint":"9.39.5","eslint-plugin-n":"18.2.2","eslint-plugin-security":"4.0.1","eslint-plugin-sonarjs":"4.2.0","gitleaks":"8.30.1","jq":"1.7.1","osv-scanner":"2.4.0","oxlint":"1.75.0","ruff":"0.16.0","shellcheck":"0.11.0"}}' \
  > "$TOOLS_READY_TMP"
mv -f "$TOOLS_READY_TMP" "$DESTINATION/tools-ready.json"
