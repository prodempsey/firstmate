# @krakenloop/control-plane — S0 foundation

The canonical per-`FM_HOME` control-plane coordinator for ORD-228. This package
is the **first implementation code** of the recovery program. It builds the
storage foundation only (slice **S0**); every later slice's verbs are deliberately
absent.

Authority: `firstmate-runtime/data/spec-amend-s4/report.md` (the PASSED spec). Build
to that spec; this README does not restate it, only points into it.

## What S0 provides

- **Storage seam** (`lib/control-plane-store.mjs`): an engine-neutral base that
  owns all domain logic behind one primitive, `runExclusive(fn)`. Adapters supply
  only exclusivity + a connection.
- **PGlite production adapter** (`lib/pglite-local-store.mjs`): PGlite persistent
  NodeFS at `FM_HOME/state/control-plane/pgdata`, serialized by real POSIX
  `flock(2)`. First-init and steady-state protocols per spec §2.2. One PGlite
  instance is opened and closed per exclusive section; **every** open — reads
  included — is gated by an exclusive flock, and close precedes unlock.
- **Test-only hosted contract adapter** (`lib/pg-hosted-contract-store.mjs`): a
  skeleton (spec §2.1) that runs the storage-seam contract against a real
  multi-connection Postgres fixture, proving the seam is not tied to PGlite's
  single-connection serialization. Depends on `pg` via dynamic import so `pg`
  never becomes a production dependency; skips when no `CP_HOSTED_TEST_URL`/`pg`.
- **Real `flock(2)`** (`lib/flock.mjs`): held in a `flock(1)` holder subprocess
  with a ready handshake; released by closing the holder's stdin. The handle is a
  capability the runtime owner guard checks.
- **Owner guard**, two halves (spec §2.2): the runtime half
  (`lib/pglite-engine.mjs`) refuses to open PGlite without a currently-held
  exclusive lock handle; the static half (`scripts/check-no-direct-pglite.mjs`)
  fails CI if any shipped file constructs PGlite outside the engine module.
- **Full schema/DDL** (`sql/core-schema.sql`, `sql/domain-schema.sql`): the
  complete spec §3 DDL, applied idempotently by `cp init`.
- **Typed errors** (`lib/errors.mjs`): the S0 store/guard errors plus the spec's
  command-conflict error taxonomy.
- **Coordinator entrypoint skeleton** (`lib/coordinator.mjs`, `bin/cp.mjs`): the
  three S0 verbs `init`, `create-task`, `task-head`.

## Scope note — S0 boundary and a brief↔spec reconciliation

The spec's slice plan (§12) lists S0 as owning only `schema_meta` and
`coordinator_state`, with domain-table constraints and `create-task` formally
assigned to S1. The S0 **task brief**, however, sets the acceptance as: *DDL
applies clean; constraints reject duplicate event ids, duplicate
(task,gen,producer,seq), and a second terminal event per generation; illegal
transitions rejected; create-task read-back verified.*

That acceptance cannot be met with only the two core tables — it requires the
full DDL (for `task_events`/`tasks` constraints) and a `create-task` path. The
brief's own scope line explicitly authorizes "schema/DDL application," and a
schema is applied as one coherent unit. So S0 here:

- applies the **complete** §3 DDL (all 13 tables), and
- implements **only** `create-task` + `task-head` on top of it,

and implements **nothing else** from later slices (no `begin-run`, `event`,
`complete`/`fail`, cleanup saga, consumer, reconciler, snapshots, projections).
The seam contract probe still runs on core tables alone, satisfying the spec's
"contract skeleton runs … without domain tables." This reconciliation is
surfaced here and in the commit message for the review gate; it is a scope call,
not a spec change.

## Verbs (S0)

```
cp init [--data-dir <path>] [--home-label <label>]
cp create-task <task_id> --kind <ship|scout|secondmate> --title <title>
   [--repo <repo>] --origin <captain_order|internal>
   (--order-ref <ref> | --internal-reason <reason>) [--command-id <id>]
cp task-head <task_id>
```

`--data-dir` overrides the `FM_HOME`-derived location. `create-task` is idempotent
under a repeated `--command-id`.

## Tests

Colocated under `test/`, run with the Node test runner (repo convention):

```
npm test            # node --test ./test/*.test.mjs
npm run lint:owner-guard
```

All fixtures are sandboxed `mktemp` homes; tests never touch a real `FM_HOME`,
production state, or any production ledger. Set `CP_HOSTED_TEST_URL` (and install
`pg`) to additionally run the hosted-adapter contract.

## Maintaining this file

Keep this file for knowledge useful to almost every future session in this
package. Point to the authoritative spec and source files rather than restating
them. Prefer rewriting or pruning entries over appending. When a later slice adds
verbs, update the Scope note and Verbs section rather than leaving them stale.
