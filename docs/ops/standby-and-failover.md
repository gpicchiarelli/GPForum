# Standby and Failover

A streaming standby keeps a second copy of the database seconds behind the
primary, and takes over when the primary is lost. ADR 0112 records the
decisions; this page is the procedure. Point-in-time recovery
([backup-and-restore.md](backup-and-restore.md)) is still needed: a standby
copies a mistake as faithfully as a post.

| | Point-in-time recovery | Streaming standby |
| --- | --- | --- |
| Recovers from | deletion, corruption, disk loss | losing the primary host |
| Downtime | the replay of the archive | the promotion: well under a second in the drill |
| Data lost | none up to the target | what had not reached the standby (milliseconds) |
| Rehearsed by | `script/pitr-drill` | `script/standby-drill` |

## Rehearse it first

```sh
make standby-drill      # script/standby-drill
```

The drill builds a primary and a standby of its own, so it touches nothing you
run. It clones the standby through a replication slot, checks that a write on
the primary reaches it and that it refuses writes, connects with a multi-host
DSN, loses the primary, promotes the standby, and checks that a process that
was connected before the loss -- the application's own `GPForum::Schema` --
reconnects to the new primary and writes to it.

```text
standby-drill status=pass caught_up_ms=54 promoted_ms=166
```

## Set up the standby

On the primary, in `postgresql.conf` (the archive settings from
[backup-and-restore.md](backup-and-restore.md) stay):

```
wal_level = replica
max_wal_senders = 5
max_replication_slots = 5
```

A role for replication, and the standby admitted by `pg_hba.conf`:

```sql
CREATE ROLE gpforum_replication WITH REPLICATION LOGIN PASSWORD '…';
SELECT pg_create_physical_replication_slot('gpforum_standby');
```

```
host replication gpforum_replication <standby address>/32 scram-sha-256
```

The slot makes the primary keep its WAL until the standby has it, so a standby
that falls behind catches up instead of needing a new base backup. Watch it: a
standby that is gone for good keeps the primary's WAL forever, until the disk
fills. Drop the slot of a standby you retire.

On the standby host, clone the primary; `-R` writes `standby.signal` and the
connection settings:

```sh
pg_basebackup -h <primary> -U gpforum_replication -D <data directory> \
    -Fp -Xs -R -S gpforum_standby
```

Start the standby. `SELECT pg_is_in_recovery();` answers `t` on it.

## Point the application at both

`GPFORUM_DATABASE_DSN` takes the primary and the standby in one DSN, and
libpq picks whichever accepts writes:

```
dbi:Pg:dbname=gpforum;host=<primary>,<standby>;port=5432,5432;target_session_attrs=read-write
```

No configuration changes at failover: a node whose connection dies
reconnects through the same DSN and lands on the new primary. The drill
proves this with the application's own connection.

## Watch the lag

On the primary:

```sql
SELECT application_name, state, replay_lag, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind
FROM pg_stat_replication;

SELECT slot_name, active, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes
FROM pg_replication_slots;
```

An inactive slot with growing `retained_bytes` is a standby that has stopped
following.

## Fail over

1. **Make sure the primary is down and stays down.** Two primaries accepting
   writes (split brain) is worse than downtime. Stop the service or fence
   the host before promoting.
2. Promote the standby: `pg_ctl -D <data directory> promote`, or
   `SELECT pg_promote();`. It answers `f` to `pg_is_in_recovery()` once it is
   the primary.
3. Nothing to change in GPForum: the multi-host DSN reaches the new primary on
   the next connection. Check `/health/ready`.
4. The old primary must not come back as a primary. Rebuild it as the new
   standby, with `pg_rewind` or a fresh `pg_basebackup`, and create a slot
   for it on the new primary.

Promotion is deliberately manual (ADR 0112): an automatic failover that
misjudges a network partition creates the split brain step 1 exists to
prevent.

## Related

- [backup-and-restore.md](backup-and-restore.md) — the archive and point-in-time recovery
- [reload-and-restart.md](reload-and-restart.md) — stopping and starting the service
- `docs/adr/0112-streaming-standby-and-manual-failover.md` — the decisions
- [`evidence/2026-10-01-standby-drill/`](evidence/2026-10-01-standby-drill/README.md) — the last recorded run
