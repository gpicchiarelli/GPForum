-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- threads.last_activity_at had no writer: every thread kept its creation
-- time, so "latest activity" was creation order. The outbox's ThreadActivity
-- handler now moves a thread up on each reply; this sets existing threads to
-- their latest visible post.

BEGIN;

UPDATE threads t
   SET last_activity_at = latest.created_at
  FROM (
       SELECT thread_id, max(created_at) AS created_at
         FROM posts
        WHERE deleted_at IS NULL
          AND moderation_state = 'visible'
        GROUP BY thread_id
       ) latest
 WHERE latest.thread_id = t.thread_id
   AND latest.created_at > t.last_activity_at;

COMMIT;
