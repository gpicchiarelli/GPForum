-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- Removing an item from every feed (a hidden or deleted post or thread)
-- deletes by (item_type, item_id), and user_feed_items could only be read by
-- user: its primary key and both indexes lead with user_id. Each removal read
-- the whole table, once per post of a removed thread.
--
-- Not CONCURRENTLY: the runner executes migrations inside a transaction. The
-- build takes a SHARE lock on user_feed_items, which blocks feed writes for
-- its duration; on a large forum run it during a maintenance window.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_user_feed_items_item
    ON user_feed_items (item_type, item_id);

COMMIT;
