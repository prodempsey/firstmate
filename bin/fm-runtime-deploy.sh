#!/usr/bin/env bash
# fm-runtime-deploy.sh - deterministic template->runtime deployment of the
# manifested implementation artifacts (bin/ scripts and tests) from THIS
# firstmate template checkout into a target runtime FM_HOME.
#
# Usage:
#   fm-runtime-deploy.sh --target <FM_HOME> [--manifest <path>] [--dry-run]
#     --target    the runtime FM_HOME to deploy into (its bin/, tests/, data/).
#     --manifest  the deploy manifest (default:
#                 docs/model-economy/bindings-deploy-manifest.json). Its schema
#                 and the state/ refusal are owned by fm-runtime-manifest-lib.sh.
#     --dry-run   validate the manifest and report what WOULD be deployed, copy
#                 nothing, write no record.
#
# Guarantees:
#   - Only manifested artifacts are copied; the manifest never targets state/, so
#     the live bindings, its metadata sidecar, and its fingerprint sidecar
#     (production-local) are NEVER deployed.
#   - Each artifact is replaced atomically (temp file in the destination dir,
#     then mv) preserving the source's mode bits, and its sha256 is verified
#     against the canonical source after the copy.
#   - After copying, the target's newly deployed validator is run against the
#     target's live bindings and the semantic fingerprint is compared to the
#     pre-deploy value; the production-local state files are additionally proven
#     byte-unchanged. Any failure aborts and restores this run's own pre-deploy
#     backups (new files are removed).
#   - A deployment record is written to the target's
#     data/model-economy/deploy-manifest.json recording each artifact, its
#     canonical sha256, destination, installed sha256, the source repo HEAD, and
#     a timestamp, so the runtime can always report which canonical HEAD it runs.
#
# Never run this against the real production runtime without captain approval;
# firstmate performs the live deployment.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bin/fm-runtime-manifest-lib.sh
. "$SCRIPT_DIR/fm-runtime-manifest-lib.sh"

die() { echo "fm-runtime-deploy: $*" >&2; exit 1; }

TARGET=
MANIFEST="$REPO/docs/model-economy/bindings-deploy-manifest.json"
DRY=0
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
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "unexpected argument: $a" ;;
  esac
done
[ -z "$want" ] || die "--$want requires a value"
[ -n "$TARGET" ] || die "usage: fm-runtime-deploy.sh --target <FM_HOME> [--manifest <path>] [--dry-run]"

command -v jq >/dev/null 2>&1 || die "jq not found (the repo's JSON dependency)"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"
[ -d "$TARGET" ] || die "target FM_HOME does not exist: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

# Parse + validate the manifest (this also enforces the state/ refusal).
ARTIFACTS=$(fm_rt_manifest_artifacts "$MANIFEST") || die "invalid manifest: $MANIFEST"

TBIND="$TARGET/state/crew-profile-bindings.json"

# Validate the target's bindings with the given validator, always scoped to the
# TARGET's own config/state so an operator's ambient FM_HOME cannot misdirect the
# check. Never --write-sidecar: that would write into state/.
validate_target_fp() {
  env -u FM_ROOT_OVERRIDE FM_HOME="$TARGET" FM_CONFIG_OVERRIDE="$TARGET/config" \
    FM_STATE_OVERRIDE="$TARGET/state" "$1" "$TBIND" --fingerprint-only 2>/dev/null
}

# Pre-deploy: capture the target's live-bindings validity and semantic
# fingerprint using the repo validator (the target may not have one yet).
PRE_FP=""
PRE_VALID=0
if [ -f "$TBIND" ]; then
  if PRE_FP=$(validate_target_fp "$REPO/bin/fm-bindings-validate.sh"); then
    PRE_VALID=1
  else
    PRE_VALID=0
    PRE_FP=""
  fi
fi
# Raw pre-hashes of the production-local state trio, to prove state is untouched.
pre_hash_bind=$(fm_rt_sha256 "$TBIND")
pre_hash_meta=$(fm_rt_sha256 "${TBIND%.json}.meta.json")
pre_hash_fp=$(fm_rt_sha256 "${TBIND%.json}.fingerprint")

if [ "$DRY" -eq 1 ]; then
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
    [ -f "$REPO/$src" ] || die "manifest source missing in repo: $src"
    printf 'DRY would deploy %s -> %s (sha %s)\n' "$src" "$dest" "$(fm_rt_sha256 "$REPO/$src")"
  done <<< "$ARTIFACTS"
  echo "fm-runtime-deploy: dry run complete (manifest valid, no files changed)"
  exit 0
fi

BACKUP_DIR=$(mktemp -d)
CREATED_NEW=()
BACKED_UP=()
RECORD_ITEMS=()

rollback() {
  local entry dest bpath
  for entry in "${BACKED_UP[@]:-}"; do
    [ -n "$entry" ] || continue
    dest=${entry%%|*}
    bpath=${entry#*|}
    cp -p "$bpath" "$TARGET/$dest" 2>/dev/null || true
  done
  for dest in "${CREATED_NEW[@]:-}"; do
    [ -n "$dest" ] || continue
    rm -f "$TARGET/$dest"
  done
  rm -rf "$BACKUP_DIR"
}

while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  srcpath="$REPO/$src"
  [ -f "$srcpath" ] || { rollback; die "manifest source missing in repo: $src"; }
  src_sha=$(fm_rt_sha256 "$srcpath")
  destpath="$TARGET/$dest"
  destdir=$(dirname "$destpath")
  mkdir -p "$destdir" || { rollback; die "could not create $destdir"; }

  if [ -f "$destpath" ]; then
    bpath="$BACKUP_DIR/$(printf '%s' "$dest" | tr '/' '_')"
    cp -p "$destpath" "$bpath" || { rollback; die "could not back up $dest"; }
    BACKED_UP+=("$dest|$bpath")
  else
    CREATED_NEW+=("$dest")
  fi

  tmp="$destdir/.fm-runtime-deploy.tmp.$$"
  cp "$srcpath" "$tmp" || { rollback; die "could not stage $dest"; }
  chmod --reference="$srcpath" "$tmp" || { rm -f "$tmp"; rollback; die "could not preserve mode for $dest"; }
  mv -f "$tmp" "$destpath" || { rm -f "$tmp"; rollback; die "could not install $dest"; }

  inst_sha=$(fm_rt_sha256 "$destpath")
  [ "$inst_sha" = "$src_sha" ] || { rollback; die "checksum mismatch after copy for $dest (canonical $src_sha != installed $inst_sha)"; }
  RECORD_ITEMS+=("$(jq -nc --arg a "$src" --arg c "$src_sha" --arg d "$dest" --arg i "$inst_sha" \
    '{artifact:$a, canonical_sha256:$c, dest:$d, installed_sha256:$i}')")
done <<< "$ARTIFACTS"

# Post-deploy verification. Run the just-deployed validator against the target's
# live bindings; require it to stay valid with an identical fingerprint when it
# was valid before. Never --write-sidecar (would touch state/).
POST_FP=""
POST_OK=1
FAILMSG=
if [ -f "$TBIND" ] && [ -x "$TARGET/bin/fm-bindings-validate.sh" ]; then
  if POST_FP=$(validate_target_fp "$TARGET/bin/fm-bindings-validate.sh"); then
    if [ "$PRE_VALID" -eq 1 ] && [ "$POST_FP" != "$PRE_FP" ]; then
      POST_OK=0
      FAILMSG="semantic fingerprint changed ($PRE_FP -> $POST_FP)"
    fi
  elif [ "$PRE_VALID" -eq 1 ]; then
    POST_OK=0
    FAILMSG="post-deploy bindings validation failed though pre-deploy was valid"
  fi
fi

# Prove no production-local state file was touched by the deploy.
if [ "$POST_OK" -eq 1 ]; then
  if [ "$pre_hash_bind" != "$(fm_rt_sha256 "$TBIND")" ] ||
     [ "$pre_hash_meta" != "$(fm_rt_sha256 "${TBIND%.json}.meta.json")" ] ||
     [ "$pre_hash_fp" != "$(fm_rt_sha256 "${TBIND%.json}.fingerprint")" ]; then
    POST_OK=0
    FAILMSG="a production-local state file changed during deploy"
  fi
fi

if [ "$POST_OK" -ne 1 ]; then
  rollback
  die "post-deploy verification failed: $FAILMSG (restored pre-deploy backups)"
fi

# Write the deployment record.
REC_DIR="$TARGET/data/model-economy"
mkdir -p "$REC_DIR" || { rollback; die "could not create $REC_DIR"; }
head_sha=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
items_json=$(printf '%s\n' "${RECORD_ITEMS[@]}" | jq -s '.')
jq -n --arg ts "$ts" --arg head "$head_sha" --arg manifest "$MANIFEST" \
  --arg prefp "$PRE_FP" --arg postfp "$POST_FP" --argjson artifacts "$items_json" \
  '{deployed_at:$ts, source_repo_head:$head, manifest:$manifest, pre_deploy_fingerprint:$prefp, post_deploy_fingerprint:$postfp, artifacts:$artifacts}' \
  > "$REC_DIR/deploy-manifest.json" || { rollback; die "could not write deploy record"; }

rm -rf "$BACKUP_DIR"
echo "fm-runtime-deploy: deployed ${#RECORD_ITEMS[@]} artifact(s) to $TARGET (source HEAD $head_sha); record at data/model-economy/deploy-manifest.json"
