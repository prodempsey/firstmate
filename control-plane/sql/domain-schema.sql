-- Control-plane domain schema.
--
-- This is the complete control-plane domain DDL transcribed verbatim from the
-- amended spec (spec-amend-s4 section 3), with `IF NOT EXISTS` added on every
-- object so `cp init` is idempotent (spec section 6: init is idempotent).
--
-- Table/verb OWNERSHIP still follows the slice plan (S1..S6). S0 applies the whole
-- schema because the S0 acceptance requires "DDL applies clean" and the constraint
-- rejection tests, and because a schema is applied as one coherent unit. S0 does
-- NOT implement the later-slice verbs that mutate these tables; only `create-task`
-- and `task-head` are implemented (see control-plane/README.md "Scope").

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
  CONSTRAINT outbox_generation_key_matches CHECK (
    (run_generation IS NULL AND generation_key = -1) OR
    (run_generation IS NOT NULL AND generation_key = run_generation)),
  UNIQUE (task_id, generation_key, task_seq),
  CONSTRAINT fk_outbox_event_copy
    FOREIGN KEY (event_id, task_id, generation_key, event_type, payload_hash)
    REFERENCES task_events (event_id, task_id, generation_key, event_type, payload_hash)
);
CREATE INDEX IF NOT EXISTS ix_outbox_unacked ON outbox (outbox_id) WHERE acked_at IS NULL;

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
