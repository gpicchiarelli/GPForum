# Partition Maintenance

`audit_log`, `event_log` and `notifications` are range-partitioned by month.
Nothing creates next month's partitions on the write path: an insert whose
timestamp falls outside every existing partition lands in the DEFAULT
partition, and once rows are sitting there PostgreSQL will refuse to attach a
partition covering that range. The command creates the partitions ahead of
time and records them in `partition_registry`.

```sh
script/gpforum-carton exec bin/gpforum-partition-maintenance --plan
```

`--plan` is the default and writes nothing: it prints the DDL it would run.
`--apply` executes it.

```
Usage: bin/gpforum-partition-maintenance [--plan|--apply] [--lookahead N]

  --plan       report the DDL without executing it (default)
  --apply      execute CREATE TABLE ... PARTITION OF and upsert the registry
  --lookahead  months to keep ahead, including the current month (default 3)
  --help       show this help
```

Exit status is 0 on success, 1 when a partition cannot be created, 2 for a
usage error.

## Run it in a maintenance window

`CREATE TABLE ... PARTITION OF` takes an `ACCESS EXCLUSIVE` lock on the parent
table for the duration of the statement. On `audit_log` that blocks every
auditable write — thread creation, moderation actions, privacy requests —
because `Infrastructure::EventRecorder` reads the hash-chain tip on each one.
The statements are short, but schedule them like any other DDL.

The remediation procedure the command prints when it finds a conflict takes
`ACCESS EXCLUSIVE` locks too, and for longer: it detaches the DEFAULT
partition, moves the overlapping rows and reattaches. Do not paste it into a
live system outside a window.

## When it refuses

A run fails with `default_partition_overlap` when rows already in the DEFAULT
partition fall inside the range of a partition it wants to create. The report
names the default partition, counts the blocking rows and prints the
remediation. This is the case the lookahead exists to prevent: if the command
has not run for longer than `--lookahead` months, rows have already landed in
DEFAULT and the fix is manual.

## Alerting

`/readyz` carries a `partition_horizon` check. It reads PostgreSQL's catalog
for the upper bound of each table's last range partition, and whether any
DEFAULT partition holds rows, and reports:

- `degraded` when any of the three tables has partitions for less than 45
  days ahead -- with a monthly run and the default `--lookahead 3`, that means
  a run was missed. Run `--apply` in the next window.
- `degraded` when a DEFAULT partition holds rows: writes have already passed
  the horizon, and the fix is the remediation above, in a window.

It is degraded, never failed: writes still land, and taking the node out of
service would not create a partition. Point the readiness alerting at
`degraded` on this check. The report names each table, its horizon and the
days left.

## Cadence

Run it monthly, or more often than `--lookahead` months in any case. It is
idempotent: a partition that already exists is reported as existing and the
registry is synced. `bin/gpforum-scheduled-jobs` reports partition plan,
retention and restore **evidence** only — it never creates a partition and
never writes `partition_registry`, so it is not a substitute.

## Related

- `docs/ops/scheduled-jobs.md` — the oneshot runner and its timers
- `migrations/038_monthly_log_partitions.sql` — the partition layout
