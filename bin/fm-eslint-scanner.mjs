#!/usr/bin/env node
// fm-eslint-scanner.mjs - pinned ESLint 9 scanner with the Phase 1 plugins.
//
// The package root is supplied by fm-scanner.sh and is installed only by
// bin/fm-install-scanners.sh. No package resolution or network access occurs
// during a scan.
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const nodeDir = process.env.FM_SCANNER_NODE_DIR;
if (!nodeDir) {
  process.stderr.write("FM_SCANNER_NODE_DIR is required\n");
  process.exit(2);
}

const require = createRequire(pathToFileURL(path.join(nodeDir, "package.json")));
const { ESLint } = require("eslint");
const eslintPackage = require("eslint/package.json");
const n = require("eslint-plugin-n");
const sonarjs = require("eslint-plugin-sonarjs");
const security = require("eslint-plugin-security");

if (process.argv[2] === "--version") {
  process.stdout.write(`${eslintPackage.version}\n`);
  process.exit(0);
}

const files = process.argv.slice(2);
if (files.length === 0) {
  process.stderr.write("at least one JavaScript path is required\n");
  process.exit(2);
}

const recommendedRules = (plugin, names) => {
  for (const name of names) {
    if (plugin.configs?.[name]?.rules) {
      return plugin.configs[name].rules;
    }
  }
  return {};
};

try {
  const eslint = new ESLint({
    overrideConfigFile: true,
    overrideConfig: [{
      files: ["**/*.{js,mjs,cjs}"],
      plugins: { n, sonarjs, security },
      rules: {
        ...recommendedRules(n, ["flat/recommended-module", "flat/recommended", "recommended-module", "recommended"]),
        ...recommendedRules(sonarjs, ["recommended"]),
        ...recommendedRules(security, ["recommended"]),
      },
    }],
  });
  const results = await eslint.lintFiles(files);
  process.stdout.write(`${JSON.stringify(results)}\n`);
  process.exitCode = results.some((result) => result.errorCount > 0 || result.warningCount > 0) ? 1 : 0;
} catch (error) {
  process.stderr.write(`${error?.stack ?? error}\n`);
  process.exitCode = 2;
}
