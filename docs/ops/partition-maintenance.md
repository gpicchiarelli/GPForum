# Partition Maintenance

`audit_log`, `event_log` and `notifications` are range-partitioned by month.
An insert whose timestamp falls outside every month partition lands in the
DEFAULT partition, and once rows are sitting there PostgreSQL will refuse to
attach a partition covering that range. So the months are created ahead of
time, from the date, and recorded in `partition_registry` (ADR 0113):

- `bin/gpforum-migrate --apply` creates the current month and the two after
  it, where they are missing, right after the migrations. A fresh install has
  its month before its first write, and every deploy refreshes the window.
- A daily timer runs `bin/gpforum-partition-maintenance --apply`, which does
  the same, so the window moves on between deploys.

No migration names a month any more. Migration 038 named September to
December 2026; migration 049 drops those of them that ended before the month
it runs in and hold no row, and leaves any that hold rows where they are.

```sh
gpforum partitions
```

The plan is the default and writes nothing: `9 monthly partitions to create,
up to 2026-12.` and `Next: gpforum partitions --apply`, or `✓ The monthly
partitions reach 2026-12.` when nothing is missing. `--apply` creates them.
A database the migrations have not reached yet is refused, exit 1, with
`gpforum migrate` to run first. `bin/gpforum-partition-maintenance`, which
the timer runs, prints the DDL and one `key=value` line for its journal.

```
Usage: bin/gpforum-partition-maintenance [--plan|--apply] [--lookahead N] [--json]

  --plan       report the DDL without executing it (default)
  --apply      create each missing month and ATTACH it, and upsert the registry
  --lookahead  months to keep ahead, including the current month (default 3)
  --json       one JSON object on stdout instead of lines
  --help       show this help
```

Exit status is 0 on success, and when another run holds the maintenance lock
(`skipped=1`); 1 when a partition cannot be created or the database cannot
be reached; 2 for a usage error.

`--json` prints the same result as one object, for a script or an alert:

```json
{"command":"gpforum-partition-maintenance","mode":"plan","status":"ok",
 "skipped":0,"lookahead_months":3,"created":[],"existing":[],"planned":[...],
 "conflicts":[],"errors":[]}
```

`status` is `ok` or `fail`, as the exit code. Each list holds one object per
partition with `table_name`, `partition_name`, `range_start`, `range_end` and
`default_partition`, plus `create_sql` when the DDL was planned or run,
`conflicting_rows`, `message` and `remediation` (a list of statements) for a
conflict, and `error` for an error. When the run itself fails -- the database
cannot be reached -- the object has empty lists, `status` `fail` and the
reason in `error`, which standard error repeats: for a database that refuses
the connection, `partition lifecycle: cannot connect to the database:` and
what DBI said, a `password=` in the DSN shown as `[redacted]`. For example,
to alert on conflicts:

```sh
gpforum partitions --plan --json | jq -e '.conflicts == []'
```

## What a run does to traffic

Each missing month is one transaction, under a half-second `lock_timeout`:

```sql
BEGIN;
CREATE TABLE notifications_2026_11 (LIKE notifications
    INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE
    INCLUDING COMMENTS INCLUDING COMPRESSION INCLUDING GENERATED);
ALTER TABLE notifications ATTACH PARTITION notifications_2026_11
    FOR VALUES FROM (TIMESTAMPTZ '2026-11-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-12-01 00:00:00+00');
INSERT INTO partition_registry ...;
COMMIT;
```

The locks it holds until `COMMIT`, measured on PostgreSQL 18
(`t/integration/postgres-partition-maintenance.t` prints them):

| Relation | Lock | What waits for it |
| --- | --- | --- |
| the parent (`notifications`) | `SHARE UPDATE EXCLUSIVE` | nothing that reads or writes; only other DDL and `VACUUM` |
| the new month | `ACCESS EXCLUSIVE` | nothing: no one can see it yet |
| the DEFAULT partition | `ACCESS EXCLUSIVE`, and PostgreSQL scans all of it for rows of the new month | every read the planner cannot prune to one month, so opens DEFAULT too, and every write that starts with such a read (below) |
| `users` (`notifications` only) | `SHARE ROW EXCLUSIVE`, cloning the foreign key | writes to `users` |

`CREATE TABLE ... PARTITION OF`, which earlier versions ran, took `ACCESS
EXCLUSIVE` on the parent instead: it queued behind every open transaction on
the table and stopped every read and write queued behind it.

The DEFAULT partition's lock is the one that still matters. A read is
pruned at plan time only when it filters `created_at` by constants; a lookup
by `event_id` or `idempotency_key`, the audit chain tip (`ORDER BY
created_at DESC LIMIT 1`), and a filter on `now()` all open every partition,
DEFAULT included. The application begins every event write with the first
(`EventRecorder` looks the event up by id) and every audit write with the
second, so during an `event_log` or `audit_log` attach those writes wait
too. A plain `INSERT` routed to its month does not. The integration test
shows both: `EventRecorder->record_event` waits for an open attach, a bare
insert into the current month does not.

They wait for as long as the attach waits for, and then holds, DEFAULT's
lock:

- **Waiting for it.** The attach queues behind any open transaction that has
  read DEFAULT, and everything that opens DEFAULT queues behind the attach.
  That is why `lock_timeout` is half a second: past it the month is rolled
  back, table and registry row together, and tried again after a one-second
  pause in which the queue drains, five tries in all. A month still locked
  out then is reported under `errors` and left to the next run. The window
  starts two months ahead of need, so a failed run costs nothing but its log
  line.
- **Holding it.** The attach scans the whole of DEFAULT while it holds the
  lock. An empty DEFAULT scans in a millisecond; a DEFAULT holding history
  takes as long as reading that history, on every attach of every table,
  and is capped only by
  `statement_timeout` (the configured one, 15 seconds by default, under
  migrate as under the timer). Rows written before migration 038 live in
  DEFAULT: moving them into range partitions with the remediation below, in
  a maintenance window, keeps every later attach short.

So each stall is at most half a second plus the DEFAULT scan, a few times a
month per table; it is not nothing, and it is not a window.

A run first takes the advisory lock `4021970002` (the migration runner holds
`4021970001`) with `pg_try_advisory_lock`. Two nodes' timers, or a timer and
a deploy's migrate, can therefore overlap: the timer run that does not get
it prints `skipped=1` and exits 0, because the run that has it is doing the
same work. `bin/gpforum-migrate --apply` waits up to a minute for the lock
instead, so the application a deploy starts next finds its month in place;
only past that does it skip.

The role that runs it must own the partitioned tables: `ATTACH PARTITION`
and `CREATE TABLE` need it. That is the role the migrations run as. If the
application connects as another, give the timer that role's DSN.

## When it refuses

A run fails with `default_partition_overlap` when rows already in the DEFAULT
partition fall inside the range of a partition it wants to create -- found
by its own probe first, or by PostgreSQL refusing the `ATTACH`. The report
names the default partition, counts the blocking rows and prints the
remediation. This is the case the window exists to prevent: if nothing has
run for longer than `--lookahead` months, rows have already landed in DEFAULT
and the fix is manual.

The remediation detaches the DEFAULT partition, creates the month, moves the
overlapping rows and reattaches. It takes `ACCESS EXCLUSIVE` locks on the
parent and holds them while the rows move: run it in a maintenance window,
never pasted into a live system.

`bin/gpforum-migrate --apply` reports the same refusal after its migrations
have committed: it prints each partition and this page on standard error and
exits 1, with the migrations applied (`--json`: `status` `fail`, `applied`
and `partitions` both present). The deploy should stop there until the
overlap is cleared, or go on knowingly with `--no-partitions`.

## Alerting

`/health/ready` carries a `partition_horizon` check. It reads PostgreSQL's catalog
for the upper bound of each table's last range partition, and whether any
DEFAULT partition holds rows, and reports:

- `degraded` when any of the three tables has partitions for less than 45
  days ahead. With a daily run and the default `--lookahead 3` the horizon is
  never under two months, so this means the timer has not run for weeks:
  check `systemctl list-timers gpforum-partition-maintenance.timer` and the
  unit's journal.
- `degraded` when a DEFAULT partition holds rows: writes have already passed
  the horizon, and the fix is the remediation above, in a window.

It is degraded, never failed: writes still land, and taking the node out of
service would not create a partition. Point the readiness alerting at
`degraded` on this check. The report names each table, its horizon and the
days left; it goes only to a request carrying the metrics token, and an
anonymous probe sees the overall status alone
([DEPLOYMENT.md](../DEPLOYMENT.md#health-endpoints)).

## Scheduling

| Host | Unit | Cadence |
| --- | --- | --- |
| Linux systemd | `deploy/systemd/gpforum-partition-maintenance.timer` + oneshot service | daily, `Persistent=true`, up to an hour's random delay |
| macOS launchd | `deploy/launchd/com.gpforum.partition-maintenance.plist` | 86400s |
| FreeBSD | `deploy/freebsd/gpforum_jobs`, the crontab below | daily |

```sh
systemctl enable --now gpforum-partition-maintenance.timer
```

On FreeBSD the daily run is a line of `deploy/freebsd/gpforum_jobs`, the
crontab cron reads from `/usr/local/etc/cron.d/`, which `gpforum service
print rc` writes for the host with the rc scripts (choose a different
minute on each node). `bin/gpforum` reads the service's environment file
itself and finds the Perl the checkout installed; the crontab's own `PATH`
names `/usr/local/bin`, where the perl5 package puts `perl`:

```cron
PATH=/usr/local/bin:/usr/bin:/bin
17 3 * * * gpforum /usr/local/www/gpforum/bin/gpforum partitions --apply
```

It is idempotent: a partition that already exists is reported as existing
and its registry row synced. `bin/gpforum-scheduled-jobs` reports partition
plan, retention and restore **evidence** only -- it never creates a
partition, so it is not a substitute.

## Retention

Nothing detaches or drops a month that holds rows. Removing audit and event
history is the owner's decision, made against the retention policy, and ADR
0113 leaves automating it open. Until then the scheduled jobs' evidence
lists the months past retention, and an operator detaches them by hand
(`ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY`, outside a transaction
block), archives and drops them.

## Related

- `docs/adr/0113-rolling-monthly-partitions.md` -- the decision
- `docs/architecture/partition-lifecycle.md` -- the boundary
- `docs/ops/scheduled-jobs.md` -- the oneshot runner and its timers
- `migrations/038_monthly_log_partitions.sql`,
  `migrations/049_rolling_partitions.sql` -- the partition layout
