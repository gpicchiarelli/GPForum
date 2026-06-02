BEGIN;

CREATE INDEX IF NOT EXISTS idx_outbox_messages_claim_ready
    ON outbox_messages (next_attempt_at, created_at, outbox_id)
    WHERE status IN ('pending', 'failed');

CREATE INDEX IF NOT EXISTS idx_outbox_messages_pending_ready
    ON outbox_messages (next_attempt_at, created_at, outbox_id)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_outbox_messages_failed_ready
    ON outbox_messages (next_attempt_at, created_at, outbox_id)
    WHERE status = 'failed';

CREATE INDEX IF NOT EXISTS idx_outbox_messages_stale_locks
    ON outbox_messages (locked_until, next_attempt_at, created_at, outbox_id)
    WHERE status = 'running';

COMMIT;
