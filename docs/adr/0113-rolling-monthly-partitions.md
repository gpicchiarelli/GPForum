# ADR 0113: Rolling Monthly Partitions, Created Without a Maintenance Window

## Status

Accepted. Amends ADR 0012, whose "the application does not execute partition
DDL" now reads "no web request or worker executes partition DDL".

## Context

`audit_log`, `event_log` and `notifications` are `PARTITION BY RANGE
(created_at)` with a DEFAULT partition. Migration 038 created their monthly
partitions for September to December 2026 by name, and nothing created any
other month on its own: `bin/gpforum-partition-maintenance --apply` existed,
but only an operator ran it, ADR 0012 having kept partition DDL out of the
application, and the hourly scheduled jobs only reported evidence. Three
things followed.

- The window ran out. On 2026-10-03 the horizon was 2027-01-01, and
  `/health/ready`'s `partition_horizon` check would degrade by mid-November.
- An installation migrated after 2026 got four empty past months and no
  partition for the month it was in. Every row went to DEFAULT, after which
  PostgreSQL refuses to attach the month covering them, and the fix takes
  `ACCESS EXCLUSIVE` locks in a maintenance window.
- The command created a month with `CREATE TABLE ... PARTITION OF`, which
  takes `ACCESS EXCLUSIVE` on the parent. It queued behind every open
  transaction on the table and stopped every read and write queued behind
  it, which is why the runbook asked for a maintenance window.

The owner's observation was that the partitioning was not dynamic at all:
the migrations named months already gone or about to be. Migration 038
cannot be edited, because the runner compares the checksum of every applied
file.

## Decision

- **A month is created and attached, not created as a partition.** Each
  missing month is `CREATE TABLE ... (LIKE parent INCLUDING DEFAULTS
  INCLUDING CONSTRAINTS INCLUDING STORAGE INCLUDING COMMENTS INCLUDING
  COMPRESSION INCLUDING GENERATED)` then `ALTER TABLE parent ATTACH
  PARTITION ... FOR VALUES FROM ... TO ...`, in one transaction with its
  `partition_registry` row. Measured on PostgreSQL 18: the parent is held in
  `SHARE UPDATE EXCLUSIVE`, which no read or write conflicts with;
  `ACCESS EXCLUSIVE` falls on the new table and on the DEFAULT partition,
  which is scanned whole; `notifications` also holds `SHARE ROW EXCLUSIVE`
  on `users` while its foreign key is cloned. Indexes
  are not copied by `LIKE`: the attach builds each partitioned index on the
  new table and attaches it, so the result has the indexes, primary key,
  foreign key, checks and not-null constraints `PARTITION OF` would have
  given it, all inherited, none duplicated.
- **Lock waits are short and retried.** DEFAULT's `ACCESS EXCLUSIVE` still
  stops every read the planner cannot prune to one month, since such a read
  opens DEFAULT too: a lookup by `event_id` or `idempotency_key`, the audit
  chain tip, a filter on `now()`. The application begins every event write
  and every audit write with one, so those writes wait for an `event_log` or
  `audit_log` attach as `PARTITION OF` made them wait; a plain `INSERT`
  routed to its month does not. What bounds the stall is the attach's own
  wait: `lock_timeout` is half a second, and a month that times out is
  rolled back and tried again after a one-second pause, five tries in all,
  before it is reported and left to the next run. Holding the lock lasts as
  long as the scan of DEFAULT, capped by the configured `statement_timeout`.
- **Runs are serialised by an advisory lock.** A run takes the session-level
  `pg_try_advisory_lock(4021970002)`, next to the migration runner's
  `4021970001`. A timer run that cannot is reported as skipped, status ok,
  and does nothing: two nodes' timers and a deploy can overlap, and the one
  holding the lock is doing the work. `bin/gpforum-migrate --apply` waits up
  to a minute for the lock instead, so the application the deploy starts
  next finds its month there.
- **The window is computed.** `bin/gpforum-migrate --apply` ensures the
  current UTC month and the two after it once the migrations are in, so a
  fresh install has its month before its first write and every deploy
  refreshes the window. `--no-partitions` skips it. The step runs with the
  configured `statement_timeout` back in place, the migrations having lifted
  it. If the step finds a
  conflict or an error, the command exits 1 after the migrations committed,
  naming each partition and `docs/ops/partition-maintenance.md`: a window left
  short fills DEFAULT with rows that only a maintenance window removes, so
  the deploy should stop and say so rather than go on.
- **A daily timer keeps it ahead.**
  `deploy/systemd/gpforum-partition-maintenance.{service,timer}` (daily,
  `Persistent=true`, up to an hour's random delay, the scheduled jobs'
  hardening), `deploy/launchd/com.gpforum.partition-maintenance.plist`, and
  a documented crontab line on FreeBSD, where no periodic sample is shipped
  for the scheduled jobs either. Each runs
  `bin/gpforum-partition-maintenance --apply`.
- **Migration 049 clears what 038 left.** It names no month: every month
  partition of the three tables whose range ended before the current UTC
  month and that holds no row is dropped, with its registry row. A month
  holding rows is kept. On the owner's databases in October 2026 that drops
  the September partitions that stayed empty; on an install in 2027 it drops
  all twelve. It checks a partition for rows before locking anything, so a
  parent whose past months all hold rows is never locked; it does each
  parent in a transaction of its own, so it never holds one parent's
  `ACCESS EXCLUSIVE` while waiting for another and cannot deadlock with a
  transaction writing two of the tables; it checks again under the lock
  before dropping. It replays at another date when a session sets
  `gpforum.partition_cutoff`, which only its test does.
- **DDL stays out of the request path.** What ADR 0012 guarded against was
  schema mutation from the web application and its services' request
  handling, with the time and locks those do not have. That stands: the DDL
  runs from operator processes -- a deploy's migrate and a oneshot timer --
  never from a web request or a looping worker.

## Consequences

- Nothing has to remember to create a month. The horizon is two months
  ahead or more whenever the timer has run in the last month; the 45-day
  warning on `/health/ready` now means weeks of missed runs.
- Creating a month no longer needs a maintenance window, but it is not free.
  Unpruned reads, the event and audit writes that begin with one, and writes
  to `users` during a `notifications` attach wait for each attach: at most
  half a second while it waits for its locks, then as long as the scan of
  DEFAULT, a few times a month per table. With an empty DEFAULT that is
  milliseconds. Rows written before migration 038 sit in DEFAULT on existing
  installations and make every attach scan them; moving them into range
  partitions, once, in a maintenance window, is recommended.
- The maintenance role must own the partitioned tables. Where the
  application connects as a role that does not, the timer gets the migration
  role's DSN.
- `bin/gpforum-migrate --apply` can now fail after committing its
  migrations. The applied list is still printed (and kept in `--json`), and
  the message names what to do.
- The test templates are rebuilt once per UTC month, because migrating
  depends on the month it runs in; integration tests that needed a monthly
  partition use the current month's.
- **Open: retention.** Detaching and dropping months that hold rows is not
  automated. `DETACH PARTITION ... CONCURRENTLY` would do it without
  stopping traffic, but dropping audit and event history is the owner's
  decision against the retention policy; until it is taken, the scheduled
  jobs report the months past retention and an operator acts on them.

## Alignment

- ADR 0012 (amended), ADR 0111 (scaling directives).
- `lib/GPForum/Service/Operations/PartitionLifecycle.pm`,
  `lib/GPForum/Command/PartitionMaintenance.pm`,
  `lib/GPForum/Command/Migrate.pm`.
- `migrations/049_rolling_partitions.sql`.
- `deploy/systemd/gpforum-partition-maintenance.service`,
  `deploy/systemd/gpforum-partition-maintenance.timer`,
  `deploy/launchd/com.gpforum.partition-maintenance.plist`.
- `docs/ops/partition-maintenance.md`,
  `docs/architecture/partition-lifecycle.md`, `docs/DEPLOYMENT.md`.
- `t/99-partition-lifecycle.t`, `t/173-partition-maintenance.t`,
  `t/10-migrate-command.t`, `t/integration/postgres-partition-maintenance.t`,
  `t/integration/postgres-partition-horizon.t`.
