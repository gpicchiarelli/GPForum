BEGIN;

CREATE INDEX IF NOT EXISTS idx_notification_inbox_recipient_created
    ON notification_inbox (recipient_user_id, created_at DESC,
        notification_id DESC)
    INCLUDE (read_at, rank_score);

COMMIT;
