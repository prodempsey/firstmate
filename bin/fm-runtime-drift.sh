#!/usr/bin/env bash
# fm-runtime-drift.sh - report drift between THIS firstmate template checkout and
# a target runtime FM_HOME, for the manifested implementation artifacts only.
#
# Usage:
#   fm-runtime-drift.sh --target <FM_HOME> [--manifest <path>]
#     --target    the runtime FM_HOME to compare against.
#     --manifest  the deploy manifest (default:
#                 docs/model-economy/bindings-deploy-manifest.json).
#
# Per manifested artifact it reports one of: same, differs, missing (not
# deployed), plus any executable-bit mismatch, and it reports a missing deploy
# record (data/model-economy/deploy-manifest.json). It exits nonzero on any
# drift. It never writes and never auto-overwrites.
#
# It deliberately inspects ONLY the manifested artifacts (bin/ scripts, tests):
# the manifest never lists state/, so the production-local bindings, its metadata
# sidecar, and its fingerprint sidecar are never compared and never flagged as
# drift merely for differing from any committed example.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bin/fm-runtime-manifest-lib.sh
. "$SCRIPT_DIR/fm-runtime-manifest-lib.sh"

die() { echo "fm-runtime-drift: $*" >&2; exit 2; }

TARGET=
MANIFEST="$REPO/docs/model-economy/bindings-deploy-manifest.json"
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      target) TARGET=$a ;;
      manifest) MANIFEST=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --target) want=target ;;
    --manifest) want=manifest ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unexpected argument: $a" ;;
  esac
done
[ -z "$want" ] || die "--$want requires a value"
[ -n "$TARGET" ] || die "usage: fm-runtime-drift.sh --target <FM_HOME> [--manifest <path>]"

command -v jq >/dev/null 2>&1 || die "jq not found (the repo's JSON dependency)"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"
[ -d "$TARGET" ] || die "target FM_HOME does not exist: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"

ARTIFACTS=$(fm_rt_manifest_artifacts "$MANIFEST") || die "invalid manifest: $MANIFEST"

DRIFT=0
while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  srcpath="$REPO/$src"
  destpath="$TARGET/$dest"
  if [ ! -f "$srcpath" ]; then
    printf '%-9s %s (source missing in repo)\n' "error" "$src"
    DRIFT=1
    continue
  fi
  if [ ! -f "$destpath" ]; then
    printf '%-9s %s (not deployed in target)\n' "missing" "$dest"
    DRIFT=1
    continue
  fi
  status=same
  [ "$(fm_rt_sha256 "$srcpath")" = "$(fm_rt_sha256 "$destpath")" ] || { status=differs; DRIFT=1; }
  execnote=
  if fm_rt_is_exec "$srcpath" && ! fm_rt_is_exec "$destpath"; then
    execnote=" [exec-bit: repo +x, target -x]"
    DRIFT=1
  elif ! fm_rt_is_exec "$srcpath" && fm_rt_is_exec "$destpath"; then
    execnote=" [exec-bit: repo -x, target +x]"
    DRIFT=1
  fi
  printf '%-9s %s%s\n' "$status" "$dest" "$execnote"
done <<< "$ARTIFACTS"

REC="$TARGET/data/model-economy/deploy-manifest.json"
if [ ! -f "$REC" ]; then
  printf '%-9s %s\n' "no-record" "target has no data/model-economy/deploy-manifest.json (provenance unknown)"
  DRIFT=1
else
  printf '%-9s deployed from source HEAD %s\n' "record" "$(jq -r '.source_repo_head // "unknown"' "$REC" 2>/dev/null || echo unknown)"
fi

if [ "$DRIFT" -ne 0 ]; then
  echo "fm-runtime-drift: DRIFT detected" >&2
  exit 1
fi
echo "fm-runtime-drift: clean (all manifested artifacts match; deploy record present)"
