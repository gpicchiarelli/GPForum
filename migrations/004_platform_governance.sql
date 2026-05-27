BEGIN;

CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS security;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS search;
CREATE SCHEMA IF NOT EXISTS jobs;
CREATE SCHEMA IF NOT EXISTS analytics;

CREATE TABLE IF NOT EXISTS command_log (
    command_id uuid NOT NULL,
    command_type text NOT NULL,
    actor_id uuid,
    correlation_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    response_hash text,
    status text NOT NULL DEFAULT 'accepted',
    created_at timestamptz NOT NULL DEFAULT now(),
    handled_at timestamptz,
    CONSTRAINT command_log_pkey PRIMARY KEY (command_id),
    CONSTRAINT command_log_idempotency_key_key UNIQUE (idempotency_key),
    CONSTRAINT command_log_status_check CHECK (status IN ('accepted', 'rejected', 'handled', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_command_log_actor_created_at
    ON command_log (actor_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_command_log_correlation
    ON command_log (correlation_id);

CREATE TABLE IF NOT EXISTS role_binding_events (
    role_binding_event_id uuid NOT NULL,
    binding_id uuid,
    actor_id uuid,
    user_id uuid NOT NULL,
    role_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid,
    event_type text NOT NULL,
    valid_from timestamptz NOT NULL DEFAULT now(),
    valid_to timestamptz,
    reason text,
    correlation_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT role_binding_events_pkey PRIMARY KEY (role_binding_event_id),
    CONSTRAINT role_binding_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT role_binding_events_role_id_fkey FOREIGN KEY (role_id) REFERENCES roles (role_id),
    CONSTRAINT role_binding_events_valid_window_check CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT role_binding_events_type_check CHECK (event_type IN ('granted', 'revoked', 'expired'))
);

CREATE TABLE IF NOT EXISTS permission_grants (
    permission_grant_id uuid NOT NULL,
    actor_id uuid,
    user_id uuid,
    role_id uuid,
    permission_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid,
    valid_from timestamptz NOT NULL DEFAULT now(),
    valid_to timestamptz,
    reason text,
    correlation_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT permission_grants_pkey PRIMARY KEY (permission_grant_id),
    CONSTRAINT permission_grants_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT permission_grants_role_id_fkey FOREIGN KEY (role_id) REFERENCES roles (role_id),
    CONSTRAINT permission_grants_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES permissions (permission_id),
    CONSTRAINT permission_grants_valid_window_check CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE IF NOT EXISTS permission_revocations (
    permission_revocation_id uuid NOT NULL,
    permission_grant_id uuid,
    actor_id uuid,
    reason text NOT NULL DEFAULT '',
    correlation_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT permission_revocations_pkey PRIMARY KEY (permission_revocation_id),
    CONSTRAINT permission_revocations_permission_grant_id_fkey FOREIGN KEY (permission_grant_id) REFERENCES permission_grants (permission_grant_id)
);

CREATE TABLE IF NOT EXISTS effective_permissions (
    principal_type text NOT NULL,
    principal_id uuid NOT NULL,
    permission_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid,
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    permission_version bigint NOT NULL,
    source_generation_id uuid NOT NULL,
    CONSTRAINT effective_permissions_pkey PRIMARY KEY (principal_type, principal_id, permission_id, resource_type, resource_id),
    CONSTRAINT effective_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES permissions (permission_id),
    CONSTRAINT effective_permissions_version_check CHECK (permission_version > 0),
    CONSTRAINT effective_permissions_valid_window_check CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE IF NOT EXISTS visibility_events (
    visibility_event_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    old_visibility text,
    new_visibility text NOT NULL,
    actor_id uuid,
    reason text NOT NULL DEFAULT '',
    correlation_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT visibility_events_pkey PRIMARY KEY (visibility_event_id),
    CONSTRAINT visibility_events_new_visibility_check CHECK (new_visibility IN ('public', 'members', 'private')),
    CONSTRAINT visibility_events_old_visibility_check CHECK (old_visibility IS NULL OR old_visibility IN ('public', 'members', 'private'))
);

CREATE INDEX IF NOT EXISTS idx_visibility_events_resource_created_at
    ON visibility_events (resource_type, resource_id, created_at);

CREATE TABLE IF NOT EXISTS deletion_requests (
    deletion_request_id uuid NOT NULL,
    requester_user_id uuid,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    request_type text NOT NULL,
    reason text NOT NULL DEFAULT '',
    status text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    CONSTRAINT deletion_requests_pkey PRIMARY KEY (deletion_request_id),
    CONSTRAINT deletion_requests_requester_user_id_fkey FOREIGN KEY (requester_user_id) REFERENCES users (id),
    CONSTRAINT deletion_requests_type_check CHECK (request_type IN ('soft_delete', 'anonymize', 'hard_purge')),
    CONSTRAINT deletion_requests_status_check CHECK (status IN ('pending', 'approved', 'rejected', 'completed', 'held'))
);

CREATE TABLE IF NOT EXISTS deletion_actions (
    deletion_action_id uuid NOT NULL,
    deletion_request_id uuid NOT NULL,
    actor_id uuid,
    action_type text NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT deletion_actions_pkey PRIMARY KEY (deletion_action_id),
    CONSTRAINT deletion_actions_request_id_fkey FOREIGN KEY (deletion_request_id) REFERENCES deletion_requests (deletion_request_id),
    CONSTRAINT deletion_actions_type_check CHECK (action_type IN ('soft_deleted', 'anonymized', 'purged', 'held', 'released'))
);

CREATE TABLE IF NOT EXISTS erasure_jobs (
    erasure_job_id uuid NOT NULL,
    deletion_request_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    scheduled_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    last_error text,
    CONSTRAINT erasure_jobs_pkey PRIMARY KEY (erasure_job_id),
    CONSTRAINT erasure_jobs_request_id_fkey FOREIGN KEY (deletion_request_id) REFERENCES deletion_requests (deletion_request_id),
    CONSTRAINT erasure_jobs_status_check CHECK (status IN ('pending', 'running', 'done', 'failed', 'cancelled'))
);

CREATE TABLE IF NOT EXISTS retention_holds (
    retention_hold_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    reason text NOT NULL,
    starts_at timestamptz NOT NULL DEFAULT now(),
    ends_at timestamptz,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT retention_holds_pkey PRIMARY KEY (retention_hold_id),
    CONSTRAINT retention_holds_window_check CHECK (ends_at IS NULL OR ends_at > starts_at)
);

CREATE TABLE IF NOT EXISTS audit_checkpoints (
    checkpoint_id uuid NOT NULL,
    checkpoint_scope text NOT NULL,
    root_hash text NOT NULL,
    first_audit_id uuid,
    last_audit_id uuid,
    range_start timestamptz NOT NULL,
    range_end timestamptz NOT NULL,
    exported_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT audit_checkpoints_pkey PRIMARY KEY (checkpoint_id),
    CONSTRAINT audit_checkpoints_range_check CHECK (range_end > range_start)
);

CREATE TABLE IF NOT EXISTS projection_offsets (
    projection_name text NOT NULL,
    last_event_id uuid,
    last_event_created_at timestamptz,
    lag_seconds integer NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'initializing',
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT projection_offsets_pkey PRIMARY KEY (projection_name),
    CONSTRAINT projection_offsets_lag_check CHECK (lag_seconds >= 0),
    CONSTRAINT projection_offsets_status_check CHECK (status IN ('initializing', 'catching_up', 'current', 'degraded', 'failed'))
);

CREATE TABLE IF NOT EXISTS projection_generations (
    generation_id uuid NOT NULL,
    projection_name text NOT NULL,
    built_from_event_id uuid,
    built_from_event_created_at timestamptz,
    is_active boolean NOT NULL DEFAULT false,
    status text NOT NULL DEFAULT 'building',
    created_at timestamptz NOT NULL DEFAULT now(),
    activated_at timestamptz,
    CONSTRAINT projection_generations_pkey PRIMARY KEY (generation_id),
    CONSTRAINT projection_generations_status_check CHECK (status IN ('building', 'ready', 'active', 'failed', 'retired'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_projection_generations_one_active
    ON projection_generations (projection_name)
    WHERE is_active;

CREATE TABLE IF NOT EXISTS partition_registry (
    table_name text NOT NULL,
    partition_name text NOT NULL,
    range_start timestamptz NOT NULL,
    range_end timestamptz NOT NULL,
    state text NOT NULL DEFAULT 'planned',
    created_at timestamptz NOT NULL DEFAULT now(),
    detached_at timestamptz,
    archived_at timestamptz,
    CONSTRAINT partition_registry_pkey PRIMARY KEY (table_name, partition_name),
    CONSTRAINT partition_registry_range_check CHECK (range_end > range_start),
    CONSTRAINT partition_registry_state_check CHECK (state IN ('planned', 'created', 'detached', 'archived', 'dropped'))
);

ALTER TABLE outbox_messages
    ADD COLUMN IF NOT EXISTS next_attempt_at timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS locked_by text,
    ADD COLUMN IF NOT EXISTS locked_until timestamptz,
    ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_error_class text;

ALTER TABLE outbox_messages
    ADD CONSTRAINT outbox_messages_attempt_count_check CHECK (attempt_count >= 0);

CREATE INDEX IF NOT EXISTS idx_outbox_messages_ready
    ON outbox_messages (status, next_attempt_at)
    WHERE status IN ('pending', 'failed');

CREATE TABLE IF NOT EXISTS dead_letters (
    dead_letter_id uuid NOT NULL,
    source_table text NOT NULL,
    source_id uuid NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_class text NOT NULL,
    error_message text NOT NULL,
    retry_count integer NOT NULL DEFAULT 0,
    first_failed_at timestamptz NOT NULL DEFAULT now(),
    last_failed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT dead_letters_pkey PRIMARY KEY (dead_letter_id),
    CONSTRAINT dead_letters_retry_count_check CHECK (retry_count >= 0)
);

CREATE TABLE IF NOT EXISTS thread_counter_shards (
    thread_id uuid NOT NULL,
    shard_id integer NOT NULL,
    reply_count_delta bigint NOT NULL DEFAULT 0,
    last_updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT thread_counter_shards_pkey PRIMARY KEY (thread_id, shard_id),
    CONSTRAINT thread_counter_shards_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads (thread_id),
    CONSTRAINT thread_counter_shards_shard_check CHECK (shard_id >= 0)
);

CREATE TABLE IF NOT EXISTS view_count_deltas (
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    bucket_start timestamptz NOT NULL,
    delta bigint NOT NULL DEFAULT 0,
    CONSTRAINT view_count_deltas_pkey PRIMARY KEY (resource_type, resource_id, bucket_start)
);

CREATE TABLE IF NOT EXISTS user_read_marker_deltas (
    user_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    last_read_position bigint NOT NULL,
    last_read_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_read_marker_deltas_pkey PRIMARY KEY (user_id, thread_id),
    CONSTRAINT user_read_marker_deltas_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT user_read_marker_deltas_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads (thread_id)
);

CREATE TABLE IF NOT EXISTS thread_read_state (
    user_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    last_read_position bigint NOT NULL,
    last_read_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT thread_read_state_pkey PRIMARY KEY (user_id, thread_id),
    CONSTRAINT thread_read_state_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT thread_read_state_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads (thread_id)
);

CREATE TABLE IF NOT EXISTS endpoint_query_budgets (
    endpoint_name text NOT NULL,
    max_queries integer NOT NULL,
    max_transactions integer NOT NULL DEFAULT 1,
    notes text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT endpoint_query_budgets_pkey PRIMARY KEY (endpoint_name),
    CONSTRAINT endpoint_query_budgets_queries_check CHECK (max_queries > 0),
    CONSTRAINT endpoint_query_budgets_transactions_check CHECK (max_transactions > 0)
);

CREATE TABLE IF NOT EXISTS database_role_contracts (
    role_name text NOT NULL,
    purpose text NOT NULL,
    may_migrate boolean NOT NULL DEFAULT false,
    may_read_credentials boolean NOT NULL DEFAULT false,
    may_write_audit boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT database_role_contracts_pkey PRIMARY KEY (role_name)
);

INSERT INTO database_role_contracts (role_name, purpose, may_migrate, may_read_credentials, may_write_audit)
VALUES
    ('gpforum_web', 'SSR web traffic', false, false, false),
    ('gpforum_worker', 'async jobs and projections', false, false, true),
    ('gpforum_migrator', 'schema changes only', true, false, true),
    ('gpforum_readonly', 'support and reporting reads', false, false, false),
    ('gpforum_admin', 'controlled administrative maintenance', false, true, true)
ON CONFLICT (role_name) DO NOTHING;

CREATE TABLE IF NOT EXISTS migration_safety (
    version text NOT NULL,
    checksum text NOT NULL,
    applied_by text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    execution_time_ms integer,
    requires_lock boolean NOT NULL DEFAULT false,
    reversible boolean NOT NULL DEFAULT false,
    rollback_sql_hash text,
    CONSTRAINT migration_safety_pkey PRIMARY KEY (version),
    CONSTRAINT migration_safety_execution_time_check CHECK (execution_time_ms IS NULL OR execution_time_ms >= 0)
);

COMMIT;
