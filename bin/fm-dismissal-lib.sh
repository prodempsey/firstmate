#!/usr/bin/env bash
# Shared dismissal-ledger helpers.

FM_DISMISSAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_dismissal_ledger_prove() {
  "$FM_DISMISSAL_LIB_DIR/fm-dismissal-validate.sh" prove "$1"
}

fm_scanner_stack_fingerprint() {
  local root=${1:?repository root required}
  local relative
  {
    printf '%s\n' \
      bin/fm-scanner.sh \
      bin/fm-findings-attribute.sh \
      bin/fm-findings-adjudicate.sh \
      bin/fm-dismissal-lib.sh \
      bin/fm-dismissal-validate.sh \
      docs/scanner/blocking-policy.json \
      docs/scanner/adjudicator-policy.json \
      docs/scanner/schema/dismissal-event.schema.json \
      docs/scanner/package-lock.json
    find "$root/docs/scanner/ast-rules" -type f -print |
      sed "s#^$root/##" |
      sort
  } | while IFS= read -r relative; do
    printf '%s\t' "$relative"
    sha256sum "$root/$relative" | awk '{print $1}'
  done | sha256sum | awk '{print $1}'
}

fm_scanner_repository_id() {
  local repo=${1:?git repository required} commit=${2:-HEAD}
  git -C "$repo" rev-list --max-parents=0 "$commit" |
    sort |
    sha256sum |
    awk '{print $1}'
}
