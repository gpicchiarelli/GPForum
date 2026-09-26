# Partition Lifecycle

`GPForum::Service::Operations::PartitionLifecycle` versions the operational
policy for range-partitioned `event_log`, `audit_log`, and `notifications`
tables. The PostgreSQL `partition_registry` table is mapped by
`GPForum::Schema::Result::PartitionRegistry`.

The lifecycle contract is:

- plan monthly partitions from the current month through the profile horizon;
- record intended state as `planned` → `created` → `detached` → `archived` →
  `dropped`;
- recommend detach when a created window is older than the profile retention;
- emit restore evidence from created registry rows.

This boundary does not execute `CREATE TABLE ... PARTITION OF`. Operators apply
DDL from planned windows. That keeps PostgreSQL authoritative and avoids
application-owned schema mutation. The hourly scheduled-jobs command calls
plan/retention/restore evidence only; see `docs/ops/scheduled-jobs.md`.

Coverage lives in `t/99-partition-lifecycle.t` and `t/151-scheduled-jobs.t`.
