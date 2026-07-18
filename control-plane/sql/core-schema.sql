-- Control-plane core schema (S0-owned tables).
-- These are the only tables S0 owns per the amended spec (spec-amend-s4 section 12,
-- S0 row). The storage-seam contract probe runs against these tables alone, so it
-- exercises open/lock/transaction/durability "without domain tables" on any adapter.
--
-- All statements are Postgres/PGlite SQL. Applied idempotently: every object uses
-- IF NOT EXISTS so re-running `cp init` is a no-op on an already-seeded database.

CREATE TABLE IF NOT EXISTS schema_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS coordinator_state (
  id                  SMALLINT PRIMARY KEY CHECK (id = 1),
  domain_revision     BIGINT NOT NULL DEFAULT 0,
  projection_revision BIGINT NOT NULL DEFAULT 0,
  commit_sequence     BIGINT NOT NULL DEFAULT 0,
  writer_pid          INTEGER,
  writer_boot_id      TEXT,
  writer_started_at   TIMESTAMPTZ
);
