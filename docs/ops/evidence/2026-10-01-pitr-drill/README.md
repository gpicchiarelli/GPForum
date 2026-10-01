# Point-in-time recovery drill — 2026-10-01

`script/pitr-drill` run on the macOS development host, against a throwaway
PostgreSQL cluster it creates and removes.

| | |
| --- | --- |
| Host | macOS, Apple silicon |
| PostgreSQL | 18.6 (Homebrew `postgresql@18`) |
| Result | `status=pass`: the row written before the recovery target was recovered, the row written after it was not |
| Wall time | 108 s for the whole drill (cluster creation, base backup, WAL archive, simulated loss, restore to the target) |
| Log | [`pitr-drill.log`](pitr-drill.log) |

What this proves: the base backup plus archived WAL restore to a chosen
instant on this PostgreSQL version, with the procedure in
`docs/ops/backup-and-restore.md`.

What it does not: a restore of a production-sized database on a production
host (the recovery time there is dominated by the database's size and the
WAL to replay), or the attachments, which `script/staging-drill-attachments`
rehearses separately.
