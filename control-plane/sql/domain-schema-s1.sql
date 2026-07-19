-- Control-plane S1 domain schema (tasks, runs, events, producer high-water,
-- command idempotency, base anomalies).
--
-- These are the S1-owned tables per the amended spec (spec-amend-s4 section 3 DDL
-- lines 192-340; section 12 S1 row). They are byte-faithful to the spec DDL with
-- one deliberate difference: every object uses IF NOT EXISTS so the schema can be
-- applied idempotently at the start of every domain transaction (ruling Q7) rather
-- than by a separate migrate step. Re-applying over an already-created schema is a
-- clean no-op.
--
-- S0 tables (schema_meta, coordinator_state) are NOT (re)created here; init() owns
-- them. Later-slice tables (outbox S2; consumer_* S4; snapshots S6) are NOT here;
-- they ship in their owning slices.
--
-- All statements are Postgres/PGlite SQL, applied only through the storage seam
-- (runExclusive); direct SQL is never a public mutation surface (spec section 3.1).

CREATE TABLE IF NOT EXISTS tasks (
  task_id            TEXT PRIMARY KEY,
  home_uuid          TEXT NOT NULL,
  kind               TEXT NOT NULL CHECK (kind IN ('ship','scout','secondmate')),
  title              TEXT NOT NULL,
  repo               TEXT,
  task_origin        TEXT NOT NULL CHECK (task_origin IN ('captain_order','internal')),
  order_ref          TEXT,
  internal_reason    TEXT,
  status             TEXT NOT NULL CHECK (status IN (
                       'queued','spawning','running','blocked','waiting_firstmate',
                       'needs_human','failed','completed','archived')),
  revision           BIGINT NOT NULL DEFAULT 0,
  current_generation INTEGER NOT NULL DEFAULT 0 CHECK (current_generation >= 0),
  created_at         TIMESTAMPTZ NOT NULL,
  updated_at         TIMESTAMPTZ NOT NULL,
  archived_at        TIMESTAMPTZ,
  CONSTRAINT origin_link CHECK (
    (task_origin = 'captain_order' AND order_ref IS NOT NULL AND internal_reason IS NULL) OR
    (task_origin = 'internal'      AND order_ref IS NULL     AND internal_reason IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS ix_tasks_status ON tasks (status);
CREATE INDEX IF NOT EXISTS ix_tasks_order ON tasks (order_ref);

-- task_origin, order_ref, and internal_reason are immutable once a task exists
-- (spec section 3.1: "task_origin and non-null order_ref are immutable through a
-- trigger or through an equivalently tested repository guard"). The combination
-- CHECK above only guards a single row's shape; it does not stop a valid-to-valid
-- rewrite such as ORD-1 -> ORD-2. This BEFORE UPDATE trigger closes that gap at the
-- store level (QA-s1-q49 finding 3). CREATE OR REPLACE keeps it idempotent under
-- the lazy per-transaction schema apply.
CREATE OR REPLACE FUNCTION cp_tasks_origin_immutable() RETURNS trigger AS $cp$
BEGIN
  IF NEW.task_origin IS DISTINCT FROM OLD.task_origin
     OR NEW.order_ref IS DISTINCT FROM OLD.order_ref
     OR NEW.internal_reason IS DISTINCT FROM OLD.internal_reason THEN
    RAISE EXCEPTION 'origin_immutable: task_origin/order_ref/internal_reason are immutable'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$cp$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_tasks_origin_immutable
  BEFORE UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION cp_tasks_origin_immutable();

CREATE TABLE IF NOT EXISTS runs (
  task_id            TEXT NOT NULL,
  run_generation     INTEGER NOT NULL CHECK (run_generation >= 1),
  status             TEXT NOT NULL CHECK (status IN ('spawning','open','failed','completed')),
  binding_state      TEXT NOT NULL DEFAULT 'spawning' CHECK (binding_state IN (
                       'spawning','bound_verified','bound_unverified','lost',
                       'cleanup_pending','closed')),
  backend            TEXT NOT NULL,
  bind_nonce         TEXT NOT NULL,
  launch_marker      TEXT NOT NULL,
  launch_dir         TEXT NOT NULL,
  registration_path  TEXT NOT NULL,
  launch_deadline_at TIMESTAMPTZ NOT NULL,
  endpoint_id        TEXT,
  pane_id            TEXT,
  pane_leader_pid    INTEGER,
  pane_start_ticks   BIGINT,
  boot_id            TEXT,
  agent_pid          INTEGER,
  agent_start_ticks  BIGINT,
  agent_exe          TEXT,
  agent_argv_hash    TEXT,
  agent_ppid         INTEGER,
  agent_pty          TEXT,
  worktree           TEXT,
  harness            TEXT,
  cleanup_state      TEXT NOT NULL DEFAULT 'not_started' CHECK (cleanup_state IN (
                       'not_started','intent_committed','cleaned')),
  cleanup_started_at TIMESTAMPTZ,
  cleanup_finished_at TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL,
  verified_at        TIMESTAMPTZ,
  closed_at          TIMESTAMPTZ,
  PRIMARY KEY (task_id, run_generation),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id),
  CONSTRAINT run_closed_iff_terminal CHECK (
    (status IN ('failed','completed')) = (closed_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_one_open_run ON runs (task_id) WHERE closed_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_launch_marker ON runs (launch_marker);

CREATE TABLE IF NOT EXISTS task_events (
  event_id        TEXT PRIMARY KEY,
  task_id         TEXT NOT NULL REFERENCES tasks(task_id),
  event_scope     TEXT NOT NULL CHECK (event_scope IN ('task','run')),
  run_generation  INTEGER,
  producer_id     TEXT NOT NULL CHECK (producer_id IN
                    ('coordinator','adapter','crewmate','firstmate','reconciler')),
  producer_seq    BIGINT NOT NULL,
  event_type      TEXT NOT NULL CHECK (event_type IN (
                    'created','cancelled','spawn_intent','spawned','running_verified',
                    'progress','blocked','unblocked','waiting_firstmate','needs_human',
                    'rework','identity_lost','completed','failed',
                    'cleanup_started','cleaned','archived','anomaly')),
  generation_key  INTEGER NOT NULL,
  is_terminal     BOOLEAN NOT NULL,
  outcome         TEXT,
  payload_json    JSONB NOT NULL DEFAULT '{}'::jsonb,
  payload_hash    TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL,
  CONSTRAINT scope_gen CHECK (
    (event_scope='task' AND run_generation IS NULL) OR
    (event_scope='run'  AND run_generation IS NOT NULL)),
  CONSTRAINT generation_key_matches CHECK (
    (event_scope='task' AND generation_key = -1) OR
    (event_scope='run'  AND generation_key = run_generation)),
  CONSTRAINT terminal_derived CHECK (
    is_terminal = (event_type IN ('completed','failed'))),
  CONSTRAINT terminal_is_run CHECK (
    (NOT is_terminal) OR event_scope='run'),
  CONSTRAINT outcome_tied CHECK (
    (event_type='completed' AND outcome='success') OR
    (event_type='failed' AND outcome IN ('failure','superseded')) OR
    (event_type NOT IN ('completed','failed') AND outcome IS NULL)),
  CONSTRAINT run_event_fk FOREIGN KEY (task_id, run_generation)
    REFERENCES runs (task_id, run_generation),
  CONSTRAINT uq_event_copy UNIQUE
    (event_id, task_id, generation_key, event_type, payload_hash)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_event_producer_seq
  ON task_events (task_id, COALESCE(run_generation,-1), producer_id, producer_seq);
CREATE UNIQUE INDEX IF NOT EXISTS ux_terminal_per_gen
  ON task_events (task_id, run_generation) WHERE is_terminal;
CREATE INDEX IF NOT EXISTS ix_events_task ON task_events (task_id, run_generation, created_at);

CREATE TABLE IF NOT EXISTS producer_highwater (
  task_id          TEXT NOT NULL,
  run_generation  INTEGER NOT NULL CHECK (run_generation >= -1),
  producer_id     TEXT NOT NULL,
  last_seq        BIGINT NOT NULL,
  last_command_id TEXT,
  updated_at      TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (task_id, run_generation, producer_id)
);

CREATE TABLE IF NOT EXISTS command_results (
  command_id          TEXT PRIMARY KEY,
  verb                TEXT NOT NULL,
  request_hash        TEXT NOT NULL,
  result_json         JSONB NOT NULL,
  committed_revision  BIGINT,
  created_at          TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS anomalies (
  fingerprint          TEXT PRIMARY KEY,
  anomaly_class        TEXT NOT NULL,
  home_uuid            TEXT NOT NULL,
  task_id              TEXT,
  run_generation       INTEGER,
  endpoint_id          TEXT,
  pane_id              TEXT,
  agent_pid            INTEGER,
  agent_start_ticks    BIGINT,
  terminal_fingerprint TEXT,
  status               TEXT NOT NULL CHECK (status IN ('active','resolved')),
  resolution_kind      TEXT,
  resolved_reason      TEXT,
  occurrence_count     INTEGER NOT NULL DEFAULT 1,
  first_seen_at        TIMESTAMPTZ NOT NULL,
  last_seen_at         TIMESTAMPTZ NOT NULL,
  resolved_at          TIMESTAMPTZ,
  detail_json          JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS ix_anomalies_active ON anomalies (status) WHERE status = 'active';
