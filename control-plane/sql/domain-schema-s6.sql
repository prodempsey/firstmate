-- Control-plane S6 domain schema (snapshots).
--
-- The S6-owned table per the amended spec (spec-amend-s4 section 3 DDL lines
-- 401-412; section 12 S6 row 891). Byte-faithful to the spec DDL with the same
-- single deliberate difference S1/S2/S4 made: every object uses IF NOT EXISTS so
-- the schema can be applied idempotently at the start of every S6 snapshot
-- transaction. Re-applying over an already-created schema is a clean no-op.
--
-- S6 applies ONLY this file (the applyS2Schema pattern). The snapshots table has no
-- foreign key to any domain table: a snapshot is an immutable, self-contained
-- PROJECTION of domain state captured at build time, not a live reference into it,
-- so it never depends on S1-S5 tables being present to CREATE and there is no
-- cross-slice ordering hazard. The snapshot build reads the domain tables (guarded
-- by presence checks) INSIDE the same exclusive transaction that inserts the row,
-- for a consistent view; it never mutates them.
--
-- projection_revision is UNIQUE (spec 403): every new snapshot carries a strictly
-- increasing projection revision, and `cp snapshot` is the ONLY writer of
-- coordinator_state.projection_revision in the entire system.
--
-- The four-column dedup UNIQUE (spec 411) is what makes repeated snapshots
-- idempotent: a rebuild over unchanged (domain_revision, order prefix bytes/hash,
-- payload checksum) matches the latest row and returns it without inserting a
-- second, and the constraint is the structural backstop behind the in-transaction
-- dedup SELECT.
--
-- All statements are Postgres/PGlite SQL, applied only through the storage seam
-- (runExclusive); direct SQL is never a public mutation surface (spec section 3.1).

CREATE TABLE IF NOT EXISTS snapshots (
  snapshot_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  projection_revision BIGINT NOT NULL UNIQUE,
  domain_revision    BIGINT NOT NULL,
  checksum           TEXT NOT NULL,
  order_source_path  TEXT NOT NULL,
  order_source_bytes BIGINT NOT NULL,
  order_source_hash  TEXT NOT NULL,
  created_at         TIMESTAMPTZ NOT NULL,
  payload_json       JSONB NOT NULL,
  UNIQUE (domain_revision, order_source_bytes, order_source_hash, checksum)
);
