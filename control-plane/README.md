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
  owns all domain logic. The raw exclusive-transaction primitive — the only thing
  that hands out a connection with unrestricted `query`/`exec` — is **not on the
  store instance at all**. It lives in a module-private WeakMap
  (`lib/internal-runtime.mjs`) keyed by the store, so a public caller holding a
  store object cannot discover it (no property, no symbol, no private field is
  enumerable to it) or invoke it (spec §3.1). Public callers see only
  domain-level methods (`init`, `schemaMeta`, `coordinatorState`, `tableNames`,
  `contractProbe`). See **"Extending the store (S1+)"** below for the sanctioned
  in-package path.
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
  sanctioned engine file imports or constructs PGlite. Run via `npm test` /
  `npm run lint:owner-guard`. (Wiring this scan into the repository-level CI
  workflow is proposed separately for explicit approval — see "CI wiring" below —
  and is deliberately NOT part of this S0 diff, which is confined to
  `control-plane/`.)
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
rejected that as crossing the slice boundary. This is the round-3 recut, which
also seals the exclusive-transaction primitive per round-2 QA
`firstmate-runtime/data/qa-s0r2-q23/report.md`.)

## Extending the store (S1+)

The sanctioned — and only — way for in-package code to run a domain transaction
is `lib/internal-runtime.mjs`:

```js
import { runExclusive } from './internal-runtime.mjs';
await runExclusive(store, async (conn) => {
  // conn.query(sql, params) / conn.exec(sql), inside the exclusive transaction
});
```

An adapter registers its raw primitive once, in its constructor, as a truly
private method:

```js
registerExclusive(this, (callback) => this.#exclusive(callback));
```

`internal-runtime.mjs` is never re-exported from the public entrypoint
(`bin/cp.mjs`). Reaching the primitive therefore requires deep-importing that
internal module from **inside** the package — the same trust boundary S1's own
`lib/` modules live within — and is impossible with only a public store object.
So S1 can add new `lib/` domain modules (task/run/event verbs) that run
transactions without reopening a public arbitrary-SQL hole. The guarantee is
regression-tested in `test/private-primitive.test.mjs` (the round-2 QA
reproduction now finds no reachable callable and cannot mutate the DB).

## CI wiring (proposed, needs explicit approval)

The static owner guard would ideally run in the repository CI. Wiring it into
`.github/workflows/ci.yml` is intentionally **out of this S0 diff** so the change
stays confined to `control-plane/` (round-2 QA finding 2). Proposed follow-up: a
small, dependency-free CI job running `node control-plane/scripts/check-no-direct-pglite.mjs`
(the sibling `memory` package's own tests are likewise not in repo CI, so this is
a new integration to approve on its own, not smuggle into S0).

## Verb (S0)

```
cp init [--data-dir <path>] [--home-label <label>]
```

Applies the core schema and seeds `home_uuid` (idempotent). `--data-dir`
overrides the `FM_HOME`-derived location.

## Cutover stage CW2 (shadow run + archived-history back-fill)

CW2 (ORD-256) adds the shadow-run wiring and the archived-history back-fill on top of
the landed S0-S8 + CW1 modules, which stay byte-identical apart from the one sanctioned
verb registration in `lib/coordinator.mjs`. Legacy stores remain the operational
authority until a later cutover stage; nothing here switches writer authority.

- **Shadow writer** (`lib/shadow-writer.mjs`, `bin/cp-shadow.mjs`, and the repo-root
  `bin/fm-cp-shadow.sh` hook). A fire-and-forget mirror firstmate's lifecycle chokepoints
  invoke to write control-plane records in parallel with the legacy op. Three contracts:
  it NEVER blocks or fails a legacy op (every error is logged to a divergence file and
  swallowed, and the shell hook backgrounds the call); it fabricates NO runs (task filed →
  `create-task` queued; every run-based action degrades to an audit annotation in
  `shadow_annotations` unless a real run generation already exists, in which case it drives
  the landed verb); and it is idempotent by deterministic command-id. The hook is INERT
  unless `CP_SHADOW=1`; enabling and wiring it is firstmate's operational act.
- **Divergence monitor** — `cp shadow-diff --out <path> --data-dir <store> [--home <legacy>]`.
  Read-only. Regenerates the S8 mapper's view of the legacy stores on demand, translates it
  through the same CW1 classification the production migration used, and reports
  missing/mismatched/extra live tasks plus archived history that is deferred vs back-filled.
  Applies nothing to the legacy home or the store.
- **Archived-history back-fill** — `cp migrate-backfill --residual <cw1-residual> --data-dir
  <store> --out <path> [--resume]`. Imports the archived-history residual CW1 deferred
  (done-archive / superseded-generation / task-scope-archived-event records) as AUDIT-ONLY
  rows in a distinct `archived_history` table. Live-path synthesis of the terminal-delivery/
  ack/cleanup/archive chain is judged FORBIDDEN (spec §4/§14 + the CW1 anti-ghost rule), so
  the import writes no task/run/event/outbox/consumer row; see `lib/migrate-backfill.mjs`
  `BACKFILL_DECISION` for the full reasoning. Idempotent by `record_key`; input is the
  residual FILE, so no legacy store is read. The snapshot layer can carry `archived_history`;
  folding it into a snapshot is a later (CW3) concern, intentionally not wired into S6 here.

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
