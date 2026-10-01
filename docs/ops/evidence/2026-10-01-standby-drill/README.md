# Streaming standby and failover drill — 2026-10-01

`script/standby-drill` run on the macOS development host, against two
throwaway PostgreSQL clusters it creates and removes.

| | |
| --- | --- |
| Host | macOS, Apple silicon |
| PostgreSQL | 18.6 (Homebrew `postgresql@18`) |
| Result | `status=pass` |
| Replication | a write on the primary reached the standby in 54 ms |
| Promotion | 166 ms from `pg_ctl promote` to a writable primary |
| Application | a `GPForum::Schema` connection held across the loss reconnected through the multi-host DSN to the promoted standby and wrote to it; the three rows written before the loss were all on the new primary |
| Log | [`standby-drill.log`](standby-drill.log) |

What this does not prove: replication over a real network, under write
load, or between hosts with separate disks; those lags will be larger, and
`pg_stat_replication` is where to read them (`docs/ops/standby-and-failover.md`).
