-- Control-plane S2 domain schema (outbox).
--
-- The S2-owned table per the amended spec (spec-amend-s4 section 3 DDL lines
-- 342-363; section 12 S2 row). Byte-faithful to the spec DDL with the same single
-- deliberate difference S1 made: every object uses IF NOT EXISTS so the schema can
-- be applied idempotently at the start of every S2 domain transaction. Re-applying
-- over an already-created schema is a clean no-op.
--
-- S2 applies ONLY this file (ruling RISK#6). It never re-applies or imports the S1
-- schema: every S2 verb's precondition is an existing task (complete/fail also
-- require an existing run), so the S1 tables are guaranteed present by the time any
-- statement here runs. There is deliberately no defensive cross-slice schema
-- import. Later-slice tables (consumer_* S4; snapshots S6) are NOT here.
--
-- All statements are Postgres/PGlite SQL, applied only through the storage seam
-- (runExclusive); direct SQL is never a public mutation surface (spec section 3.1).

CREATE TABLE IF NOT EXISTS outbox (
  outbox_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_id          TEXT NOT NULL UNIQUE REFERENCES task_events(event_id),
  task_id           TEXT NOT NULL,
  run_generation    INTEGER,
  generation_key    INTEGER NOT NULL,
  task_seq          BIGINT NOT NULL,
  event_type        TEXT NOT NULL,
  payload_hash      TEXT NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL,
  delivery_attempts INTEGER NOT NULL DEFAULT 0,
  delivered_at      TIMESTAMPTZ,
  acked_at          TIMESTAMPTZ,
  -- Task-scope rows (coordinator-generated `cancelled`) carry run_generation NULL
  -- with generation_key -1; run-scope rows mirror their generation (spec section
  -- 3.1 R3-1). This is what keeps a task-scope delivery insertable while the
  -- event-copy FK below still holds.
  CONSTRAINT outbox_generation_key_matches CHECK (
    (run_generation IS NULL AND generation_key = -1) OR
    (run_generation IS NOT NULL AND generation_key = run_generation)),
  -- Secondary within-generation ordering (ruling RISK#3). Global delivery order is
  -- the outbox_id IDENTITY; task_seq orders only within (task_id, generation_key).
  CONSTRAINT ux_outbox_task_seq UNIQUE (task_id, generation_key, task_seq),
  -- An outbox row is an exact COPY of its task_events row's identifying 5-tuple,
  -- not an independently-authored record: it cannot name an event that does not
  -- exist, nor restate that event's type/scope/payload differently.
  CONSTRAINT fk_outbox_event_copy
    FOREIGN KEY (event_id, task_id, generation_key, event_type, payload_hash)
    REFERENCES task_events (event_id, task_id, generation_key, event_type, payload_hash)
);
CREATE INDEX IF NOT EXISTS ix_outbox_unacked ON outbox (outbox_id) WHERE acked_at IS NULL;
