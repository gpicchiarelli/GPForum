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
| `bin/gpforum-partition-maintenance` | none | DDL on the partitioned tables, run by its daily timer or crontab and, through its lifecycle, by `gpforum-migrate --apply` (ADR 0113). It needs locks and time a web request does not have. |
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

## Machine-readable output

Every command that reports state takes `--json` and prints one JSON object on
one line of standard output instead of its lines -- a command that loops
prints one per pass, so its output reads as JSON Lines. Every object has
`status`, and most a `command` (the `bin/` name) and a `mode`. The exit code
is the same as without `--json`: 0 ok, 1 a problem, 2 misuse. Misuse prints
the usage on standard error and nothing on standard output. When the work
itself fails -- the database cannot be reached -- the reason goes to standard
error, the exit code is 1, and the object still comes, with `status` `fail`,
the reason in `error` and the lists empty. Work already done shows where the
command knows it: `dead-letter-replay` keeps the ids it replayed before the
failure, and a looping `outbox-dispatch` has printed a line for each batch
before it. `migrate --apply` leaves `applied` out when a migration failed:
each one commits as it goes, so those before the failure are in the schema,
and `--check` lists what is left (`applied` is `[]` only when the database
was never reached). `scheduled-jobs` lists no job, though the jobs that ran
before the failure did their work.

No object carries a secret. What is printed is what the lines print, except
that `platform-check` adds each check's report: what `os-preflight --json`
prints, and the operational profile's floors. An inline password in a
failure's reason -- a DSN's `password=`, which DBI's connect error repeats --
is replaced by `[redacted]`, on standard error too.
Each object is flushed as it is printed, so a reader on a pipe gets every
batch of a looping command when it ends.

For the commands from `migrate` to `search-rebuild` below, `status` is `ok`
or `fail` as the exit code says (`platform-check` adds `degraded`), and keys
are sorted, so the same state prints the same bytes. `os-preflight`,
`antivirus-check` and the evidence commands keep their own vocabulary (`ok`
or `pass`, `degraded`, `disabled`, `fail`); the evidence commands print JSON
by default and their lines with `--human`.

| Command and mode | Object |
| --- | --- |
| `gpforum-migrate --plan --json` | `migrations`: every file in `migrations/`, each `{version, description, file}`. Needs no database. |
| `gpforum-migrate --check --json` | `pending`: the migrations the database has not recorded, as above; `status` `fail` when any are, or (`error`) when an applied file changed since. |
| `gpforum-migrate --apply --json` | `applied`: each `{version, description, checksum, execution_time_ms}`; left out when a migration failed (above). `partitions`: the window step after the migrations, shaped as `gpforum-partition-maintenance --json` less `command` and `mode`; left out with `--no-partitions`. A conflict or error there makes `status` `fail` with `applied` still listed. |
| `gpforum-partition-maintenance --json` | `lookahead_months`, `skipped` (1 when another run held the maintenance lock) and the lists `created`, `existing`, `planned`, `conflicts`, `errors` (`partition-maintenance.md`). |
| `gpforum-platform-check --json` | `mode`, `strict`, `checks`: each `{name, status, report}`, `report` being the check's own (`os-preflight --json` for `os_preflight`). `status` is the worst check's, `fail` when the exit code is 1. |
| `gpforum-query-budget --print --json` | `endpoints`: the catalog, keyed by endpoint name. |
| `gpforum-query-budget --check --json` | `missing`, `extra`, `mismatched`: endpoint names. |
| `gpforum-query-budget --sync --json` | `synced`: the number the line prints, every endpoint in the catalog, whether its row was written or already matched. |
| `gpforum-scheduled-jobs --json` | `jobs`: each `{name, count}` and, when there are any, `ok`, `skipped`, `error`, `errors` (`scheduled-jobs.md`). |
| `gpforum-outbox-dispatch --json` | One object per batch: `selected`, `dispatched`, `failed`, `dead_lettered` (`dead-letters.md`). |
| `gpforum-dead-letter-replay --list --json` | `dead_letters`, as `/admin/jobs` lists them (`dead-letters.md`). With `--id` instead, `outcomes`: each `{dead_letter_id, status}`, with `outbox_id` when replayed or `error` when refused. |
| `gpforum-search-rebuild --status --json` | `lag_status` (`current` or `behind`), `pending`, `lag_seconds`, `oldest_pending_at` (UTC, or `null`). `status` is the command's, `ok`. |
| `gpforum-search-rebuild --json` | `entity_type`, `indexed`, `unchanged`, `pruned`. |
| `gpforum-os-preflight --json` | The preflight report: `checks`, each `{name, status}`, and the host it read. |
| `gpforum-antivirus-check --json` | The antivirus evidence (`antivirus.md`). |
| `gpforum-dead-letter-check`, `gpforum-mail-check`, `gpforum-mail-lifecycle-check`, `gpforum-evidence-validate`, `gpforum-staging-*`, `gpforum-stress-load` | JSON evidence by default (their runbooks). |

A field may be added; one is not renamed or removed without a CHANGELOG
entry. For example, to fail a deploy step when the schema is behind:

```sh
bin/gpforum-migrate --check --json | jq -e '.status == "ok"'
```

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
