-- GPForum viewer and profile thread indexes.
--
-- A signed-in reader of a category also sees their own deleted threads.
-- ThreadReader used to ask for that as
--
--   WHERE category_id = ? AND (deleted_at IS NULL OR author_user_id = ?) ...
--
-- and every index on threads that leads with category_id is partial on
-- deleted_at IS NULL, which that OR does not imply. With sequential scans
-- disabled PostgreSQL 18 still chose one ("Disabled: true"): no index could
-- answer the query, so every signed-in category page read the whole table.
--
-- The reader now fetches the two halves separately inside one statement --
-- the visible threads from idx_threads_category_activity_visible_locked, the
-- viewer's own deleted threads from the index below -- each in page order and
-- cut at the page size, and takes the page from their union. This index holds
-- deleted threads only, so it stays small and is almost never written: a
-- thread enters it once, when it is deleted.
--
-- The public profile lists and counts an author's threads that are visible or
-- locked. idx_threads_author_public_activity was built for
-- moderation_state = 'visible' only, which IN ('visible', 'locked') does not
-- imply, so the profile walked the site-wide activity index and filtered by
-- author instead. It is rebuilt with the predicate the query states.
--
-- Not CONCURRENTLY: the runner executes migrations inside a transaction. Each
-- build takes a SHARE lock on threads, which blocks writes -- including the
-- last_activity_at update every reply makes -- for its duration. On a large
-- forum run this during a maintenance window.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_threads_deleted_category_activity
    ON threads (category_id, pinned DESC, last_activity_at DESC,
        thread_id DESC)
    INCLUDE (author_user_id, visibility, moderation_state)
    WHERE deleted_at IS NOT NULL;

DROP INDEX IF EXISTS idx_threads_author_public_activity;

CREATE INDEX IF NOT EXISTS idx_threads_author_public_activity
    ON threads (author_user_id, last_activity_at DESC, thread_id DESC)
    INCLUDE (category_id, title, slug, created_at)
    WHERE deleted_at IS NULL
      AND moderation_state IN ('visible', 'locked')
      AND visibility = 'public';

COMMIT;
