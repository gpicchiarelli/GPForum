BEGIN;

CREATE INDEX IF NOT EXISTS idx_threads_public_activity
    ON threads (last_activity_at DESC, thread_id DESC)
    INCLUDE (category_id, author_user_id, title, slug, pinned, visibility,
        moderation_state, created_at)
    WHERE deleted_at IS NULL
      AND visibility = 'public'
      AND moderation_state IN ('visible', 'locked');

CREATE INDEX IF NOT EXISTS idx_threads_category_activity_visible_locked
    ON threads (category_id, pinned DESC, last_activity_at DESC,
        thread_id DESC)
    INCLUDE (title, author_user_id, slug, visibility, moderation_state,
        created_at)
    WHERE deleted_at IS NULL
      AND moderation_state IN ('visible', 'locked');

CREATE INDEX IF NOT EXISTS idx_posts_visible_thread_position
    ON posts (thread_id, position ASC, post_id ASC)
    INCLUDE (author_user_id, current_body_id, current_revision_id, visibility,
        moderation_state, created_at)
    WHERE deleted_at IS NULL
      AND moderation_state = 'visible';

COMMIT;
