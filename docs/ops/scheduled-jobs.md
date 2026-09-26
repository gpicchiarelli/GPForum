# Scheduled Operational Jobs

GPForum does not sweep stale rows during HTTP or outbox dispatch. Expired
sessions, rate-limit windows, identity tokens, completed outbox rows, and
dead letters accumulate until an operator timer invokes the oneshot command:

```sh
script/gpforum-carton exec bin/gpforum-scheduled-jobs --once --limit 100
```

The runner also calls `Attachment::Store::cleanup_orphans` (policy on
`Attachment::Lifecycle`), rescans uploads the antivirus could not decide
(`attachment_scans`), puts files served on a format check alone through the
antivirus (`attachment_backfill`; both ADR 0108, see
`docs/ops/antivirus.md`), and
`PartitionLifecycle` plan/retention/restore evidence only. It never executes `CREATE TABLE ... PARTITION OF` and never
writes `partition_registry`.

`purge_dead_letters` deletes aged `dead_letters` rows. See
`docs/ops/dead-letters.md` before treating purge as a drain of the live
outbox queue.

The command prints one line: `ok`, then each job with its count, and for a job
that did not complete, its `_error`, `_errors` count or `_skipped` reason. It
exits 1 when any job failed, so a systemd timer marks the unit failed.

## Timers shipped in-tree

| Host | Unit | Cadence |
| --- | --- | --- |
| Linux systemd | `deploy/systemd/gpforum-scheduled-jobs.timer` + oneshot service | hourly |
| macOS launchd | `deploy/launchd/com.gpforum.scheduled-jobs.plist` | 3600s |

Enable Linux with:

```sh
systemctl enable --now gpforum-scheduled-jobs.timer
```

Do not enable the oneshot service as a long-running daemon. The outbox
dispatcher remains the only looping worker command.

## What still needs an operator crontab

- **FreeBSD** (and any host without systemd/launchd): install an hourly
  crontab for the `gpforum` user. No rc.d periodic sample is shipped.
- **Partition DDL**: apply `CREATE TABLE ... PARTITION OF` (and later
  detach/archive/drop) from the printed planned windows. The app versions
  policy and evidence only.
- **PostgreSQL maintenance** outside autovacuum (`VACUUM`, `ANALYZE`,
  restore drills) stays on the operator runbook.

Example FreeBSD/crontab line:

```cron
0 * * * * /opt/gpforum/script/gpforum-carton exec /opt/gpforum/bin/gpforum-scheduled-jobs --once --limit 100
```
