#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Static owner guard (the lint/CI half; the runtime half lives in
// pglite-engine.mjs). Spec section 2.2: "Direct new PGlite(dataDir) outside the
// coordinator package is forbidden by lint/CI and a runtime owner guard."
//
// Rule: only lib/pglite-engine.mjs may import `@electric-sql/pglite` or construct
// PGlite. Any other shipped file (lib/, bin/) that does so is a violation.

const PACKAGE_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SANCTIONED = path.join('lib', 'pglite-engine.mjs');

const IMPORT_RE = /@electric-sql\/pglite/;
const CONSTRUCT_RE = /new\s+PGlite\s*\(|PGlite\.create\s*\(/;

function walk(dir, acc) {
  if (!fs.existsSync(dir)) return acc;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, acc);
    } else if (entry.isFile() && /\.mjs$/.test(entry.name)) {
      acc.push(full);
    }
  }
  return acc;
}

// Return the list of shipped files (under lib/ and bin/) that import or construct
// PGlite outside the sanctioned engine module.
export function findViolations(root = PACKAGE_ROOT) {
  const scanned = [];
  for (const sub of ['lib', 'bin']) {
    walk(path.join(root, sub), scanned);
  }
  const violations = [];
  for (const file of scanned) {
    const rel = path.relative(root, file);
    if (rel === SANCTIONED) continue;
    const text = fs.readFileSync(file, 'utf8');
    if (IMPORT_RE.test(text) || CONSTRUCT_RE.test(text)) {
      violations.push(rel);
    }
  }
  return violations;
}

function isMain() {
  return process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
}

if (isMain()) {
  const violations = findViolations();
  if (violations.length > 0) {
    process.stderr.write(
      `owner-guard: PGlite may only be imported/constructed in ${SANCTIONED}; ` +
        'offending files:\n' +
        violations.map((v) => `  - ${v}`).join('\n') +
        '\n'
    );
    process.exit(1);
  }
  process.stdout.write(`owner-guard: OK (PGlite confined to ${SANCTIONED})\n`);
}
