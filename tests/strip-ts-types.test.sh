#!/usr/bin/env bash
# Behavior tests for tests/lib/strip-ts-types.mjs, the TEST-ONLY TypeScript
# type-annotation stripper used to import the tracked .pi extensions under a
# node that cannot load .ts natively (see tests/fm-turnend-guard.test.sh).
#
# The stripper is a fallback, not a compiler, so it is pinned here: it must
# remove type-only syntax and NOTHING else. The dangerous failure is not a
# syntax error (node would reject that loudly at import) but a SILENT semantic
# change - deleting something that only looked like a type. Every case below is
# a construct that could be confused for one: object literals, ternaries,
# regexes, strings containing ':' or ' as ', and `import * as`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot strip-ts-types)
STRIP="$ROOT/tests/lib/strip-ts-types.mjs"

# Strip the TypeScript on stdin and run the result, echoing whatever it prints.
# The source arrives by quoted heredoc so the shell expands nothing in it.
strip_and_run() {  # <name>  (TypeScript source on stdin)
  local name=$1 ts="$TMP_ROOT/$1.ts" mjs="$TMP_ROOT/$1.mjs"
  cat > "$ts"
  node "$STRIP" "$ts" "$mjs" || fail "$name: stripper exited non-zero"
  node "$mjs" || fail "$name: stripped output failed to run"
}

test_strips_type_only_syntax() {
  local out
  out=$(strip_and_run annotations <<'TS'
import type { Thing } from "somewhere";
type Alias = "a" | "b";
interface Shape { x: number; }
let slot: any = null;
function greet(who: string, times: number | null): string {
  return `${who}:${times ?? 0}`;
}
const arrow = (n: number): number => n + 1;
slot = { kept: 1 };
console.log(greet("cap", 2), arrow(1), slot.kept);
TS
)
  [ "$out" = "cap:2 2 1" ] || fail "type stripping changed runtime behavior: got '$out'"
  pass "strip-ts-types: removes import type, aliases, interfaces, params, returns, and variable annotations"
}

# The whole risk of a regex-ish stripper: eating real code that resembles a type.
test_preserves_lookalike_runtime_syntax() {
  local out
  out=$(strip_and_run lookalikes <<'TS'
import * as os from "node:os";
const obj = { key: "value", nested: { deep: true } };
const ternary = obj.key === "value" ? "yes" : "no";
const re = /^watcher: healthy\b/;
const text = "a: b as c";
const tpl = `${obj.key ? "t:1" : "t:0"} as done`;
const cast = (obj as { key?: unknown })?.key;
console.log(obj.nested.deep, ternary, re.test("watcher: healthy"), text, tpl, cast, typeof os.platform);
TS
)
  [ "$out" = "true yes true a: b as c t:1 as done value function" ] \
    || fail "stripper mangled lookalike runtime syntax: got '$out'"
  pass "strip-ts-types: leaves object literals, ternaries, regexes, strings, and 'import * as' intact"
}

# Every tracked extension must strip to syntactically valid JavaScript. This is
# only a parse check: fm-primary-pi-watch.ts additionally imports "typebox" at
# runtime, a package this repo does not install (there is no package.json - Pi
# supplies it), so it cannot be IMPORTED under bare node no matter how it is
# stripped. The import check below therefore covers the extension the suite
# actually loads.
test_tracked_pi_extensions_strip_to_valid_js() {
  local ext base mjs
  for ext in "$ROOT"/.pi/extensions/*.ts; do
    base=$(basename "$ext" .ts)
    mjs="$TMP_ROOT/$base.mjs"
    node "$STRIP" "$ext" "$mjs" || fail "$base: stripper exited non-zero"
    node --check "$mjs" || fail "$base: stripped extension is not valid JavaScript"
  done
  pass "strip-ts-types: every tracked .pi extension strips to valid JavaScript"
}

# The extension tests/fm-turnend-guard.test.sh imports must survive stripping as
# a real, importable module that still exposes its entry point.
test_turnend_extension_strips_to_importable_esm() {
  local mjs home
  mjs="$TMP_ROOT/turnend-import.mjs"
  # The extension marks itself loaded at import time, writing under
  # $FM_HOME/state. Sandbox that so importing it here cannot touch the repo.
  home="$TMP_ROOT/import-home"
  mkdir -p "$home/state"
  node "$STRIP" "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$mjs" \
    || fail "stripper exited non-zero on the turn-end extension"
  PLUGIN="$mjs" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    node --input-type=module <<'EOF' || fail "stripped turn-end extension did not export a default entry point"
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
if (typeof mod.default !== "function") process.exit(1);
EOF
  pass "strip-ts-types: the turn-end extension strips to importable ESM with a default export"
}

test_strips_type_only_syntax
test_preserves_lookalike_runtime_syntax
test_tracked_pi_extensions_strip_to_valid_js
test_turnend_extension_strips_to_importable_esm
