# @krakenloop/control-plane — S0 foundation

The canonical per-`FM_HOME` control-plane coordinator for ORD-228. This package
is the **first implementation code** of the recovery program. It builds the
storage foundation only — slice **S0** — cut to the authoritative slice boundary.
Domain tables and their verbs ship in the slices that own them (S1+); none of
them exist here.

Authority: `firstmate-runtime/data/spec-amend-s4/report.md` (the PASSED spec),
S0 row at lines 883-886. Build to that spec; this README points into it rather
than restating it.

## What S0 owns (and only this)

- **Storage seam** (`lib/control-plane-store.mjs`): an engine-neutral base that
  owns all domain logic behind one primitive. That primitive is a symbol-keyed
  method (`internal-symbols.mjs` `RUN_EXCLUSIVE`), NOT a public method, so the
  raw SQL surface is not part of the public contract (spec §3.1). Public callers
  see only domain-level methods (`init`, `schemaMeta`, `coordinatorState`,
  `tableNames`, `contractProbe`).
- **PGlite production adapter** (`lib/pglite-local-store.mjs`): PGlite persistent
  NodeFS at `FM_HOME/state/control-plane/pgdata`, serialized by real POSIX
  `flock(2)`. First-init and steady-state protocols per spec §2.2. One PGlite
  instance is opened and closed per exclusive section; **every** open — reads
  included — is gated by an exclusive flock, close precedes unlock, and a lost
  lock (dead holder) mid-section aborts the transaction rather than committing.
- **Test-only hosted contract adapter** (`lib/pg-hosted-contract-store.mjs`): a
  skeleton (spec §2.1) that runs the storage-seam contract against a **real**
  multi-connection Postgres (started by the ephemeral `test/pg-fixture.mjs`),
  proving the seam is not tied to PGlite's single-connection serialization. `pg`
  is a devDependency only, imported dynamically; it is never a production dep.
- **Real `flock(2)`** (`lib/flock.mjs`): held in a `flock(1)` holder subprocess
  with a ready handshake; released by closing the holder's stdin. The handle is a
  capability the runtime owner guard checks — and it is **invalidated the moment
  the holder dies** (WeakSet removal on `exit` plus a live-child check), so a
  stale capability from a dead holder cannot authorize an unlocked open.
- **Owner guard**, two halves (spec §2.2): the runtime half
  (`lib/pglite-engine.mjs`) refuses to open PGlite without a currently-live
  exclusive lock handle; the static half (`scripts/check-no-direct-pglite.mjs`)
  scans the **whole repository** and fails if any shipped module outside the one
  sanctioned engine file imports or constructs PGlite. It is wired into repo CI.
- **Core schema** (`sql/core-schema.sql`): only `schema_meta` and
  `coordinator_state`, applied idempotently by `cp init`.
- **Typed errors** (`lib/errors.mjs`): the S0 store/lock/guard errors only.
- **Coordinator entrypoint skeleton** (`lib/coordinator.mjs`, `bin/cp.mjs`): the
  single S0 verb, `init`.

## Scope (S0 boundary)

`cp init` seeds exactly the two S0-owned core tables and `home_uuid` — nothing
else. There are no domain tables, no `create-task`/`task-head`, and no
command-conflict taxonomy in S0; those belong to the slices that own the tables
and verbs they concern (S1 for tasks/runs/events and command idempotency, S2 for
outbox/terminals, etc. — spec §12). The seam contract runs on the core tables
alone, satisfying the spec's "contract skeleton runs … without domain tables."

(An earlier candidate applied the full DDL and a minimal `create-task`; round-1
independent QA — `firstmate-runtime/data/qa-s0-q20/report.md` — correctly
rejected that as crossing the slice boundary. This is the round-2 recut.)

## Verb (S0)

```
cp init [--data-dir <path>] [--home-label <label>]
```

Applies the core schema and seeds `home_uuid` (idempotent). `--data-dir`
overrides the `FM_HOME`-derived location.

## Tests

Colocated under `test/`, run with the Node test runner. `npm test` runs the
static owner guard first, then the suite:

```
npm test            # owner-guard scan + node --test ./test/*.test.mjs
npm run test:only   # tests without the owner-guard prefix (iteration)
npm run lint:owner-guard
```

All fixtures are sandboxed `mktemp` homes; tests never touch a real `FM_HOME`,
production state, or any production ledger. The hosted-adapter contract boots a
real ephemeral Postgres via `embedded-postgres` (a devDependency), so
`npm ci && npm test` exercises both engines with no external setup; it skips only
on a platform where that fixture cannot start.

## Maintaining this file

Keep this file for knowledge useful to almost every future session in this
package. Point to the authoritative spec and source files rather than restating
them. Prefer rewriting or pruning entries over appending. When a later slice adds
tables/verbs, update the Scope and Verb sections rather than leaving them stale.
