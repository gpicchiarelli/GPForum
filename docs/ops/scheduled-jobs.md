# Scheduled Operational Jobs

GPForum does not sweep stale rows during HTTP or outbox dispatch. Expired
sessions, rate-limit windows, identity tokens, completed outbox rows, and
dead letters accumulate until an operator timer invokes the oneshot command:

```sh
script/gpforum-carton exec bin/gpforum-scheduled-jobs --once --limit 100
```

The runner also purges orphan attachments (`attachments`, below), rescans
uploads the antivirus could not decide
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
exits 1 when any job failed, so a systemd timer marks the unit failed, and 2
on misuse (an unknown option or job name; this used to die with 255).

`--json` prints the same summary as one JSON object instead:

```json
{"command":"gpforum-scheduled-jobs","status":"ok",
 "jobs":[{"name":"sessions","count":2,"ok":1}, ...]}
```

`status` is `ok` or `fail`, as the exit code. Each job, in name order, has its
`name` and the `count` the line prints, `ok` when the job reports one, and
when there is one its `skipped` reason, its `error`, and `errors`, the number
of items that failed. A run that fails -- the database gone -- exits 1 with
`status` `fail`, `jobs` empty and the reason in `error`. Empty means not
reported, not none run: the jobs before the one that failed did their work,
and the next run carries on.

## Orphan attachments

An upload writes its bytes, then its intent row, and moves the row to
`uploaded` within the same request. A request that dies in between leaves
an intent nobody links, and its file: an orphan. The `attachments` job
(`Attachment::Store::cleanup_orphans`, policy on `Attachment::Lifecycle`)
purges them:

- **What it takes**: rows still in the `intent` state, with no link, created
  at least a day ago, oldest first, up to `--limit`. The limit counts
  orphans only; linked intents are not fetched and do not use it.
- **Minimum age**: one day (86400 seconds, `Attachment::Lifecycle`'s
  `orphan_min_age`). A younger intent may be an upload still in flight, and
  removing its file would break it. The job always uses the day: it is a
  constant, not a setting. A caller of the store may pass its own `min_age`,
  a whole number of seconds above zero; anything else is taken as the day.
- **What it removes**: through the attachment storage under
  `attachment_root`, which the command gives the job's store, the stored
  object of each variant and then the original's; then it soft-deletes the
  row and records `attachment.deleted` in the owner's name, as
  `orphan cleanup`. The variant rows stay with the deleted attachment. The
  job must see the application's `attachment_root`: the same
  `GPFORUM_ATTACHMENT_ROOT`, and for a relative root the same working
  directory, as the shipped units give both. A file it does not find there
  it takes as already removed, and deletes the row all the same.
- **Order and repeats**: each orphan is purged in a transaction of its own,
  under its row's lock, and only if it is still an intent without links once
  the lock is held. Two runs at once purge an orphan once, each counting only
  the rows it deleted, and an attachment linked while the purge waited keeps
  its file. The files go before the row: a deleted row is never selected
  again, so files left by a failure after the delete would stay for good,
  while a row left by a failure after the removal is purged by the next run,
  whose removals find nothing and succeed.
- **Failures**: an orphan whose file the storage will not remove, or whose
  lock is not had within the database lock timeout
  (`GPFORUM_DATABASE_LOCK_TIMEOUT_MS`), stays where it is for the next run,
  and the job goes on to the others. The line shows `ok=0` and
  `attachments_errors=N`, and the command exits 1. A store without the
  storage -- one built outside the command -- purges nothing and says
  `attachments_skipped="no attachment storage"`.
- **What it cannot see**: a request that dies after writing the bytes and
  before writing the row leaves a file no row names. This job works from the
  rows, and leaves such a file in storage.

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
