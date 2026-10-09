# Partition Lifecycle

`GPForum::Service::Operations::PartitionLifecycle` versions the operational
policy for range-partitioned `event_log`, `audit_log`, and `notifications`
tables. The PostgreSQL `partition_registry` table is mapped by
`GPForum::Schema::Result::PartitionRegistry`.

The lifecycle contract is:

- plan monthly partitions from the current UTC month through the lookahead,
  computed from the date and never written down;
- create the missing ones as `CREATE TABLE ... (LIKE parent ...)` followed by
  `ALTER TABLE parent ATTACH PARTITION`, one transaction per month together
  with its registry row, so the parent is held only in `SHARE UPDATE
  EXCLUSIVE`; the DEFAULT partition is held in `ACCESS EXCLUSIVE`, which
  stops unpruned reads (and the event and audit writes that start with one),
  so each lock wait is half a second and a month gets five tries;
- serialise runs with the session advisory lock `4021970002`; a run that
  cannot take it is reported as skipped and does nothing;
- record intended state as `planned` → `created` → `detached` → `archived` →
  `dropped`;
- recommend detach when a created window is older than the profile retention;
- emit restore evidence from created registry rows.

Who runs the DDL (ADR 0113, amending ADR 0012): `bin/gpforum-migrate --apply`
after its migrations, and `bin/gpforum-partition-maintenance --apply` from a
daily timer (`deploy/systemd/gpforum-partition-maintenance.timer`, its
launchd and FreeBSD counterparts). Both are operator processes. No web
request and no long-running worker executes partition DDL: that is what ADR
0012 kept out of the application, and it still is. The hourly scheduled-jobs
command calls plan/retention/restore evidence only; see
`docs/ops/scheduled-jobs.md`.

Detach, archive and drop stay manual: they remove audit and event history,
which is the owner's decision. Migration 049 is the one exception, and only
for months that never held a row: it drops the empty past months migration
038 named.

The runbook is `docs/ops/partition-maintenance.md`. Coverage lives in
`t/99-partition-lifecycle.t`, `t/173-partition-maintenance.t`,
`t/10-migrate-command.t`, `t/151-scheduled-jobs.t`, and, against
PostgreSQL, `t/integration/postgres-partition-maintenance.t` and
`t/integration/postgres-partition-horizon.t`.
