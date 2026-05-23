BEGIN;

CREATE TABLE IF NOT EXISTS event_log (
    event_id uuid NOT NULL,
    event_type text NOT NULL,
    schema_version integer NOT NULL,
    aggregate_type text NOT NULL,
    aggregate_id uuid,
    actor_id uuid,
    correlation_id uuid NOT NULL,
    causation_id uuid,
    idempotency_key text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT event_log_pkey PRIMARY KEY (event_id, created_at),
    CONSTRAINT event_log_schema_version_check CHECK (schema_version > 0)
) PARTITION BY RANGE (created_at);

CREATE TABLE IF NOT EXISTS event_log_default
    PARTITION OF event_log DEFAULT;

CREATE INDEX IF NOT EXISTS idx_event_log_aggregate_created_at
    ON event_log (aggregate_type, aggregate_id, created_at);

CREATE INDEX IF NOT EXISTS idx_event_log_type_created_at
    ON event_log (event_type, created_at);

CREATE INDEX IF NOT EXISTS idx_event_log_correlation
    ON event_log (correlation_id);

CREATE INDEX IF NOT EXISTS idx_event_log_idempotency_key
    ON event_log (idempotency_key);

CREATE INDEX IF NOT EXISTS idx_event_log_created_at_brin
    ON event_log USING BRIN (created_at);

CREATE TABLE IF NOT EXISTS event_idempotency_keys (
    idempotency_key text NOT NULL,
    event_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT event_idempotency_keys_pkey PRIMARY KEY (idempotency_key)
);

CREATE TABLE IF NOT EXISTS idempotency_keys (
    key text NOT NULL,
    actor_id uuid,
    command_type text NOT NULL,
    response_hash text,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    CONSTRAINT idempotency_keys_pkey PRIMARY KEY (key),
    CONSTRAINT idempotency_keys_expires_after_created_check CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS idx_idempotency_keys_actor_command
    ON idempotency_keys (actor_id, command_type, created_at);

CREATE TABLE IF NOT EXISTS audit_log (
    audit_id uuid NOT NULL,
    action text NOT NULL,
    schema_version integer NOT NULL,
    actor_id uuid,
    target_type text,
    target_id uuid,
    correlation_id uuid NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT audit_log_pkey PRIMARY KEY (audit_id, created_at),
    CONSTRAINT audit_log_schema_version_check CHECK (schema_version > 0)
) PARTITION BY RANGE (created_at);

CREATE TABLE IF NOT EXISTS audit_log_default
    PARTITION OF audit_log DEFAULT;

CREATE INDEX IF NOT EXISTS idx_audit_log_actor_created_at
    ON audit_log (actor_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_log_action_created_at
    ON audit_log (action, created_at);

CREATE INDEX IF NOT EXISTS idx_audit_log_target_created_at
    ON audit_log (target_type, target_id, created_at);

CREATE INDEX IF NOT EXISTS idx_audit_log_correlation
    ON audit_log (correlation_id);

CREATE INDEX IF NOT EXISTS idx_audit_log_created_at_brin
    ON audit_log USING BRIN (created_at);

CREATE TABLE IF NOT EXISTS outbox_messages (
    outbox_id uuid NOT NULL,
    event_id uuid NOT NULL,
    queue text NOT NULL,
    job_type text NOT NULL,
    idempotency_key text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    available_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    locked_at timestamptz,
    attempts integer NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'pending',
    last_error text,
    CONSTRAINT outbox_messages_pkey PRIMARY KEY (outbox_id),
    CONSTRAINT outbox_messages_idempotency_key_key UNIQUE (idempotency_key),
    CONSTRAINT outbox_messages_attempts_check CHECK (attempts >= 0),
    CONSTRAINT outbox_messages_status_check CHECK (status IN ('pending', 'running', 'done', 'failed', 'cancelled'))
);

CREATE INDEX IF NOT EXISTS idx_outbox_messages_dispatch
    ON outbox_messages (status, available_at, created_at);

COMMIT;
