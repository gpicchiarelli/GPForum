# Backup and Restore

A forum is two things to keep: its PostgreSQL database and its uploads. ADR
0050 asks for point-in-time recovery of the first; this page has the nightly
backup of both, the check that a backup can be restored, and the archive
that recovers the database to any instant.

| | `gpforum backup` | Point-in-time recovery |
| --- | --- | --- |
| Recovers | the database and the uploads | the database cluster |
| Granularity | the moment of the backup | any instant covered by the archive |
| Typical RPO | as old as the last backup | seconds |
| Checked by | `gpforum restore --check` | `script/pitr-drill` |
| Good for | a copy off the host, a bad deploy, a copy for staging | deletion, corruption, disk loss |

A nightly backup alone means a bad afternoon costs a day of posts; PITR is
what the ADR asks for. Run both: the backup is the copy you can carry off
the host and check in one command.

## The nightly backup

```console
$ sudo install -d -o gpforum -m 700 /var/backups/gpforum
$ sudo -u gpforum gpforum backup --to /var/backups/gpforum
✓ database gpforum: 4.2 MB, schema 051, PostgreSQL 18.6
✓ attachments: 312 files, 48.1 MB, from /opt/gpforum/var/attachments
✓ Backed up into /var/backups/gpforum/gpforum-20261009T031500Z
Next: check that it can be restored, with sudo -u gpforum gpforum restore --check /var/backups/gpforum/gpforum-20261009T031500Z
```

Run under `sudo -u`, the check it offers runs as the same account, which
alone can read the backup. Each run makes a new directory, named for the time in UTC and readable by
`gpforum` alone, holding:

| File | What it is |
| --- | --- |
| `database.dump` | the database `GPFORUM_DATABASE_DSN` names, as `pg_dump --format=custom` writes it |
| `attachments.tar` | the attachment root (`GPFORUM_ATTACHMENT_ROOT`), relative to it |
| `manifest.json` | when it was taken; the latest migration applied, PostgreSQL's and pg_dump's versions; what the attachment root held; each file's size and SHA-256 |

The manifest is written last, and a backup that fails half-way is removed:
a directory with a manifest is a whole backup. Run it as `gpforum`, who can
read the settings and the uploads. It reads the settings as every `gpforum`
command does, from the environment file; the password reaches pg_dump only
through its environment, and is written nowhere.

What it refuses, it says, with what to do instead: a directory inside the
code directory (an upgrade replaces it) or inside the attachment root (the
backup would copy itself); a directory it cannot make, with the `sudo
install -d` that makes it; a host without `pg_dump`. pg_dump refuses a
server newer than itself: install the client of the server's major
version, or name it with `GPFORUM_PG_DUMP`.

**What it does not hold: the settings.** The environment file holds the
secrets. Keep a copy of `/etc/gpforum/gpforum.env` where you keep secrets,
not beside the backups.

**Every night**, as `gpforum`'s crontab (`sudo crontab -u gpforum -e`):

```cron
15 3 * * * /opt/gpforum/bin/gpforum backup --to /var/backups/gpforum > /dev/null
30 3 * * * find /var/backups/gpforum -maxdepth 1 -name 'gpforum-*' -mtime +14 -exec rm -r {} +
```

Success prints to standard output and a failure to standard error, so cron
mails only a failure. The second line keeps two weeks. A backup on the
forum's own disk is lost with it: copy the directory off the host (`rsync
-a /var/backups/gpforum/ backup-host:gpforum/`).

The uploads are copied after the dump, as tar finds them: an upload made
meanwhile is a file in the archive nothing refers to; an attachment erased
meanwhile is referred to by the dump and missing from the archive. Run it
when the forum is quiet.

## Checking a backup

```console
$ sudo -u gpforum gpforum restore --check /var/backups/gpforum/gpforum-20261009T031500Z
✓ manifest: gpforum, taken 2026-10-09 03:15 UTC, schema 051
✓ database.dump: 4.2 MB, as the backup wrote it; pg_restore reads its 578 entries
✓ attachments.tar: 48.3 MB, as the backup wrote it; 312 files

The backup can be restored; nothing was restored.
Next: to restore it, follow the steps in docs/ops/backup-and-restore.md
```

It reads the manifest; compares each file's size and SHA-256 with it; has
`pg_restore --list` read the dump's table of contents and `tar` the archive,
and counts the archive's files against the manifest. It restores nothing,
needs no database, and runs on any host with `pg_restore` -- the one you
copied the backups to, too -- as an account that can read the backup
(`gpforum`, who made it). Run as an account that cannot read it, it says
so and gives the check as the backup's owner, rather than taking the
backup for lost. A file that changed, was cut short, is gone or is left
out of the manifest is said by name, and the command exits 1:

```console
✗ database.dump: its SHA-256 is not the one the backup wrote: it changed after the backup

This backup cannot be restored as it is.
Next: keep it as it is, and take another with gpforum backup
```

Given the directory of the backups rather than one of them, it offers the
newest. `--json` prints one object with a `status` and each finding, for a
monitor.

## Restoring a backup

A restore replaces the forum's database and uploads, so it is done by hand.
On Debian, with the settings of the template (database and role `gpforum`
on this host):

1. **Check it**: `sudo -u gpforum gpforum restore --check DIR`. Restore
   nothing that fails.
2. **Stop the forum**: `sudo systemctl stop gpforum gpforum-outbox`.
3. **Put the database back.** Keep the one you are replacing, renamed, until
   the restore is proven:

   ```sh
   sudo -u postgres psql -c 'ALTER DATABASE gpforum RENAME TO gpforum_before_restore'
   sudo -u postgres createdb --owner gpforum gpforum
   sudo -u gpforum pg_restore --no-owner --no-acl --host 127.0.0.1 --username gpforum \
     --dbname gpforum DIR/database.dump
   ```

   pg_restore asks for `GPFORUM_DATABASE_PASSWORD` unless `~/.pgpass` holds
   it; on macOS run `psql` and `createdb` as the account that installed
   PostgreSQL instead of `postgres`.
4. **Put the uploads back**, the same way:

   ```sh
   sudo mv /opt/gpforum/var/attachments /opt/gpforum/var/attachments.before-restore
   sudo install -d -o gpforum -g gpforum -m 750 /opt/gpforum/var/attachments
   sudo -u gpforum tar -xf DIR/attachments.tar -C /opt/gpforum/var/attachments
   ```

5. **Bring the schema to the code**: `sudo -u gpforum gpforum migrate`. A
   backup older than the code has migrations to apply; one newer than the
   code needs the release it was taken with (its manifest says the schema).
6. **Start the forum** and check it: `sudo systemctl start gpforum
   gpforum-outbox`, then `sudo -u gpforum gpforum doctor`.

When it is right, drop `gpforum_before_restore` and remove
`attachments.before-restore`. `gpforum staging-drill` rehearses a dump and
restore on throwaway databases.

## Point-in-time recovery

The archive below recovers the database alone. **The uploads are not in
it**: `FilesystemStorage` writes them under the attachment root, which
neither WAL archiving nor `pg_basebackup` touches, and the database keeps
only their keys -- a recovery without them is a forum whose attachments
all answer 404. Restore the attachment root from the nightly backup taken
closest to the instant (step 4 above). `script/staging-drill-attachments`
rehearses that half.

### Configuring the archive

On the primary:

```
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /srv/gpforum/wal/%f && cp %p /srv/gpforum/wal/%f'
max_wal_senders = 3
```

`archive_command` must return non-zero when it does not archive, or PostgreSQL
believes the segment is safe and recycles it. The `test ! -f` guard refuses to
overwrite an existing segment rather than silently replacing it. Archive to
storage that does not share a failure domain with the data directory: an
archive on the same disk protects against deletion, not against losing the
disk.

Take a base backup after enabling archiving, and again often enough that
replaying WAL from the last one is a tolerable wait:

```sh
pg_basebackup -h HOST -U gpforum -D /srv/gpforum/base/$(date -u +%Y%m%dT%H%M%SZ) -Fp -Xs
```

### Restoring to an instant

1. Stop the server. Keep the broken data directory rather than deleting it —
   it is the evidence, and a second restore attempt may need it.
2. Put the base backup in place as the data directory.
3. Append the recovery settings:

   ```
   restore_command = 'cp /srv/gpforum/wal/%f %p'
   recovery_target_time = '2026-09-24 11:27:58+02'
   recovery_target_action = 'promote'
   ```

4. `touch recovery.signal` in the data directory.
5. Start the server. It replays WAL to the target and promotes.
6. Restore the attachment root to the same instant, from the nightly
   backup taken closest to it.
7. Run `gpforum migrate --check` (`--json` for a script). It should exit
   0 with `pending=0`: if it lists pending migrations, the restore predates a
   deploy and the application will not match the schema. (`--plan` lists the
   files in `migrations/` without asking the database, so it cannot tell.)

Choose the target *before* the damage, not after it. If you do not know when
the damage happened, restore to a candidate instant, look, and repeat — which
is why step 1 says keep the original.

### Rehearsing it

```bash
script/pitr-drill
```

The drill builds its own throwaway cluster, so it touches nothing you run. It
applies the configuration above, takes a base backup, writes rows on either
side of a recovery target, restores to that target, and checks that the rows
written before it came back and the rows written after it did not. The last
recorded run is in
[`evidence/2026-10-01-pitr-drill/`](evidence/2026-10-01-pitr-drill/README.md)
(PostgreSQL 18.6, 108 s end to end).

Row counts alone would not catch the failure worth catching, which is a restore
that silently lands on the wrong instant. Verified on PostgreSQL 18: three rows
before the incident, two recovered.

It fails loudly in the case operators actually hit — an incomplete archive,
where the base backup is fine but the WAL needed to roll forward was never
archived, so recovery cannot reach the target and refuses to promote:

```
pitr-drill status=fail reason=recovery-did-not-start
```

Rehearse after any change to `archive_command`, to the storage the archive
writes to, or to the PostgreSQL major version.

## What this does not give you

Availability. An archive plus base backups is a recovery story: recovering
means downtime measured in however long the replay takes. The streaming
standby that ADR 0050 also asks for, and the failover to it, are in
[standby-and-failover.md](standby-and-failover.md) (ADR 0112).

## Related

- `docs/ops/staging-drills.md` — the dump and restore drill on throwaway
  databases
- `docs/ops/standby-and-failover.md` — the streaming standby and failover
- `docs/ops/reload-and-restart.md` — stopping and starting the service
- `docs/adr/0050-infrastructure-distributed-systems.md` — the requirement
