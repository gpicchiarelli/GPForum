BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_erasure_jobs_request_unique
    ON erasure_jobs (deletion_request_id);

COMMIT;
