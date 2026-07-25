# Shakedown scanner battery

`bin/fm-scanner.sh` owns scanner execution, normalization, timing, offline enforcement, and the `firstmate/scanner-report/1` contract.
`bin/fm-findings-attribute.sh` is the reusable owner of inherited, candidate-new, and unattributed baseline semantics.
`bin/fm-verify.sh` consumes that closed report as its `scanner` gate.

Install the pinned tools with `bin/fm-install-scanners.sh <scanner-directory>`.
Refresh the OSV database explicitly with `bin/fm-install-osv-db.sh <scanner-directory>`.
The verification runtime never downloads packages, updates vulnerability data, submits source, or calls a remote service.
TruffleHog is deliberately excluded because its license and verification behavior violate this gate's local-first boundary.

The direct pins and licenses are:

- Gitleaks 8.30.1 is MIT.
- Oxlint 1.75.0 is MIT.
- OSV-Scanner 2.4.0 is Apache-2.0.
- Actionlint 1.7.12 is MIT.
- Ruff 0.16.0 is MIT.
- jq 1.7.1 is MIT.
- ShellCheck 0.11.0 is GPL-3.0.
- ESLint 9.39.5 is MIT.
- eslint-plugin-n 18.2.2 is MIT.
- eslint-plugin-sonarjs 4.2.0 is LGPL-3.0-only.
- eslint-plugin-security 4.0.1 is Apache-2.0.
- Ajv 8.17.1 is MIT and provides offline validation for declared JSON Schemas.

Standalone release assets are pinned by SHA-256 in `bin/fm-install-scanners.sh`.
The Node tool graph is transitively pinned by `docs/scanner/package-lock.json`.

Repositories declare exact document-to-schema mappings in `.fm-scanner-schemas.json`.
That declaration must conform to `firstmate/scanner-schema-map/1` and contains only exact `path` and `schema_path` pairs.
