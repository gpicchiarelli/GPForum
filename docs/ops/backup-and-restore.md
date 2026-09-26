# Backup and Restore

ADR 0050 requires operators to run PostgreSQL with replication, WAL archiving
and point-in-time recovery. Until this page existed the repository stated that
requirement and shipped nothing to meet it: no sample configuration, no
procedure, and no way to find out whether a restore would work before needing
one.

There are two recovery stories here and they cover different failures.

| | Logical dump | Point-in-time recovery |
| --- | --- | --- |
| Recovers | schema and rows | the cluster at a chosen instant |
| Granularity | the moment of the dump | any instant covered by the archive |
| Typical RPO | as old as the last dump | seconds |
| Rehearsed by | `script/staging-drill` | `script/pitr-drill` |
| Good for | migration, a copy for staging, a bad deploy | deletion, corruption, disk loss |

A nightly dump alone means a bad afternoon costs a day of posts. PITR is what
the ADR asks for.

## What is not in either

**Attachments.** `FilesystemStorage` writes blobs under the attachment root
(`GPFORUM_ATTACHMENT_ROOT`, default `var/attachments`). Neither `pg_dump` nor
WAL archiving touches them, and the database keeps only the object keys — so a
restore without the blobs gives you a forum whose attachments all 404. Back the
attachment root up on its own schedule and restore it to the same instant.
`script/staging-drill-attachments` rehearses that half.

## Configuring the archive

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

## Restoring to an instant

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
6. Restore the attachment root to the same instant.
7. Run `bin/gpforum-migrate --plan`. It should report nothing pending: if it
   wants to apply migrations, the restore predates a deploy and the application
   will not match the schema.

Choose the target *before* the damage, not after it. If you do not know when
the damage happened, restore to a candidate instant, look, and repeat — which
is why step 1 says keep the original.

## Rehearsing it

```bash
script/pitr-drill
```

The drill builds its own throwaway cluster, so it touches nothing you run. It
applies the configuration above, takes a base backup, writes rows on either
side of a recovery target, restores to that target, and checks that the rows
written before it came back and the rows written after it did not.

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

Replication. ADR 0050 asks for that too, and nothing here sets up a standby.
An archive plus base backups is a recovery story, not a availability story:
recovering means downtime measured in however long the replay takes.

## Related

- `docs/ops/staging-drills.md` — the logical dump and restore drill
- `docs/ops/reload-and-restart.md` — stopping and starting the service
- `docs/adr/0050-infrastructure-distributed-systems.md` — the requirement
