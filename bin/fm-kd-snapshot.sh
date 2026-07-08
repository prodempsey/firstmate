#!/usr/bin/env bash
# fm-kd-snapshot.sh - turn a live render at a URL into ONE self-contained
# KrakenDesign HTML artifact, then optionally register it for captain review.
#
# KrakenDesign snapshots only the text of a single HTML file (it does not copy
# sibling CSS, JS, images, or live app/API state), so a live multi-file cockpit
# app on a test port will not render in the review dock. This helper renders the
# page headless, waits for the target state, inlines stylesheets and images as
# data: URIs, drops scripts so the static snapshot never re-fetches live state,
# and writes one <output>.kd.html the dock can display and the captain annotate.
#
# Usage:
#   fm-kd-snapshot.sh <url> <output.kd.html> [options]
# Options:
#   --title "<t>"      register the artifact with `krakendesign <out> --title "<t>"` after writing
#   --register         register with krakendesign (no explicit title)
#   --wait <ms|text>   wait for a duration in ms, or until text/selector appears, before capture
#                      (default: 800ms settle)
#   --freeze-js <file> a JS snippet run in-page before capture to freeze deterministic
#                      sample/board data (the board-data shape is the cockpit's concern,
#                      so it is supplied by the caller, not baked in here)
#   --engine <cmd>     override the render engine (also FM_KD_SNAPSHOT_ENGINE). The engine is
#                      invoked as `<cmd> --url <url> --out <out> [--wait <w>] [--freeze-js <f>]`
#                      and must write the self-contained HTML to <out>. Use this to plug in a
#                      higher-fidelity cockpit snapshotter that can freeze live board state.
#   -h, --help         print this usage
#
# Dependency: the built-in engine drives `chrome-devtools-axi` (open -> wait -> eval),
# the sanctioned browser tool, and relies on its `eval` awaiting async JS. Fidelity
# depends on the page; for cockpit renders that need real board-data freezing, supply a
# cockpit engine via --engine / FM_KD_SNAPSHOT_ENGINE rather than duplicating cockpit
# logic here. The register/poll/resolve review flow lives in the krakendesign skill.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fm-kd-snapshot.sh <url> <output.kd.html> [options]
  Render a live page into ONE self-contained KrakenDesign HTML artifact.
Options:
  --title "<t>"      register the artifact with krakendesign after writing, using this title
  --register         register with krakendesign (no explicit title)
  --wait <ms|text>   wait for a duration in ms, or until text/selector appears (default: 800)
  --freeze-js <file> JS snippet run in-page before capture to freeze sample/board data
  --engine <cmd>     override render engine (also FM_KD_SNAPSHOT_ENGINE); invoked as
                     `<cmd> --url <url> --out <out> [--wait <w>] [--freeze-js <f>]`
  -h, --help         print this usage
EOF
}

URL=""
OUT=""
TITLE=""
REGISTER=0
WAIT="800"
FREEZE_JS=""
ENGINE="${FM_KD_SNAPSHOT_ENGINE:-}"

POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title) shift; TITLE="${1:-}"; REGISTER=1 ;;
    --register) REGISTER=1 ;;
    --wait) shift; WAIT="${1:-}" ;;
    --freeze-js) shift; FREEZE_JS="${1:-}" ;;
    --engine) shift; ENGINE="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done; break ;;
    -*) echo "fm-kd-snapshot: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) POS+=("$1") ;;
  esac
  shift || true
done

[ "${#POS[@]}" -ge 1 ] && URL="${POS[0]}"
[ "${#POS[@]}" -ge 2 ] && OUT="${POS[1]}"

if [ -z "$URL" ] || [ -z "$OUT" ]; then
  echo "fm-kd-snapshot: need <url> and <output.kd.html>" >&2
  usage >&2
  exit 2
fi
if [ -n "$FREEZE_JS" ] && [ ! -f "$FREEZE_JS" ]; then
  echo "fm-kd-snapshot: --freeze-js file not found: $FREEZE_JS" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUT")"

# In-page inliner: fold stylesheets into <style>, rewrite images to data: URIs, and
# strip scripts so the snapshot is a single self-contained file that never re-fetches
# live state. Kept in a single-quoted heredoc so bash leaves the JS untouched.
IFS='' read -r -d '' INLINER_JS <<'JS' || true
(async () => {
  const abs = (u) => { try { return new URL(u, document.baseURI).href; } catch (e) { return u; } };
  const toDataURI = async (u) => {
    try {
      const r = await fetch(abs(u));
      const b = await r.blob();
      return await new Promise((res) => {
        const fr = new FileReader();
        fr.onloadend = () => res(fr.result);
        fr.onerror = () => res(u);
        fr.readAsDataURL(b);
      });
    } catch (e) { return u; }
  };
  for (const link of Array.from(document.querySelectorAll('link[rel~="stylesheet"][href]'))) {
    try {
      const css = await (await fetch(abs(link.getAttribute('href')))).text();
      const style = document.createElement('style');
      style.textContent = css;
      link.replaceWith(style);
    } catch (e) { /* leave the link in place if the fetch fails */ }
  }
  for (const img of Array.from(document.querySelectorAll('img[src]'))) {
    const src = img.getAttribute('src');
    if (src && !src.startsWith('data:')) img.setAttribute('src', await toDataURI(src));
  }
  for (const s of Array.from(document.querySelectorAll('script'))) s.remove();
  return '<!DOCTYPE html>\n' + document.documentElement.outerHTML;
})()
JS

render_with_engine() {
  # Word-split the engine command so FM_KD_SNAPSHOT_ENGINE="node /path/kd-snapshot.mjs" works.
  local engine_cmd
  read -r -a engine_cmd <<<"$ENGINE"
  local args=(--url "$URL" --out "$OUT")
  [ -n "$WAIT" ] && args+=(--wait "$WAIT")
  [ -n "$FREEZE_JS" ] && args+=(--freeze-js "$FREEZE_JS")
  "${engine_cmd[@]}" "${args[@]}"
}

render_with_chrome() {
  command -v chrome-devtools-axi >/dev/null 2>&1 || {
    echo "fm-kd-snapshot: chrome-devtools-axi not found; set --engine / FM_KD_SNAPSHOT_ENGINE to a snapshot engine" >&2
    return 3
  }
  chrome-devtools-axi open "$URL" >/dev/null
  [ -n "$WAIT" ] && chrome-devtools-axi wait "$WAIT" >/dev/null
  [ -n "$FREEZE_JS" ] && chrome-devtools-axi eval "$(cat "$FREEZE_JS")" >/dev/null
  chrome-devtools-axi eval "$INLINER_JS" >"$OUT"
}

if [ -n "$ENGINE" ]; then
  render_with_engine
else
  render_with_chrome
fi

if [ ! -s "$OUT" ]; then
  echo "fm-kd-snapshot: render produced no output at $OUT" >&2
  exit 1
fi
case "$(head -c 4096 "$OUT")" in
  *"<"*) : ;;
  *) echo "fm-kd-snapshot: output at $OUT does not look like HTML" >&2; exit 1 ;;
esac

echo "fm-kd-snapshot: wrote $OUT"

if [ "$REGISTER" = 1 ]; then
  command -v krakendesign >/dev/null 2>&1 || {
    echo "fm-kd-snapshot: krakendesign not found; artifact written but not registered" >&2
    exit 1
  }
  if [ -n "$TITLE" ]; then
    krakendesign "$OUT" --title "$TITLE"
  else
    krakendesign "$OUT"
  fi
fi
