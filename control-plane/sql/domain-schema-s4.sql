-- Control-plane S4 domain schema (FirstMate consumer: leases, cursors, receipts).
--
-- The S4-owned tables per the amended spec (spec-amend-s4 section 3 DDL lines
-- 365-399; section 12 S4 row). Byte-faithful to the spec DDL with the same single
-- deliberate difference S1 and S2 made: every object uses IF NOT EXISTS so the
-- schema can be applied idempotently at the start of every S4 domain transaction.
-- Re-applying over an already-created schema is a clean no-op.
--
-- S4 applies ONLY this file (the applyS2Schema pattern). These three tables carry NO
-- foreign keys (the spec keys them by consumer_id/event_id only, with
-- consumer_receipts.event_id a TEXT with no FK and last_acked_outbox_id a bare
-- BIGINT), so they are standalone and never depend on S1/S2 tables being present to
-- CREATE - there is no cross-schema ordering hazard. The verbs that read the S2
-- `outbox` (next/claim-delivery/mark-applied/ack) reach it only once a deliverable
-- event already produced an outbox row, so that table is guaranteed present by the
-- time it is read; a genuinely absent outbox is an environment error, raised loudly,
-- never silently created here (ruling RISK#1). There is deliberately no defensive
-- cross-slice schema import, and later-slice tables (snapshots S6) are NOT here.
--
-- All statements are Postgres/PGlite SQL, applied only through the storage seam
-- (runExclusive); direct SQL is never a public mutation surface (spec section 3.1).

CREATE TABLE IF NOT EXISTS consumer_cursors (
  consumer_id          TEXT PRIMARY KEY,
  last_acked_outbox_id BIGINT NOT NULL DEFAULT 0,
  last_acked_at        TIMESTAMPTZ,
  updated_at           TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS consumer_leases (
  consumer_id      TEXT PRIMARY KEY,
  owner_token      TEXT NOT NULL,
  owner_epoch      BIGINT NOT NULL,
  owner_boot_id    TEXT NOT NULL,
  owner_pid        INTEGER NOT NULL,
  lease_expires_at TIMESTAMPTZ NOT NULL,
  updated_at       TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS consumer_receipts (
  consumer_id          TEXT NOT NULL,
  event_id             TEXT NOT NULL,
  state                TEXT NOT NULL CHECK (state IN ('claimed','applied')),
  owner_token          TEXT NOT NULL,
  owner_epoch          BIGINT NOT NULL,
  claimed_at           TIMESTAMPTZ NOT NULL,
  claim_expires_at     TIMESTAMPTZ NOT NULL,
  sink_kind            TEXT NOT NULL,
  sink_idempotency_key TEXT NOT NULL,
  applied_disposition  JSONB,
  sink_result_hash     TEXT,
  applied_at           TIMESTAMPTZ,
  PRIMARY KEY (consumer_id, event_id),
  CONSTRAINT applied_has_result CHECK (
    (state='claimed' AND applied_at IS NULL AND sink_result_hash IS NULL) OR
    (state='applied' AND applied_at IS NOT NULL AND sink_result_hash IS NOT NULL))
);
