# The failure-class ledger

A durable, append-only catalogue of the recurring failure classes the fleet keeps rediscovering, distilled from binding design rulings and QA FAIL reports.
This is stage C of the Compounding Fleet program (ORD-274): the exponential kicker.
Every QA FAIL is distilled into a typed class with its fix invariant, and dispatch recall injects the applicable invariants into a crew's brief, so last night's recurrences become structurally unlikely.

Design authority: `data/kl-improve-scout-f5/compounding-fleet.kd.html` (stage C) and `data/kl-improve-scout-f5/report.md` improvement 3, in the firstmate-runtime home.

- Ledger: [`ledger.jsonl`](ledger.jsonl) is the tracked artifact.
- Writer / register flow: [`bin/fm-failure-class.sh`](../../bin/fm-failure-class.sh) is the only sanctioned writer; run `--help` for the full flag set.
- Seed builder: [`seed.sh`](seed.sh) is the canonical, non-destructive seed set; `--check` (default) verifies the committed ledger reproduces it, `--apply` idempotently ensures the classes into a ledger, `--to <path>` writes a fresh copy.
- Tests: [`tests/fm-failure-class.test.sh`](../../tests/fm-failure-class.test.sh).

## Why an append-only event log

`ledger.jsonl` is an append-only JSONL event log folded at read, the same idiom as `memory-registry.jsonl` and the KrakenDesign comment ledger.
There are two event kinds, one per line.
A `class-defined` event declares a class with its seed provenance.
An `occurrence` event appends one more provenance citation to an existing class id.

`list` and `show` fold the log; no verb ever rewrites or deletes a prior line.
The occurrence count is derived: it is the number of provenance citations a class has accumulated.
So every count bump is provenance-bearing by construction, because you cannot bump a class without citing where the recurrence was seen.

### Event schema (`kraken-failure-class/ledger-event/v1`)

The `class-defined` event carries these fields.

| field | meaning |
| --- | --- |
| `id` | stable class id, `FC-NNN` |
| `name` | short human name |
| `invariant` | the one-line closed rule that makes the class structurally unlikely |
| `cues` | detection cues: what a task brief or QA finding looks like when this class applies |
| `fix` | the fix pattern |
| `provenance` | array of `{type, ref, note?}`: the rulings / QA reports it was distilled from |
| `registry` | `{memory_type, scope, confidence, keywords}`: how it registers into memory |

The `occurrence` event is `{id, provenance:{type, ref, note?}}`: one more citation for `id`.

The writer refuses a duplicate id, an occurrence against an unknown id, and any event missing provenance, so the ledger cannot drift into an unprovenanced or self-contradictory state.
A malformed line, an unknown-schema line, or an occurrence for an undefined id makes `list` and `validate` fail closed rather than fold silently.

Every mutation (`add`, `ensure`, `bump`) serializes its whole read-check-append under a portable, abandoned-owner-aware lock (the fleet's `fm-wake-lib.sh` discipline) co-located with the ledger, so two concurrent sanctioned writers can never both pass the duplicate check and append the same id.
There is no destructive path: `add` refuses a duplicate, `ensure` skips an existing id, `bump` only appends, and the seed builder never deletes or rewrites the ledger, so no supported command can drop an appended occurrence.

## Retrievability: registering classes into the live memory registry

Retrieval is delegated to the landed memory registry (Memory PR-4).
`register` distils each class into the live registry through the activated propose/activate flow.

```
bin/fm-failure-class.sh register            # DRY RUN: prints the exact mem commands, mutates nothing
bin/fm-failure-class.sh register --live     # the explicit flag firstmate runs to activate (after captain approval)
bin/fm-failure-class.sh register --live --gate captain-approved:ORD-274
```

Registration mutates the live per-home registry, so it is dry-run by default and touches the registry only behind the explicit `--live` flag.
For each class it runs `mem propose` then `mem activate` with the following.

- A distinct, typed `sourceType=failure-class` (`mem propose --source-type`), so curation can filter failure classes on a first-class field.
- Every provenance citation as an `--evidence <type>:<ref>`, on both propose and activate.
- The class invariant, fix, cues, and provenance as the record body, so a dispatch recall pointer resolves (`mem show`) to actionable guidance.
- `--memory-type procedural`, `--scope fleet`, `--confidence guarded`.
- The `--gate` reference as the activation `--validation` authority.

Once activated, dispatch recall (`mem recall` / `mem inject-brief`) surfaces the applicable classes when a task brief matches their shape.
This is verified: a query like "validator keeps false-passing; add a check for the new corruption shape" recalls the relevant failure-class records.
Stage B wires this into every dispatch: `bin/fm-spawn.sh` runs `bin/fm-memory-inject.sh` for every ship/scout task before launch, so a brief whose text matches a class's detection cues carries that class's invariant as a bounded, cited recall pointer.
The wiring is on by default, fail-open (inert when the registry is empty or unavailable), and bounded by a portable deadline so it can never block a spawn (itself the FC-006 invariant).

### The typed `sourceType` field

Stage C requires a distinct `source_type` so curation can filter these records.
The memory registry now carries a first-class, typed `sourceType` record field (`memory/lib/schema.mjs`), threaded through the fold, the active index, `mem propose --source-type`, `mem update --source-type`, and the retrieve/recall projections.
Every registered failure class sets `sourceType: "failure-class"`, so curation filters on a typed field, not a free-form keyword.
The field is optional and absent on ordinary records, and it is bound under the same whole-document content hash as every other content field (change it, and the record's approval digest changes), while a record that never carried it hashes identically to the pre-field era so the existing corpus never churns on upgrade.
The `failure-class` keyword is retained additionally as a retrieval alias.
The same typed field is what a later stage would set to `task-postmortem` for the scout report's stage-A postmortem rows.

## The seed set (7 classes)

Seeded from the two binding design rulings and the 2026-07-22..24 QA FAIL corpus in the firstmate-runtime home.
Every row cites its provenance; see `ledger.jsonl` for the full citations.

| id | class | primary provenance |
| --- | --- | --- |
| FC-001 | Authority as allowlist instead of closed-schema positive proof | DJ S2 ruling sec 1; ME S3 ruling sec 1; qa-me-s3r4-q122; qa-dj-s2r3-q107 |
| FC-002 | Absence read as discharge | DJ S2 ruling sec 1/2.3-2.4; qa-dj-s2r2-q106; qa-g2-q4 |
| FC-003 | Digest/verification not covering the whole document | ME S3 ruling sec 1; qa-mem-pr3r2-q113; qa-mem-pr4r3-q117 |
| FC-004 | Fail-open on a missing prerequisite tool | ME S3 ruling sec 3.2/5; qa-me-s3r2-q120 (direct FAIL); qa-me-s3r7-q125 |
| FC-005 | Proof/validation not atomic with the mutation it authorizes | DJ S2 ruling sec 2.2; qa-mem-pr4-q115 (F3); qa-scr-q93; qa-m1r3-q22 |
| FC-006 | Unbounded/synchronous wait on a critical path | qa-mem-pr4-q115; qa-mem-pr4r2-q116; qa-mem-pr4r4-q118; scout improvement 3 |
| FC-007 | Stale artifact preserved on failure (cleanup-failure ignored) | qa-me-s3r6-q124; qa-mem-pr4-q115 (F1); qa-s6-q72 |

The evidence, measured: DJ S2 took 5 QA rounds plus a senior ruling for FC-001.
ME S3 then took 3 more rounds plus a second ruling for the same class hours later, roughly 6 QA rounds of cost in a single night.
A class ledger carried into the builder's brief at dispatch is what makes that recurrence structurally unlikely.

## Maintaining this file

Keep this README to what a future agent needs to use and extend the ledger: the append-only contract, the event schema, the register flow, and the `source_type`-marker decision.
The authoritative behaviour, flags, and refusals live in `bin/fm-failure-class.sh`'s header; point there rather than restating it.
Add a class with `fm-failure-class.sh add`; record a recurrence with `bump`; never hand-edit `ledger.jsonl`.
Prefer rewriting or pruning entries here over appending.
