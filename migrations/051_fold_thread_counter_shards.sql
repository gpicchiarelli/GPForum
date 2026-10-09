-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- A thread's reply count moves into thread_counters alone (ADR 0119).
-- Until now every reply, and every delete and restore of a post, added a
-- delta to the thread's shard 0 in thread_counter_shards, and the category
-- list and the home page added those deltas to thread_counters.reply_count.
-- From this release the application adds to thread_counters directly and
-- reads nothing else, and the opening post is not a reply: deleting or
-- restoring it leaves the count alone.
--
-- A deploy applies this, then restarts Hypnotoad, so the previous release
-- keeps serving while it runs and until its workers are gone. That code
-- still writes deltas and still adds them up. So this migration keeps the
-- table and gives it a trigger: whatever a write would leave in a shard row
-- goes into the thread's counter instead, and the row stays at zero. The
-- previous release then reads the counter plus zero, this one reads the
-- counter, and both read the same number throughout. A later release drops
-- the table, once nothing older than this one runs (ADR 0119 has the SQL).
--
-- The previous release counted a delete or a restore of the opening post.
-- The trigger does not add such a write: it counts the thread again from
-- its posts, the replies that are not deleted. The previous release updates
-- the post row before it writes the delta, in the same transaction, so the
-- opening post's row then carries that transaction's id (xmin). Counting
-- again, not leaving the write out, also settles the -1 of an opening post
-- deleted before the trigger and restored after it, which step 3 would not
-- see. The counter row is locked first, and each statement of a function
-- reads what committed before it, so the count includes every reply whose
-- +1 the row already holds, and one still in flight adds its +1 after.
--
-- Three steps, each safe to run again, since a failure part-way leaves the
-- earlier ones committed and the migration unrecorded.
--
-- 1. The trigger. CREATE TRIGGER takes SHARE ROW EXCLUSIVE on the table,
--    which waits for the replies in flight and stops the ones after it, so
--    lock_timeout is a second: below the application's three, so a reply
--    queued behind the wait is not the one to time out.
-- 2. The deltas already there. Touching a row runs the trigger, which moves
--    its delta, under the row lock a concurrent writer takes too: each delta
--    moves once, whichever comes first. Sixteen transactions, one for each
--    last hex digit of the thread id, so no row lock is held long. The last
--    digit, not the first: an id is a UUIDv7 (GPForum::Infrastructure::Id),
--    whose first digit is its timestamp's, 0 for every thread until 2527,
--    while its last is random. On PostgreSQL 18 with 300,000 threads each
--    took 0.4 to 0.7 s; split on the first digit, one took 8.6 s, and
--    replies queued behind its locks hit the application's lock_timeout.
-- 3. The threads whose opening post is deleted. The previous release took
--    one off for it, so their counter is recounted from the posts: the
--    replies that are not deleted. Which threads those are is read first,
--    into a temporary table, before any row is locked, so the scan of the
--    posts does not hold a lock; an opening post deleted or restored after
--    that read is one the trigger has counted again already. Then, in
--    sixteen transactions like the fold's, each thread row is locked FOR
--    UPDATE, which waits for the replies, deletes and restores in flight
--    and stops new ones, so the count each statement reads is the one it
--    sets. It is a number, not a difference, so running it again changes
--    nothing.

CREATE OR REPLACE FUNCTION thread_counter_shards_into_counters()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    written bigint := NEW.reply_count_delta;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        written := written - OLD.reply_count_delta;
    END IF;

    IF written <> 0 AND EXISTS (
        SELECT 1
        FROM posts AS opening
        WHERE opening.thread_id = NEW.thread_id
          AND opening.position = 1
          AND opening.xmin = pg_current_xact_id()::xid
    ) THEN
        INSERT INTO thread_counters (thread_id, reply_count)
        VALUES (NEW.thread_id, 0)
        ON CONFLICT (thread_id) DO NOTHING;
        PERFORM 1
        FROM thread_counters
        WHERE thread_id = NEW.thread_id
        FOR UPDATE;
        UPDATE thread_counters
        SET reply_count = (
            SELECT count(*)
            FROM posts AS reply
            WHERE reply.thread_id = NEW.thread_id
              AND reply.position > 1
              AND reply.deleted_at IS NULL
        )
        WHERE thread_id = NEW.thread_id;
    ELSIF NEW.reply_count_delta <> 0 THEN
        INSERT INTO thread_counters AS counter (thread_id, reply_count)
        VALUES (NEW.thread_id, GREATEST(NEW.reply_count_delta, 0))
        ON CONFLICT (thread_id) DO UPDATE
            SET reply_count =
                GREATEST(counter.reply_count + NEW.reply_count_delta, 0);
    END IF;

    NEW.reply_count_delta := 0;
    RETURN NEW;
END
$$;

BEGIN;
SET LOCAL lock_timeout = '1s';
CREATE OR REPLACE TRIGGER thread_counter_shards_into_counters
    BEFORE INSERT OR UPDATE ON thread_counter_shards
    FOR EACH ROW EXECUTE FUNCTION thread_counter_shards_into_counters();
COMMIT;

CREATE OR REPLACE FUNCTION pg_temp.gpforum_fold_shards(digit text)
RETURNS void
LANGUAGE sql AS $$
    UPDATE thread_counter_shards
    SET reply_count_delta = reply_count_delta
    WHERE reply_count_delta <> 0
      AND right(thread_id::text, 1) = digit;
$$;

BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('0'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('1'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('2'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('3'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('4'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('5'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('6'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('7'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('8'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('9'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('a'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('b'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('c'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('d'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('e'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_fold_shards('f'); COMMIT;

BEGIN;
SET LOCAL client_min_messages = 'warning';
DROP TABLE IF EXISTS pg_temp.gpforum_deleted_openings;
CREATE TEMPORARY TABLE gpforum_deleted_openings AS
SELECT opening.thread_id
FROM posts AS opening
WHERE opening.position = 1
  AND opening.deleted_at IS NOT NULL;
COMMIT;

CREATE OR REPLACE FUNCTION pg_temp.gpforum_recount_without_opening(digit text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    deleted record;
BEGIN
    FOR deleted IN
        SELECT opening.thread_id
        FROM pg_temp.gpforum_deleted_openings AS opening
        WHERE right(opening.thread_id::text, 1) = digit
        ORDER BY opening.thread_id
    LOOP
        PERFORM 1 FROM threads WHERE thread_id = deleted.thread_id FOR UPDATE;
        INSERT INTO thread_counters AS counter (thread_id, reply_count)
        SELECT deleted.thread_id, count(*)
        FROM posts AS reply
        WHERE reply.thread_id = deleted.thread_id
          AND reply.position > 1
          AND reply.deleted_at IS NULL
        ON CONFLICT (thread_id) DO UPDATE
            SET reply_count = EXCLUDED.reply_count;
    END LOOP;
END
$$;

BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('0'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('1'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('2'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('3'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('4'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('5'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('6'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('7'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('8'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('9'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('a'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('b'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('c'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('d'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('e'); COMMIT;
BEGIN; SET LOCAL lock_timeout = '1s'; SELECT pg_temp.gpforum_recount_without_opening('f'); COMMIT;

DROP FUNCTION pg_temp.gpforum_recount_without_opening(text);
DROP TABLE pg_temp.gpforum_deleted_openings;
DROP FUNCTION pg_temp.gpforum_fold_shards(text);
