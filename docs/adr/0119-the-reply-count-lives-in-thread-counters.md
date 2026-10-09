# ADR 0119: The Reply Count Lives in thread_counters, Moved There Behind a Trigger

## Status

Accepted. Amends ADR 0091: a reply now adds to `thread_counters` directly,
where ADR 0091 required an anti-hot-row `thread_counter_shards` delta and
forbade touching the canonical counter on the hot write path. Closes the
`thread_counter_shards` follow-up of ADR 0111. ADR 0099's evidence list
names the table as written by migration 004, which stays true until the
contract step below.

## Context

- `thread_counter_shards` (migration 004) was meant to spread reply-count
  writes over shards. Every write went to shard 0: every reply, copy
  completion, delete (-1) and restore (+1) of a post updated one row per
  thread. That is the same hot row a counter row is, so the shards spread
  nothing.
- Since 571cdf0 the category list and the home page show each thread's
  replies, as `thread_counters.reply_count` plus the sum of its shard deltas.
  That cost two primary key lookups per listed row, to read one number.
- A delete or a restore of the opening post moved the count too. A thread
  whose opening post was deleted showed one reply fewer than it had, and one
  with no replies showed -1. The seed and `ThreadComposer` both define the
  count as the replies after the opening post.
- `thread_counters.reply_count` has `CHECK (reply_count >= 0)`. Writing the
  deltas there as they were would have failed that opening-post delete.
- A deploy runs `bin/gpforum-migrate --apply` and then restarts Hypnotoad
  (`docs/DEPLOYMENT.md`, `docs/ops/reload-and-restart.md`). The previous
  release serves while the migration runs, and its workers finish their
  requests after the restart begins, so for a while both releases write.
  The previous release's code is fixed: it writes shard deltas and adds them
  up, whatever the schema does.
- The application connects with `lock_timeout` 3 s. A migration that holds a
  lock its writes need for longer fails those requests.

## Decision

### 1. The count is one column, written by the store

- `PostStore` adds to the thread's `thread_counters.reply_count`: a reply
  adds 1, a delete of a reply takes 1 off, a restore adds it back. The
  opening post (position 1) is not a reply, so its delete and restore leave
  the count.
- The update is `GREATEST(reply_count + ?, 0)`: a count that drifted does
  not fail the write it is a projection of. A thread without a counter row
  gets one; an insert that loses that race (`thread_counters_pkey`) adds to
  the row that won.
- The counter row is taken last, after the thread row and the post row, as
  the shard row was. The lock order of ADR 0111 is unchanged and no write
  waits where it did not: a reply already holds its thread row
  `FOR NO KEY UPDATE`, so replies never queue on the counter for each other;
  a delete or a restore holds the thread row `FOR KEY SHARE`, which does not
  conflict with a reply, so it queues with them on the counter row as it did
  on shard 0. `t/integration/postgres-concurrency.t` holds a delete
  uncommitted, shows a reply waiting on exactly that row, and both counted
  once it commits; the reply races there pass unchanged.
- `ThreadReader` reads the column, 0 for a thread without a row: one lookup
  per listed thread.
- `PostComposer` no longer builds a `counter_shard` part, and the Result
  class `ThreadCounterShard` and `Thread`'s `counter_shards` relationship are
  gone, with the test doubles' shard support.

### 2. Migration 051 moves the count while both releases run (expand)

The table stays for now, with a `BEFORE INSERT OR UPDATE` trigger,
`thread_counter_shards_into_counters()`: whatever a write would leave in a
shard row is added to the thread's counter (created if missing, floored at
zero) and the row stays at zero. The previous release then reads the counter
plus zero and this one reads the counter, so both show the same count
throughout, and none of its writes fails.

The previous release still moves the count for an opening post. The trigger
does not add such a write: it counts the thread again from its posts, the
replies that are not deleted. That release updates the post row, then writes
the delta, in one transaction and outside any savepoint (seen in its
DBIx::Class trace), so the opening post's row then carries the transaction's
own id as `xmin`, and `xmin = pg_current_xact_id()::xid` says so. Counting
again, not leaving the write out, matters for an opening post that release
deleted before the trigger and restores after it: the delete's -1 is in the
counter, or about to be folded there, and step 3 below does not see the
thread, whose opening post is no longer deleted. Leaving the restore out
kept that -1 for good (a test showed the thread one reply short). The
trigger locks the counter row first, and each statement of the function
reads what committed before it, so the count holds every reply whose +1 the
row already has, and a reply still in flight adds its +1 after. A write the
`xmin` test took for an opening post's by mistake would only be counted
exactly.

The migration runs in three steps, each safe to run again:

1. The trigger, in its own transaction with `lock_timeout` 1 s. `CREATE
   TRIGGER` takes `SHARE ROW EXCLUSIVE`, which waits for the replies in
   flight and stops later ones; one second keeps a reply queued behind it
   under the application's three.
2. The deltas already there: every non-zero row is touched, which runs the
   trigger, so each delta moves under the row lock a concurrent writer takes
   too, once. Sixteen transactions, one per last hex digit of the thread id,
   so no row lock is held long. The last digit, not the first: thread ids
   are UUIDv7 (`GPForum::Infrastructure::Id`), whose first digit is the
   timestamp's and is 0 for every thread until 2527, so a split on it folds
   everything in one transaction.
3. The threads whose opening post is deleted, which the shards had counted,
   are recounted from `posts` (replies, position above 1, not deleted).
   Which threads those are is read into a temporary table first, before any
   row is locked, so the scan of `posts` holds no lock; an opening post
   deleted or restored after that read is one the trigger has counted again
   already. Then, in
   sixteen transactions split as the fold is, each thread row is locked
   `FOR UPDATE`, which waits out its replies, deletes and restores in
   flight, so the number each statement reads is the number it sets.
   Setting a number, not adding one, makes it idempotent.

Measured on PostgreSQL 18 with 300,000 threads with UUIDv7 ids and
3,000,000 posts, 30,000 threads without a counter row, 6,000 with a deleted
opening post and 3,000 with a negative delta, while a probe sent the
previous release's shard update for random threads with the application's
3 s `lock_timeout`: each fold transaction took 0.42-0.70 s, reading the
deleted openings 0.31 s and each recount transaction under 0.07 s, 9.1 s in
all; the probe's 10,726 writes waited 0.66 s at most and none failed, and
every counter matched the count expected from the previous release's
reader plus the probe's writes. The same run with the fold split on the
first digit put all 300,000 rows in one transaction of 8.6 s, and two of
the probe's writes timed out after 3 s.

Alternatives, with the evidence that ruled them out:

- **Drop the table in this release.** The previous release's next reply,
  delete or restore inserts or updates a shard row and fails, until its
  workers are gone.
- **Fold once and keep the table, with no trigger.** The previous release's
  deltas after the fold sit in the shards, which this release does not
  read: its pages show those threads short until a second fold, and the two
  releases' pages disagree meanwhile.
- **Fold everything in one transaction under a table lock.** On the same
  300,000 threads that held `SHARE ROW EXCLUSIVE` for 4.5 s, over the
  application's 3 s `lock_timeout`, so the previous release's replies queued
  behind it would fail.

Evidence for the trigger:

- The previous release's own `PostStore` and `ThreadReader`, run against a
  database migrated through 051 at a06e19e: a reply that inserts a shard
  row, one that updates it, a delete and a restore of a reply, and a delete
  and a restore of the opening post. After each, the counter equalled the
  thread's live replies, the shard row was at zero, and that release's
  reader showed the counter.
- `t/integration/postgres-thread-counter-fold.t` replays 051 from the state
  that release leaves, with one of its writes uncommitted while 051 runs
  (the migration waits for it, then folds it), checks that every thread
  then counts what that release showed, and sends the statements that
  release sends. Each step of the migration and the `xmin` check fails a
  named assertion when removed. It also deletes an opening post before the
  trigger and restores it after, which a trigger that left the restore out
  failed, and races an opening-post delete against this release's reply
  holding the counter row, which a count taken before the row lock failed.

### 3. Deploy order and the contract step

1. **This release: 051 must be applied before its code starts.**
   `bin/gpforum-migrate --apply`, then the restart, as every deploy does;
   a deploy whose migration fails stops there, and the previous release
   keeps serving correctly on whatever steps of 051 committed. Starting
   this release's code first is not safe. A thread the application created
   has `reply_count` 0 in `thread_counters` until 051 runs (`ThreadComposer`
   writes 0 and every reply went to the shards), so this release's pages
   show no replies, and its delete of a reply is floored at zero and lost:
   once 051 folds the deltas, that thread counts one reply too many.
   Rolling the code back to the previous release after 051 is safe: the
   trigger keeps its writes in the counter.
2. **A later release (contract), once no process runs anything older than
   this one.** A migration drops the table:

   ```sql
   BEGIN;
   SET LOCAL lock_timeout = '1s';
   UPDATE thread_counter_shards SET reply_count_delta = reply_count_delta
   WHERE reply_count_delta <> 0;
   DROP TABLE thread_counter_shards;
   DROP FUNCTION thread_counter_shards_into_counters();
   COMMIT;
   ```

   It must not ship with 051: the runner applies every pending migration in
   one `--apply`, before the restart, so the previous release would lose its
   table while still serving. The `UPDATE` moves anything a disabled trigger
   let through; `DROP TABLE` takes the trigger with it. Dropping the table
   drops its foreign key, which takes `ACCESS EXCLUSIVE` on `threads`
   (checked on PostgreSQL 18): every page waits behind it while it waits,
   so the `lock_timeout` stays at a second and a failure is run again.

## Consequences

- The category list and the home page read one number per thread. A reply
  still writes one row for the count: now the row the pages read.
- A deleted opening post no longer takes a reply off its thread's count.
- `thread_counter_shards` and its trigger live until the contract step. A
  row the previous release inserted meanwhile stays, at zero.
  The performance seed's reset deletes threads but not their shard rows,
  so on a database the previous release wrote to it fails on the foreign key
  until then, as it always could.
- Residual: an opening-post delete or restore that the previous release ran
  inside a savepoint would be added as a delta by the trigger. None of its
  paths does.
- Residual: the fold moves a thread's shard rows one at a time, each floored
  at zero, so rows of one thread with deltas of both signs could fold to
  more than their sum. The previous release wrote shard 0 only.
- No reconciliation job: the floor keeps a drifted count from failing
  writes, not from being wrong.

## Alignment

- ADR 0091 (amended), ADR 0099, ADR 0111 (follow-up closed), ADR 0051
  (anti-hot-row counters stay a SHOULD where they spread writes).
- `lib/GPForum/Service/Forum/PostStore.pm`,
  `lib/GPForum/Service/Forum/PostComposer.pm`,
  `lib/GPForum/Service/Forum/ThreadReader.pm`,
  `lib/GPForum/Schema/Result/Thread.pm`.
- `migrations/051_fold_thread_counter_shards.sql`.
- `t/12-forum-post.t`, `t/integration/postgres-thread-counter-fold.t`,
  `t/integration/postgres-thread-reply-count.t`,
  `t/integration/postgres-concurrency.t`.
