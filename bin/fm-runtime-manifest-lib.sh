#!/usr/bin/env bash
# fm-runtime-manifest-lib.sh - shared manifest contract for the deterministic
# template->runtime deployment mechanism (bin/fm-runtime-deploy.sh and
# bin/fm-runtime-drift.sh). Sourced, never executed directly.
#
# It owns, in one place, so the deploy and drift sides can never drift apart:
#   - the deploy-manifest schema (manifest_version 1; a non-empty artifacts[]
#     array of {source, dest} string pairs);
#   - artifact iteration (fm_rt_manifest_artifacts emits one "source<TAB>dest"
#     line per artifact after validating the whole manifest);
#   - the hard refusal to ever target state/ (fm_rt_assert_safe_dest), because
#     the live bindings, its metadata sidecar, and its fingerprint sidecar are
#     production-local runtime state and are NEVER deployed;
#   - the sha256 and executable-bit helpers both sides compare with.
#
# The manifest lists template-relative sources and target-relative destinations
# only; canonical and installed sha256 values are computed live from the two
# checkouts, so a routine artifact edit needs no manifest change.

# fm_rt_sha256 <file>: print the file's sha256 (bare hex), or nothing if absent.
fm_rt_sha256() {
  [ -f "$1" ] || return 0
  sha256sum "$1" | awk '{print $1}'
}

# fm_rt_is_exec <file>: succeed when the file has an executable bit set.
fm_rt_is_exec() {
  [ -x "$1" ]
}

# fm_rt_assert_safe_dest <dest>: reject any manifest destination that is not a
# safe target-relative path, or that targets state/. Prints the reason to stderr
# and returns 1 on refusal; returns 0 when the dest is safe.
fm_rt_assert_safe_dest() {
  local dest=$1
  case "$dest" in
    /*)             echo "fm-runtime: unsafe manifest dest (absolute path): $dest" >&2; return 1 ;;
    *..*)           echo "fm-runtime: unsafe manifest dest (parent escape): $dest" >&2; return 1 ;;
    state|state/*)  echo "fm-runtime: refusing manifest dest under state/: $dest (production-local, never deployed)" >&2; return 1 ;;
  esac
  return 0
}

# fm_rt_manifest_artifacts <manifest>: validate the manifest and print one
# "source<TAB>dest" line per artifact. Returns nonzero (with a stderr reason) if
# the manifest is missing, not JSON, an unsupported version, malformed, or names
# an unsafe destination.
fm_rt_manifest_artifacts() {
  local manifest=$1 ver src dest
  [ -f "$manifest" ] || { echo "fm-runtime: manifest not found: $manifest" >&2; return 1; }
  jq -e . "$manifest" >/dev/null 2>&1 || { echo "fm-runtime: manifest is not valid JSON: $manifest" >&2; return 1; }
  ver=$(jq -r '.manifest_version // empty' "$manifest")
  [ "$ver" = "1" ] || { echo "fm-runtime: unsupported manifest_version '$ver' (supported: 1)" >&2; return 1; }
  jq -e '(.artifacts | type) == "array" and (.artifacts | length) > 0' "$manifest" >/dev/null 2>&1 \
    || { echo "fm-runtime: manifest.artifacts must be a non-empty array" >&2; return 1; }
  jq -e 'all(.artifacts[]; (.source | type == "string") and (.source | length > 0) and (.dest | type == "string") and (.dest | length > 0))' \
    "$manifest" >/dev/null 2>&1 \
    || { echo "fm-runtime: each artifact needs a non-empty string source and dest" >&2; return 1; }
  while IFS=$'\t' read -r src dest; do
    fm_rt_assert_safe_dest "$dest" || return 1
    printf '%s\t%s\n' "$src" "$dest"
  done < <(jq -r '.artifacts[] | [.source, .dest] | @tsv' "$manifest")
}
