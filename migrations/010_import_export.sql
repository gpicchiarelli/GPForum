BEGIN;

CREATE TABLE IF NOT EXISTS import_jobs (
    import_job_id uuid NOT NULL,
    source_system text NOT NULL,
    adapter_name text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    dry_run boolean NOT NULL DEFAULT true,
    manifest jsonb NOT NULL DEFAULT '{}'::jsonb,
    progress jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz,
    CONSTRAINT import_jobs_pkey PRIMARY KEY (import_job_id),
    CONSTRAINT import_jobs_status_check CHECK (status IN ('pending', 'running', 'completed', 'failed', 'quarantined')),
    CONSTRAINT import_jobs_created_by_fkey FOREIGN KEY (created_by) REFERENCES users (id),
    CONSTRAINT import_jobs_finished_after_created_check CHECK (finished_at IS NULL OR finished_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_import_jobs_status_created
    ON import_jobs (status, created_at);

CREATE TABLE IF NOT EXISTS import_failures (
    import_failure_id uuid NOT NULL,
    import_job_id uuid NOT NULL,
    source_record_type text NOT NULL,
    source_record_id text NOT NULL,
    error_code text NOT NULL,
    error_message text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT import_failures_pkey PRIMARY KEY (import_failure_id),
    CONSTRAINT import_failures_import_job_id_fkey FOREIGN KEY (import_job_id) REFERENCES import_jobs (import_job_id)
);

CREATE INDEX IF NOT EXISTS idx_import_failures_job
    ON import_failures (import_job_id, source_record_type, created_at);

CREATE TABLE IF NOT EXISTS legacy_id_map (
    legacy_id_map_id uuid NOT NULL,
    import_job_id uuid NOT NULL,
    legacy_type text NOT NULL,
    legacy_id text NOT NULL,
    native_type text NOT NULL,
    native_id uuid NOT NULL,
    canonical_url text,
    visibility text NOT NULL DEFAULT 'public',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT legacy_id_map_pkey PRIMARY KEY (legacy_id_map_id),
    CONSTRAINT legacy_id_map_import_job_id_fkey FOREIGN KEY (import_job_id) REFERENCES import_jobs (import_job_id),
    CONSTRAINT legacy_id_map_source_key UNIQUE (legacy_type, legacy_id),
    CONSTRAINT legacy_id_map_visibility_check CHECK (visibility IN ('public', 'members', 'private', 'deleted'))
);

CREATE INDEX IF NOT EXISTS idx_legacy_id_map_native
    ON legacy_id_map (native_type, native_id);

CREATE TABLE IF NOT EXISTS export_requests (
    export_request_id uuid NOT NULL,
    requester_user_id uuid NOT NULL,
    subject_user_id uuid NOT NULL,
    export_type text NOT NULL,
    format text NOT NULL DEFAULT 'json',
    status text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    manifest jsonb NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT export_requests_pkey PRIMARY KEY (export_request_id),
    CONSTRAINT export_requests_requester_user_id_fkey FOREIGN KEY (requester_user_id) REFERENCES users (id),
    CONSTRAINT export_requests_subject_user_id_fkey FOREIGN KEY (subject_user_id) REFERENCES users (id),
    CONSTRAINT export_requests_type_check CHECK (export_type IN ('user_data', 'admin_content', 'moderation_audit')),
    CONSTRAINT export_requests_format_check CHECK (format IN ('json')),
    CONSTRAINT export_requests_status_check CHECK (status IN ('pending', 'running', 'completed', 'failed')),
    CONSTRAINT export_requests_finished_after_created_check CHECK (finished_at IS NULL OR finished_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_export_requests_subject_created
    ON export_requests (subject_user_id, created_at DESC);

COMMIT;
