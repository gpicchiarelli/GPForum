BEGIN;

CREATE TABLE IF NOT EXISTS schema_versions (
    version text NOT NULL,
    description text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT schema_versions_pkey PRIMARY KEY (version)
);

CREATE TABLE IF NOT EXISTS event_log (
    event_id uuid NOT NULL,
    event_type text NOT NULL,
    aggregate_type text NOT NULL,
    aggregate_id uuid,
    actor_id uuid,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT event_log_pkey PRIMARY KEY (event_id)
);

CREATE INDEX IF NOT EXISTS idx_event_log_type_created_at
    ON event_log (event_type, created_at);

CREATE INDEX IF NOT EXISTS idx_event_log_aggregate
    ON event_log (aggregate_type, aggregate_id, created_at);

CREATE TABLE IF NOT EXISTS audit_log (
    audit_id uuid NOT NULL,
    action text NOT NULL,
    actor_id uuid,
    target_type text,
    target_id uuid,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT audit_log_pkey PRIMARY KEY (audit_id)
);

CREATE INDEX IF NOT EXISTS idx_audit_log_action_created_at
    ON audit_log (action, created_at);

COMMIT;
