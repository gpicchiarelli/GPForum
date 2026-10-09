-- GPForum worker idempotency claims.
--
-- Worker::IdempotentJobRunner asked the store whether a key was done, ran the
-- side effect, then inserted the key. Between the question and the insert,
-- nothing held the key. Two workers handed the same event both saw "not done",
-- both ran the side effect, and the loser's primary-key conflict was swallowed
-- by EventIdempotencyStore::_accept_conflict and reported as success. The
-- mechanism named idempotency delivered the side effect twice and said it had
-- not. begin() and mark_failed() were bodies that returned their argument.
--
-- The row is now a claim taken BEFORE the side effect runs, so the primary key
-- is what provides mutual exclusion: the first inserter owns the event and
-- every other worker is told to skip. completed_at separates "claimed" from
-- "finished", which the single-timestamp row could not express.
--
-- Rows written before this migration were inserted only after their side
-- effect had already run, so they are complete by construction and are
-- backfilled as such. Without this backfill every previously handled event
-- would look like an abandoned claim and become eligible to run a second time.

BEGIN;

ALTER TABLE event_idempotency_keys
    ADD COLUMN IF NOT EXISTS completed_at timestamptz;

UPDATE event_idempotency_keys
    SET completed_at = created_at
    WHERE completed_at IS NULL;

-- A worker that dies between claiming and finishing leaves the row behind.
-- Reclaiming such a row needs to find it by age without scanning the finished
-- ones, which are the overwhelming majority and are never read this way.
CREATE INDEX IF NOT EXISTS idx_event_idempotency_keys_unclaimed
    ON event_idempotency_keys (created_at)
    WHERE completed_at IS NULL;

COMMIT;
