# Shakedown scanner battery

`bin/fm-scanner.sh` owns scanner execution, normalization, timing, offline enforcement, and the `firstmate/scanner-report/3` contract.
`bin/fm-findings-attribute.sh` is the reusable owner of inherited, candidate-new, and unattributed baseline semantics.
`bin/fm-findings-adjudicate.sh` owns the bounded, demote-only Phase 2 classification pass and its closed report schema.
`bin/fm-dismissal-validate.sh` is the single raw-byte validation authority for the committed dismissal ledger.
`bin/fm-scanner-learning.sh` is the sanctioned dismissal writer and Seasoning proposal surface.
`bin/fm-verify.sh` consumes that closed report as its `scanner` gate.
`docs/scanner/blocking-policy.json` is the single committed authority for blocking severities, report-only rule prefixes, and per-scanner time slices.
`docs/scanner/adjudicator-policy.json` is the single committed authority for models, bounds, noisy-finding selectors, and the demotion reason taxonomy.
`docs/scanner/adjudicator-system-prompt.txt` is the versioned trusted instruction channel.

Install the pinned tools with `bin/fm-install-scanners.sh <scanner-directory>`.
Refresh the OSV database explicitly with `bin/fm-install-osv-db.sh <scanner-directory>`.
The scanner gate is adopted automatically only after both helpers publish their closed readiness manifests.
An operator may adopt it earlier by making the first non-empty line of `config/scanner-gate` exactly `enabled`.
Before adoption, `bin/fm-verify.sh` emits a visible `gate-not-adopted` note and leaves the gate non-blocking.
After adoption, every missing, crashed, or timed-out scanner fails closed as a `scanner-unavailable` finding.
The deterministic battery never downloads packages, updates vulnerability data, submits source, or calls a remote service.
Ast-grep runs the committed rules under `docs/scanner/ast-rules/` over changed supported source files.
Its normalized findings use the same confirmation, occurrence fingerprint, severity policy, and inherited-versus-candidate attribution path as every Phase 1 scanner.
Candidate-new blocking findings from designated noisy selectors are then sent in one bounded BYOK Claude CLI call.
OSV findings use the scanner's structured JSON package and advisory fields; that closed subject is fingerprinted and human-readable scanner messages never select a corroboration target.
The committed policy declares the default and escalation models; operators select the latter with `FM_SCANNER_ADJUDICATOR_MODEL`.
The classifier runs in safe mode with no tools, no MCP servers, no session persistence, and a closed structured-output schema.
Gitleaks findings are secrets-class and are never submitted to or demoted by the classifier.
Every invalid, unavailable, or timed-out classification preserves all pre-adjudication dispositions and adds one blocking `adjudicator-unavailable` finding.
Every demotion requires an independent machine-owned corroboration proof tied to the exact finding and reason code; model-selected source text never authorizes a downgrade.
The scanner bundle records that proof with the reason code, exact cited span, prompt fingerprint, model, cost estimate, and random audit-sample marker.
TruffleHog is deliberately excluded because its license and verification behavior violate this gate's local-first boundary.

## Dismissals and captain learning

`docs/scanner/dismissals.jsonl` is an append-only committed ledger of `firstmate/scanner-dismissal-event/1` records.
Its closed schema is `docs/scanner/schema/dismissal-event.schema.json`.
The validator reads the raw JSONL bytes once with python3 and jsonschema Draft 2020-12, rejects duplicate members before materialization, and refuses if either engine is unavailable.
The writer proves the existing ledger, stages one event, proves the complete result, and atomically renames it under the portable ledger lock.

Every event binds the application-computed scanner-qualified occurrence fingerprint, repository identity, scanner and rule, severity, occurrence, scanner-stack fingerprint, narrow scope, closed reason code, actor, evidence reference, creation time, and mandatory `review_after`.
There is no global scope.
Path scope is exact.
Rule scope requires a non-global repository-relative path prefix.
Secrets-class findings may use only exact path scope.
AST scope is schema-ready but remains non-matching until a later scanner phase supplies a machine-owned AST anchor in the finding contract.
Any fingerprint, severity, rule, path scope, repository, or scanner-stack change prevents a match.

The adjudicator loads the target repository's ledger from the immutable base commit when it exists.
For repositories without a local ledger it uses this committed control-plane ledger.
`FM_SCANNER_DISMISSAL_LEDGER` selects an explicit control-plane ledger for isolated operation and tests.
A candidate ledger change cannot suppress a finding in the same review once the base carries the ledger.
Only a live event whose `created_at` is not in the future and whose `review_after` is later than the current UTC instant can pre-filter a finding.
The validator refuses a review interval longer than 180 days.
An expired event re-surfaces the finding for normal adjudication.
A corrupt, unreadable, or unprovable ledger disables all pre-filtering, preserves the ordinary model path, and adds one blocking `dismissal-ledger-unavailable` finding.
Every pre-filtered finding remains in the bundle with `adjudication.status="pre-filtered"`, its dismissal id, reason, and review deadline.

Record a surfaced captain decision with the following shape.

```sh
bin/fm-scanner-learning.sh dismiss \
  --bundle scanner-report.json \
  --fingerprint <application-computed-sha256> \
  --scope path \
  --reason accepted-risk \
  --by captain \
  --evidence captain-order:<id> \
  --review-after 2026-10-01T00:00:00Z \
  --repo .
```

Record a corroborated adjudicator demotion with the same verb and `--by adjudicator`.
The writer then derives the closed reason, model identity, and proof reference from that exact demoted finding rather than accepting human-readable scanner text as authority.

Repeated model confirmations are labels, not executable policy.
Three unique confirmations of one scanner and rule may be graduated into a captain-gated Seasoning proposal with `fm-scanner-learning.sh propose`.
The proposal is a valid `class-defined` event with one provenance citation per confirmed fingerprint, but the command never mutates the failure-class ledger.
The captain still approves and lands the real rule through `bin/fm-failure-class.sh`.
Dismissal frequency never changes scanner severity or creates a global suppression automatically.

The direct pins and licenses are:

- Gitleaks 8.30.1 is MIT.
- Oxlint 1.75.0 is MIT.
- OSV-Scanner 2.4.0 is Apache-2.0.
- Actionlint 1.7.12 is MIT.
- Ast-grep 0.45.0 is MIT.
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

Ast-grep is the structural-rule seam.
Opengrep and markdownlint remain deferred and are not runtime dependencies.

Repositories declare exact document-to-schema mappings in `.fm-scanner-schemas.json`.
That declaration must conform to `firstmate/scanner-schema-map/1` and contains only exact `path` and `schema_path` pairs.
