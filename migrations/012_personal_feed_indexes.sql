BEGIN;

CREATE INDEX IF NOT EXISTS idx_user_feed_items_user_created
    ON user_feed_items (user_id, created_at DESC, item_id DESC)
    INCLUDE (item_type, rank_score, visibility_version, permission_version);

COMMIT;
