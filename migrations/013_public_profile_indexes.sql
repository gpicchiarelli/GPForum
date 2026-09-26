-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE INDEX IF NOT EXISTS idx_threads_author_public_activity
    ON threads (author_user_id, last_activity_at DESC, thread_id DESC)
    INCLUDE (category_id, title, slug, created_at)
    WHERE deleted_at IS NULL
      AND moderation_state = 'visible'
      AND visibility = 'public';

COMMIT;
