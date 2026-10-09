# ADR 0116: A Log Id Is Looked Up in Every Partition, Not Derived Into One

## Status

Accepted. Follows ADR 0113 (rolling monthly partitions); keeps ADR 0091's
append-once replay and the audit hash chain as they are.

## Context

`notifications`, `event_log` and `audit_log` are `PARTITION BY RANGE
(created_at)`. PostgreSQL requires a unique key on a partitioned table to
contain the partition key, so their primary keys are `(notification_id,
created_at)`, `(event_id, created_at)` and `(audit_id, created_at)`. The key
catches an id written twice at the same time and nothing else: a row already
stored under the id at another time is no conflict, and the insert writes a
second row with the same id.

`t/integration/postgres-notifications.t` pinned it as a TODO. A notification
row left without its inbox row, at another time than the delivery's clock
reads, got a second `notifications` row beside it, and the new inbox row,
which joins on both columns, reached only the second. The same hole was open
in the other two tables:

- `event_log`: the recorder looks the event up by id before inserting, which
  covers a leftover, but two workers recording the same caller-supplied id at
  once, each at its own clock, both miss the other's uncommitted row and both
  inserts succeed.
- `audit_log`: a caller's `audit_id` already stored at another time was
  written again. The recorder already treats a conflict on the key as a
  collision and mints a new id; at another time there was no conflict.

The candidate fix was to take `created_at` from the id: ids are UUIDv7, whose
first 48 bits are the minting time in milliseconds, so the same id would
always land on the same `(id, created_at)` and the key would catch it with no
extra read. It does not fit any of the three tables:

- **Notification ids carry no time.** `_notification_id_for` derives the id
  from the SHA-1 of the delivery's idempotency key, version nibble 5, so a
  retried delivery finds the id it made the first time. That id has no
  timestamp to derive from. A time-bearing id would need a time the retry
  can recompute, which the delivery does not have (only fan-outs carry an
  event id), and changing how ids are derived would give every delivery in
  flight across the deploy a new id: the duplicate this sets out to prevent.
- **An event's `created_at` is its command's time.** The stores pass the
  command's clock reading as `timestamp`, the same reading their own rows
  take; the export builder passes the request's `created_at`; the
  projection offsets record the event's `created_at` beside its id; the unit
  tier runs on fixed clocks and ids such as `generated-1`. An id minted by
  `Infrastructure::Id` reads the system clock, not `Service::Clock`.
- **An audit record's `created_at` is hashed.** `record_hash` covers it, the
  chain is ordered by `(created_at, audit_id)`, and the dead-letter replay
  and report transitions pass their command's time.

Retention by month would also have followed the id's minting time rather than
the row's.

## Decision

- **The writer looks the id up in every partition before inserting.** The
  primary key's leading column is the id, so each partition's key index
  answers the lookup. Measured on PostgreSQL 18 for an absent id (the worst
  case, every partition probed): 8 shared buffers with the 4 partitions an
  install starts with, 19 with 13 partitions and 180,000 rows, 43 with 25
  partitions and 420,000 rows, 73 with 40 partitions and 720,000 rows: about
  two per partition, the same on every run. The times move with the cache:
  0.04 ms with 4 partitions; with 25 to 40, from 0.3 to 1.5 ms of execution
  and 0.5 to 1 ms of planning when part of the pages are read from disk.
- **Notifications reuse the stored row's time.** A notification already
  stored under the id is not written again; its `created_at`, exactly as
  PostgreSQL returns it, becomes the inbox row's, so the inbox joins the
  notification that exists. No lock: two deliveries racing past the lookup
  both write the inbox row, whose key is `(recipient_user_id,
  notification_id)` with no time in it, and the loser's savepoint takes its
  notification row back with it. The test races one at another time to show
  it.
- **A caller's event id is locked first.** `record_event` takes
  `pg_advisory_xact_lock(2026100310, hashtext(event_id))` before its lookup,
  in the caller's transaction or one of its own, so a second worker with the
  same id waits for the first to commit and then finds its event. That holds
  at READ COMMITTED, the isolation every transaction here runs at: the
  lookup is a statement of its own, taken after the lock, so it sees what
  the first worker committed. The two int4 keys are a key space apart from
  the audit chain's single bigint `2026060210`; two ids that hash alike only
  wait for each other.
- **A caller's audit id is looked up under the chain lock.** Every audit
  write already holds the chain's advisory lock, so the lookup cannot race.
  An id already taken is a collision, written under a new id, as after a
  conflict on the key.
- **An id the writer mints itself is not locked, nor, for an audit record,
  looked up.** No one else knows a UUIDv7 minted in this call. An event is
  still looked up by its id whatever its origin, as it was before. Event and
  audit ids are minted by the recorder unless the caller passes one;
  notification ids are derived from the delivery (a caller may pass one; no
  caller in `lib/` does), and always looked up.
- **No migration.** The keys stay as they are; the conflict paths stay for
  writes at the same time.

## Consequences

- A delivery, a caller-supplied event id or a caller-supplied audit id writes
  its row once whatever time it is retried at, in every partition: DEFAULT, a
  monthly one, one attached after the application started.
- Each delivery pays one more indexed read; an event with a caller's id pays
  an advisory lock and, autocommit, a transaction around the event and its
  outbox row. Events and audit records with minted ids pay nothing. A report
  transition and an attachment event mint their event id before handing it
  to the recorder (a report transition's is in its idempotency key), so they
  pay the lock, in the caller's transaction or one the recorder opens.
- The two stores that pass their own event id, report transitions and
  attachments, record the event before the audit record, so they take the
  event id's lock before the audit chain's, always in that order. Only two
  different ids whose `hashtext` collides, one of them recorded after an
  audit record in its transaction, could meet in a deadlock; PostgreSQL
  detects it and fails one of the two commands, as it does any deadlock.
- The read grows with the number of partitions, about two buffers each. While
  retention is open (ADR 0113) the number grows by one a month per table;
  dropping old months bounds it.
- A notification completed from a leftover row keeps the leftover's time, so
  it sits in the inbox where it was first created, not at the top.

## Alignment

- ADR 0113 (rolling monthly partitions), ADR 0091 (append once), ADR 0102
  (the inbox shows only readable sources).
- `lib/GPForum/Service/Notification/Dispatcher.pm`,
  `lib/GPForum/Infrastructure/EventRecorder.pm`.
- `t/316-log-ids-across-partitions.t`,
  `t/integration/postgres-notifications.t`,
  `t/integration/postgres-partition-conflicts.t`.
