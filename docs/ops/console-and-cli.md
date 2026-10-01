# Console and command line

Every command in `bin/` and where an administrator finds the same thing in
the admin console, or why there is none. Quality program item 6.5 asked for
the two to stop drifting apart; `t/214-console-cli-parity.t` keeps this page
honest: it fails when a `bin/` command is missing from the table below, when
the table names a command that no longer exists, or when it names a console
route that `lib/GPForum/Bootstrap/Routes.pm` does not register.

A command without a console route is not a gap by default. Some run before
there is a console (`gpforum-admin-bootstrap`), at deploy (`gpforum-migrate`)
or on a timer; others are benchmarks, seeds, drills and evidence tools that
belong to the operator's or developer's shell, not to a live forum's web
process.

## Commands

The **Console** column names the route, as `Routes.pm` names it, that covers
the command, or says `none`.

| Command | Console | Notes |
| --- | --- | --- |
| `bin/gpforum` | none | The application itself: it serves the console (`daemon`, `prefork`, Hypnotoad) and carries a subcommand for each command below (`bin/gpforum mail_check`, ...). |
| `bin/gpforum-admin-bootstrap` | none | Creates the first administrator, before anyone can sign in to the console. Later administrators are bound on `/admin/users/:user_id/roles`. |
| `bin/gpforum-antivirus-check` | `admin_settings` `admin_antivirus_check` | **Run antivirus check** on `/admin/settings` runs the same check (`Service::Operations::AntivirusCheck`) with the service's scanner and audits the report (`admin.antivirus_checked`). With `GPFORUM_ANTIVIRUS=command` only the shell can run it: clamscan loads its signatures for every file and three scans outlast a web request. |
| `bin/gpforum-bench-hypnotoad` | none | Benchmark: starts the Hypnotoad it measures. Developer and operator tooling. |
| `bin/gpforum-bench-hypnotoad-scaling` | none | Benchmark of worker counts; starts its own servers. Developer and operator tooling. |
| `bin/gpforum-benchmark` | none | HTTP benchmark against a running instance. `/admin/status` shows the benchmark commands and whether a baseline exists; running load from inside the instance under test would measure itself. |
| `bin/gpforum-dead-letter-check` | none | A drill of the dead-letter runbook against an in-memory outbox, for staging evidence. The live dead letters are listed, and replayed, on `/admin/jobs`. |
| `bin/gpforum-dead-letter-replay` | `admin_jobs` `admin_dead_letter_replay` | The **Replay** button per dead letter on `/admin/jobs`, over the same service (`Service::Outbox::DeadLetterReplay`), audited with the actor. |
| `bin/gpforum-evidence-meta` | none | Evidence tooling: stamps evidence archives. Operator's shell. |
| `bin/gpforum-evidence-validate` | none | Evidence tooling: validates evidence archives. Operator's shell. |
| `bin/gpforum-mail-check` | `admin_settings` `admin_mail_test` | **Send test message** on `/admin/settings` sends one message through the configured transport to the signed-in administrator's own address and audits the outcome (`admin.mail_test_sent`). Sending to another address (`--send --to`) and the dry-run transport probes stay on the shell: a console that mailed any address would be an open relay. |
| `bin/gpforum-mail-lifecycle-check` | none | A drill of the three identity mails under the test transport, for evidence. Developer and operator tooling. |
| `bin/gpforum-migrate` | none | Runs at deploy, before the new code serves. A web request must not change the schema of the database it is reading. |
| `bin/gpforum-os-preflight` | none | Inspects the host (limits, file descriptors, CPU) before the service starts. `/admin/status` shows the running service's own mode and health. |
| `bin/gpforum-outbox-dispatch` | none | The worker processes dispatch the outbox continuously; a web request is not a worker. `/admin/jobs` shows the outbox and its dead letters. |
| `bin/gpforum-partition-maintenance` | none | DDL on the partitioned tables, run by a timer or crontab. It needs locks and time a web request does not have. |
| `bin/gpforum-platform-check` | none | Checks the host's Perl, modules and database prerequisites. Developer and operator tooling. |
| `bin/gpforum-query-budget` | `admin_status` | `/admin/status` shows the query budgets and their drift (`--print`, `--check`). `--sync` rewrites the catalog from observed plans and stays on the shell. |
| `bin/gpforum-query-plan-evidence` | none | Evidence tooling: EXPLAIN on a seeded database. Developer tooling. |
| `bin/gpforum-scheduled-jobs` | none | Run by its timer (`gpforum-scheduled-jobs.service`). Running a pass from a web request would race the timer. |
| `bin/gpforum-search-rebuild` | `admin_jobs` `admin_search_rebuild` | **Rebuild search index** on `/admin/jobs` rebuilds through the outbox and audits the request (`admin.search_rebuild_requested`). |
| `bin/gpforum-seed-benchmark` | none | Seeds benchmark data. Never on a live forum. |
| `bin/gpforum-seed-performance-data` | none | Seeds performance data. Never on a live forum. |
| `bin/gpforum-staging-drill` | none | Staging drill, for release evidence. Operator's shell. |
| `bin/gpforum-staging-drill-attachments` | none | Staging drill for attachments, for release evidence. Operator's shell. |
| `bin/gpforum-staging-host-verify` | none | Verifies a staging host, for release evidence. Operator's shell. |
| `bin/gpforum-stress-load` | none | Load generator against a running instance. Operator's shell. |

## Only in the console

Some work has no command, because it is an administrator's decision rather
than an operator's procedure: roles, permissions and their bindings
(`/admin/roles`, `/admin/users`), categories (`/admin/categories`), the audit
viewer (`/admin/audit`), moderation, privacy review, the public page cache
purge (`/admin/jobs`) and the effective configuration (`/admin/settings`).

## Settings are not edited here

`/admin/settings` shows every variable `GPForum::Config` reads, its effective
value and whether it came from the environment or is the default, with every
secret shown only as set or not set. It does not change them: configuration
lives in the service's environment, `/etc/gpforum/gpforum.env`
(`/usr/local/etc/gpforum/gpforum.env` on FreeBSD), and takes effect on
`systemctl restart gpforum` (see `reload-and-restart.md`).
