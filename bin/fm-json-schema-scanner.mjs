#!/usr/bin/env node
// fm-json-schema-scanner.mjs - offline validator for scanner-declared schemas.
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const nodeDir = process.env.FM_SCANNER_NODE_DIR;
if (!nodeDir) {
  process.stderr.write("FM_SCANNER_NODE_DIR is required\n");
  process.exit(2);
}
const require = createRequire(pathToFileURL(path.join(nodeDir, "package.json")));
const Ajv2020 = require("ajv/dist/2020").default;
const ajvPackage = require("ajv/package.json");

if (process.argv[2] === "--version") {
  process.stdout.write(`ajv ${ajvPackage.version}\n`);
  process.exit(0);
}
if (process.argv.length !== 4) {
  process.stderr.write("usage: fm-json-schema-scanner.mjs <schema.json> <document.json>\n");
  process.exit(2);
}

const [schemaPath, documentPath] = process.argv.slice(2);
try {
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  const document = JSON.parse(fs.readFileSync(documentPath, "utf8"));
  const ajv = new Ajv2020({ allErrors: true, strict: false, validateFormats: false });
  const validate = ajv.compile(schema);
  const valid = validate(document);
  const findings = valid ? [] : (validate.errors ?? []).map((error) => ({
    path: documentPath,
    message: `${error.instancePath || "/"} ${error.message ?? "schema violation"}`,
  }));
  process.stdout.write(`${JSON.stringify(findings)}\n`);
  process.exitCode = valid ? 0 : 1;
} catch (error) {
  process.stderr.write(`${error?.stack ?? error}\n`);
  process.exitCode = 2;
}
