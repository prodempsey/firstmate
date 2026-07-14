// Minimal TypeScript type-annotation stripper, for TESTS ONLY.
//
// Why this exists: firstmate's Pi extensions (.pi/extensions/*.ts) are plain
// ESM plus type annotations - Pi supplies its own TS loader at runtime, and the
// repo has no TS toolchain, no package.json, and no build step. Tests that want
// to exercise an extension's real logic must import it under bare node.
//
// Node >= 22.18 / 23 strips types natively, so tests should ALWAYS prefer a
// direct import() and fall back here only when the host node cannot
// (ERR_UNKNOWN_FILE_EXTENSION / ERR_NO_TYPESCRIPT - e.g. a node built without
// Amaro, as some distro builds are). That keeps the suite green on any node
// without pinning one, and without adding a dependency.
//
// Scope is deliberately narrow: it handles the type-only syntax these
// extensions actually use - `import type`, `type` aliases, `interface` blocks,
// parameter/return/variable annotations, and `as` assertions - and nothing
// else. It is NOT a TypeScript compiler. It is guarded two ways: the stripped
// output is imported immediately (so any mangling fails loudly rather than
// silently passing), and tests/strip-ts-types.test.sh pins its behavior against
// the constructs that could be confused for types (object literals, ternaries,
// regexes, strings containing ':' or ' as ', `import * as`).

const IDENT = /[A-Za-z0-9_$]/;
const OPEN = { "(": ")", "[": "]", "{": "}" };

// Chars after which a `/` starts a regex literal rather than division.
const REGEX_OK_BEFORE = new Set([
  ..."(,=:[!&|?{};+-*%~^<>".split(""),
]);

// If src[i] begins a string, template, comment, or regex, return the index just
// past it. Otherwise return -1. Templates recurse through their ${...} holes.
function skipAtomic(src, i, lastSig) {
  const c = src[i];

  if (c === "/" && src[i + 1] === "/") {
    const nl = src.indexOf("\n", i);
    return nl === -1 ? src.length : nl;
  }
  if (c === "/" && src[i + 1] === "*") {
    const end = src.indexOf("*/", i + 2);
    return end === -1 ? src.length : end + 2;
  }
  if (c === "/" && (lastSig === "" || REGEX_OK_BEFORE.has(lastSig))) {
    let j = i + 1;
    let inClass = false;
    for (; j < src.length; j += 1) {
      const d = src[j];
      if (d === "\\") { j += 1; continue; }
      if (d === "\n") return -1; // unterminated: not a regex after all
      if (d === "[") inClass = true;
      else if (d === "]") inClass = false;
      else if (d === "/" && !inClass) break;
    }
    j += 1;
    while (j < src.length && /[a-z]/.test(src[j])) j += 1; // flags
    return j;
  }
  if (c === '"' || c === "'") {
    let j = i + 1;
    for (; j < src.length; j += 1) {
      if (src[j] === "\\") { j += 1; continue; }
      if (src[j] === c) break;
    }
    return j + 1;
  }
  if (c === "`") {
    let j = i + 1;
    while (j < src.length) {
      if (src[j] === "\\") { j += 2; continue; }
      if (src[j] === "`") return j + 1;
      if (src[j] === "$" && src[j + 1] === "{") {
        j = matchBracket(src, j + 1) + 1; // skip the ${...} hole
        continue;
      }
      j += 1;
    }
    return j;
  }
  return -1;
}

// Index of the bracket closing the one at `open`, skipping nested atomics.
function matchBracket(src, open) {
  const stack = [OPEN[src[open]]];
  let lastSig = src[open];
  let i = open + 1;
  while (i < src.length && stack.length) {
    const skip = skipAtomic(src, i, lastSig);
    if (skip !== -1) { i = skip; continue; }
    const c = src[i];
    if (OPEN[c]) stack.push(OPEN[c]);
    else if (c === stack[stack.length - 1]) stack.pop();
    if (!/\s/.test(c)) lastSig = c;
    i += 1;
  }
  return i - 1;
}

function nextSig(src, i) {
  while (i < src.length) {
    const skip = skipAtomic(src, i, "");
    // only comments/whitespace may be skipped when looking for the next token
    if (src[i] === "/" && (src[i + 1] === "/" || src[i + 1] === "*") && skip !== -1) { i = skip; continue; }
    if (/\s/.test(src[i])) { i += 1; continue; }
    return i;
  }
  return -1;
}

// Consume a type expression starting at i, stopping at any char in `stops` that
// sits at bracket depth 0. Balanced (), [], {}, <> are consumed wholesale.
function skipTypeExpr(src, i, stops) {
  let depth = 0;
  while (i < src.length) {
    const c = src[i];
    const skip = skipAtomic(src, i, "");
    if (skip !== -1 && (c === '"' || c === "'" || c === "`" || (c === "/" && (src[i + 1] === "/" || src[i + 1] === "*")))) {
      i = skip;
      continue;
    }
    // Stops are checked BEFORE bracket nesting: a `{` can be both a stop (the
    // start of a function body after a return type) and an opener (a type
    // literal). Checking nesting first would make `{` unreachable as a stop and
    // let the scan run away past the end of the annotation.
    if (depth === 0 && stops.includes(c)) return i;
    if (depth === 0 && c === "=" && src[i + 1] === ">") return i; // arrow body
    if (c === "(" || c === "[" || c === "{" || c === "<") { depth += 1; i += 1; continue; }
    if (c === ")" || c === "]" || c === "}" || c === ">") { depth -= 1; i += 1; continue; }
    i += 1;
  }
  return i;
}

// The identifier word immediately before index i: { word, start }.
function wordBeforeAt(src, i) {
  let j = i - 1;
  while (j >= 0 && /\s/.test(src[j])) j -= 1;
  const end = j + 1;
  while (j >= 0 && IDENT.test(src[j])) j -= 1;
  return { word: src.slice(j + 1, end), start: j + 1 };
}

function wordBefore(src, i) {
  return wordBeforeAt(src, i).word;
}

export function stripTypes(src) {
  let out = "";
  let i = 0;
  let lastSig = "";
  // Statement-level tracking, so `import * as x` is never read as an assertion.
  let stmtStart = true;
  let inImport = false;

  while (i < src.length) {
    const c = src[i];

    const skip = skipAtomic(src, i, lastSig);
    if (skip !== -1) {
      out += src.slice(i, skip);
      i = skip;
      continue;
    }

    if (stmtStart && !/\s/.test(c)) {
      const w = /^[A-Za-z_$]/.test(c) ? src.slice(i).match(/^[A-Za-z_$][A-Za-z0-9_$]*/)[0] : "";

      // `import type ... ;` / `export type ... ;` -> drop the whole statement.
      if ((w === "import" || w === "export") && /^\s*type\b/.test(src.slice(i + w.length))) {
        const semi = skipTypeExpr(src, i + w.length, [";"]);
        i = semi < src.length && src[semi] === ";" ? semi + 1 : semi;
        continue;
      }
      // `type X = ...;` -> drop.
      if (w === "type" && /^\s*[A-Za-z_$]/.test(src.slice(i + 4))) {
        const semi = skipTypeExpr(src, i + 4, [";"]);
        i = semi < src.length && src[semi] === ";" ? semi + 1 : semi;
        continue;
      }
      // `interface X { ... }` -> drop.
      if (w === "interface") {
        const brace = src.indexOf("{", i);
        i = matchBracket(src, brace) + 1;
        continue;
      }
      if (w === "import" || w === "export") inImport = true;
      stmtStart = false;
    }

    // `const|let|var IDENT: T = ...` -> drop the annotation.
    if (c === ":" && !inImport) {
      const kw = (() => {
        let j = i - 1;
        while (j >= 0 && /\s/.test(src[j])) j -= 1;
        let end = j + 1;
        while (j >= 0 && IDENT.test(src[j])) j -= 1;
        const ident = src.slice(j + 1, end);
        if (!ident) return "";
        return /^(const|let|var)$/.test(wordBefore(src, j + 1)) ? ident : "";
      })();
      if (kw) {
        i = skipTypeExpr(src, i + 1, [";", ",", "="]);
        continue;
      }
    }

    // A `(` opens a DECLARATION parameter list (not a call) when its matching
    // `)` is followed by `=>` or a `:` return type, or when `function` precedes
    // it. Calls like spawnSync(..., { encoding: "utf8" }) fall through, so their
    // object literals are never mistaken for type annotations.
    if (c === "(") {
      const close = matchBracket(src, i);
      const after = nextSig(src, close + 1);
      const arrow = after !== -1 && src[after] === "=" && src[after + 1] === ">";
      const retType = after !== -1 && src[after] === ":";
      // `function (` or `function foo(`: the word before the paren, or - when
      // the function is named - the word before that one.
      const prev = wordBeforeAt(src, i);
      const declared = prev.word === "function" || wordBefore(src, prev.start) === "function";
      const isParams = arrow || retType || declared;

      if (isParams) {
        out += "(" + stripParams(src.slice(i + 1, close)) + ")";
        i = close + 1;
        lastSig = ")";
        if (retType) {
          i = skipTypeExpr(src, after + 1, ["{"]); // drop `: T` before the body / `=>`
        }
        continue;
      }
    }

    // `expr as T` -> drop the assertion. Never inside an import statement (so
    // `import * as fs` survives), and only when it follows an expression, so an
    // identifier merely containing "as" is untouched.
    if (
      !inImport &&
      src.startsWith("as", i) &&
      !IDENT.test(src[i + 2] ?? "") &&
      !IDENT.test(src[i - 1] ?? "") &&
      (IDENT.test(lastSig) || lastSig === ")" || lastSig === "]")
    ) {
      i = skipTypeExpr(src, i + 2, [")", ",", ";", "]", "}"]);
      continue;
    }

    if (c === ";" || c === "\n") {
      if (c === ";") { inImport = false; stmtStart = true; }
      if (c === "\n" && !inImport) stmtStart = true;
    } else if (!/\s/.test(c)) {
      if (c === "}" || c === "{") stmtStart = true;
      else stmtStart = false;
    }

    out += c;
    if (!/\s/.test(c)) lastSig = c;
    i += 1;
  }

  return out;
}

// Strip annotations inside a declaration parameter list: `pid: string`,
// `code: number | null`, `x = { a: 1 }` defaults are preserved.
function stripParams(params) {
  let out = "";
  let i = 0;
  let lastSig = "";
  while (i < params.length) {
    const c = params[i];
    const skip = skipAtomic(params, i, lastSig);
    if (skip !== -1) {
      out += params.slice(i, skip);
      i = skip;
      continue;
    }
    if (c === "?" && params[nextSig(params, i + 1)] === ":") {
      i = skipTypeExpr(params, nextSig(params, i + 1) + 1, [",", "="]);
      continue;
    }
    if (c === ":") {
      i = skipTypeExpr(params, i + 1, [",", "="]);
      continue;
    }
    if (c === "{" || c === "(" || c === "[") {
      const close = matchBracket(params, i);
      out += params.slice(i, close + 1); // a default value / destructuring: keep as-is
      i = close + 1;
      lastSig = params[close];
      continue;
    }
    out += c;
    if (!/\s/.test(c)) lastSig = c;
    i += 1;
  }
  return out;
}

// CLI: strip-ts-types.mjs <in.ts> <out.mjs>
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/^.*\//, ""))) {
  const { readFileSync, writeFileSync } = await import("node:fs");
  const [, , input, output] = process.argv;
  if (!input || !output) {
    process.stderr.write("usage: strip-ts-types.mjs <in.ts> <out.mjs>\n");
    process.exit(2);
  }
  writeFileSync(output, stripTypes(readFileSync(input, "utf8")));
}
