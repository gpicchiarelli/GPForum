BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_deletion_requests_open_resource_unique
    ON deletion_requests (resource_type, resource_id, request_type)
    WHERE status IN ('pending', 'approved', 'held');

CREATE UNIQUE INDEX IF NOT EXISTS idx_export_requests_pending_unique
    ON export_requests (requester_user_id, subject_user_id, export_type, format)
    WHERE status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS idx_retention_holds_active_resource_unique
    ON retention_holds (resource_type, resource_id)
    WHERE ends_at IS NULL;

COMMIT;
