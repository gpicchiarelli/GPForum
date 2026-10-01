# ADR 0112: A Streaming Standby, a Multi-Host DSN and Manual Failover

## Status

Accepted. Meets ADR 0050's replication requirement; follows ADR 0058
(replication lag is monitored) and ADR 0111 (no read replica for search yet).

## Context

ADR 0050 says operators MUST run PostgreSQL with replication, WAL archiving
and point-in-time recovery. Until 2026-10-01 the repository met two of the
three: `docs/ops/backup-and-restore.md` configured the archive and
`script/pitr-drill` rehearsed a restore, and the same page said plainly that
nothing set up a standby. A restore is a recovery story, not an availability
one: losing the primary host meant downtime for as long as the replay took.

Three questions needed answers: how the standby follows, how the application
finds the new primary, and who decides to fail over.

## Decision

- **Physical streaming replication through a replication slot.** One standby
  per primary, cloned with `pg_basebackup -R -S`. The slot means a standby
  that falls behind catches up rather than needing a new base backup; its
  cost -- WAL retained without bound for a standby that is gone -- is watched
  through `pg_replication_slots` and the runbook says to drop a retired slot.
  Logical replication is not used: it does not carry DDL, and the migrations
  are DDL.
- **The application connects with one multi-host DSN.**
  `host=<primary>,<standby>;target_session_attrs=read-write` lets libpq pick
  whichever server accepts writes. No configuration changes at failover: a
  node whose connection dies reconnects through the same DSN and lands on
  the new primary. `script/standby-drill` proves it with the application's
  own `GPForum::Schema` connection, held from before the loss to after the
  promotion.
- **Failover is manual.** The operator fences the old primary and promotes
  the standby. An automatic tool that misjudges a network partition creates
  two primaries, and a split brain loses data in a way downtime does not.
  An operator who wants automatic failover adds a consensus-based tool
  (Patroni or similar) on their own judgement; GPForum needs nothing from it
  beyond the multi-host DSN.
- **The standby serves no reads.** ADR 0111 keeps search on the primary: a
  lagging replica would show a category turned private for the length of
  the lag, which ADR 0102 forbids.

## Consequences

- `docs/ops/standby-and-failover.md` is the procedure; `script/standby-drill`
  rehearses it (`make standby-drill`); the first recorded run is in
  `docs/ops/evidence/2026-10-01-standby-drill/`: a write reached the standby
  in about 50 ms, promotion took about 160 ms, and the connected application
  wrote to the new primary without a restart.
- Point-in-time recovery stays: a standby replicates a mistaken `DELETE` as
  faithfully as a post.
- Replication lag is visible to the operator through `pg_stat_replication`;
  exposing it on `/metrics` is open.

## Alignment

ADR 0050 (replication, WAL archiving, PITR), ADR 0058 (replication lag
monitored), ADR 0063 (scaling prioritises replica reads -- deferred by
ADR 0111 for search), ADR 0102 (no stale reads of restricted content),
ADR 0111.
