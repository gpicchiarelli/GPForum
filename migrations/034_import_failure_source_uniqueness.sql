BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_import_failures_source_unique
    ON import_failures (import_job_id, source_record_type, source_record_id);

COMMIT;
