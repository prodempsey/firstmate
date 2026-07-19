#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Static owner guard (the lint/CI half; the runtime half lives in
// pglite-engine.mjs). Spec section 2.2: "Direct new PGlite(dataDir) outside the
// coordinator package is forbidden by lint/CI and a runtime owner guard."
//
// Scope: the ENTIRE repository, not just the control-plane package. Only
// control-plane/lib/pglite-engine.mjs may import `@electric-sql/pglite` or
// construct PGlite. Any other shipped module (repo-root bin/, other packages'
// lib/bin, etc.) that does so is a violation. Test files and this guard itself are
// excluded (they legitimately reference the package in fixtures/comments).

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
// control-plane/scripts -> control-plane -> repository root
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..');

// Forward-slash relative paths permitted to import/construct PGlite.
const ALLOWLIST = new Set([
  'control-plane/lib/pglite-engine.mjs',
  'control-plane/scripts/check-no-direct-pglite.mjs'
]);

const MODULE_EXT = /\.(mjs|cjs|js|mts|cts|ts)$/;
const TEST_FILE = /\.(test|spec)\./;
const SKIP_DIRS = new Set(['node_modules', 'test', 'tests', '__tests__']);

// Match a real static/dynamic import or require of the package (optionally a
// subpath), NOT an incidental string mention of its name (e.g. a dependency-probe
// argument like `dependencyAvailable(root, '@electric-sql/pglite')`).
const IMPORT_RE = /(?:from|import|require)\s*\(?\s*['"]@electric-sql\/pglite(?:\/[^'"]*)?['"]/;
const CONSTRUCT_RE = /new\s+PGlite\s*\(|PGlite\.create\s*\(/;

function walk(dir, acc) {
  if (!fs.existsSync(dir)) return acc;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || SKIP_DIRS.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, acc);
    } else if (entry.isFile() && MODULE_EXT.test(entry.name) && !TEST_FILE.test(entry.name)) {
      acc.push(full);
    }
  }
  return acc;
}

// Return the list of shipped module files (repo-wide) that import or construct
// PGlite outside the sanctioned engine module.
export function findViolations(root = REPO_ROOT) {
  const violations = [];
  for (const file of walk(root, [])) {
    const rel = path.relative(root, file).split(path.sep).join('/');
    if (ALLOWLIST.has(rel)) continue;
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
      'owner-guard: PGlite may only be imported/constructed in ' +
        'control-plane/lib/pglite-engine.mjs; offending files:\n' +
        violations.map((v) => `  - ${v}`).join('\n') +
        '\n'
    );
    process.exit(1);
  }
  process.stdout.write('owner-guard: OK (PGlite confined to control-plane/lib/pglite-engine.mjs)\n');
}
