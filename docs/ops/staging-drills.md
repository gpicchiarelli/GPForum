# Staging drills (migrate / dump / restore / attachments / deploy checklist)

Operator-runnable rehearsal for private-beta *preparation*. Passing these drills
does **not** mean GPForum is private-beta ready. A live Hypnotoad + TLS staging
host deploy remains a separate operator runbook beyond the static checklist.

## What this covers

| Phase | PASS means | Entrypoint |
| --- | --- | --- |
| Fresh migrate | Throwaway empty DB applies every migration; `schema_versions` count matches `migrations/`; a second `--apply` adds zero versions | `script/staging-drill` |
| Upgrade path | Throwaway DB applies all but the latest migration, then `bin/gpforum-migrate --apply` reaches the full count | `script/staging-drill` |
| Dump / restore | `pg_dump -Fc` of a migrated (optionally seeded) DB restores into a second throwaway DB with matching `schema_versions`, `users`, and `threads` counts | `script/staging-drill` |
| Attachment filesystem | Throwaway sample tree under a temp root is written via `FilesystemStorage`, copied to a backup tree, wiped, restored, and SHA-256 / byte verified | `script/staging-drill-attachments` |
| Deploy checklist | `deploy/systemd/*.service` and `deploy/nginx/*.conf` templates exist and include `User`, `EnvironmentFile`, `ExecStart` via `script/gpforum-carton`, and nginx `upstream gpforum_backend` | `script/staging-drill-attachments` |

## What this does not cover

- Live production (or long-lived staging) trees under `var/attachments` or an
  operator path such as `/srv/gpforum/attachments`. The attachment drill uses a
  throwaway temp tree only; object-storage backends are out of scope.
- Loading units into a real systemd, `nginx -t` against installed host configs,
  Hypnotoad process start, TLS termination, or env-file secret contents.
- Mail delivery, load tests, or private-beta product gates.

## Prerequisites

- PostgreSQL server the operator may create/drop databases on (role needs `CREATEDB`, or superuser).
- Client tools: `pg_dump`, `pg_restore` on `PATH` (or set `GPFORUM_PG_DUMP` / `GPFORUM_PG_RESTORE`).
- App deps installed: `make install-deps-postgres`.
- Environment (same shape as other integration tools):

```sh
export GPFORUM_DATABASE_DSN='dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432'
export GPFORUM_DATABASE_USER='gpforum_migrator'
export GPFORUM_DATABASE_PASSWORD='…'
```

On macOS with MacPorts PostgreSQL, install a server port such as
`postgresql16-server` (and matching client tools), then put MacPorts binaries
ahead of other installs on `PATH` via `script/gpforum-macports-env`:

```sh
# example: PostgreSQL 16 from MacPorts
sudo port install postgresql16-server postgresql16
eval "$(script/gpforum-macports-env)"   # prints export PATH=...
script/gpforum-macports-env --check     # psql / pg_dump / pg_config under /opt/local
# data directory is typically under /opt/local/var/db/postgresql16
```

The helper is a no-op on Linux (and when MacPorts is absent), so it is safe to
document in shared runbooks. Prefer MacPorts `/opt/local` over Homebrew when
both are present on the operator Mac.

The DSN database name is only the admin/maintenance connection target. The drill
creates throwaways such as `gpforum_drill_<pid>_<time>_fresh` and does not
modify the named database’s schema.

## Commands

Default JSON evidence (paste into ops notes):

```sh
script/gpforum-carton exec bin/gpforum-staging-drill --json
# equivalent wrapper:
script/staging-drill --json
```

Human summary:

```sh
script/staging-drill --human
```

Optional knobs:

```sh
script/staging-drill --database gpforum_drill_manual \
  --seed-profile small \
  --json

script/staging-drill --skip-upgrade --seed-profile none --json
script/staging-drill --keep-databases --human   # debug; operator must drop later
```

Make target (optional; not part of `make check` / default CI):

```sh
make staging-drill
```

## Attachment filesystem + deploy checklist

No PostgreSQL required. Default JSON evidence:

```sh
script/gpforum-carton exec bin/gpforum-staging-drill-attachments --json
# equivalent wrapper:
script/staging-drill-attachments --json
```

Human summary / phase filters:

```sh
script/staging-drill-attachments --human
script/staging-drill-attachments --attachments-only --json
script/staging-drill-attachments --deploy-only --human
```

Make target (optional; not part of `make check` / default CI):

```sh
make staging-drill-attachments
```

The deploy phase is a **static** template rehearsal. If `systemd-analyze` or
`nginx` happen to be on `PATH`, evidence notes they are available; the drill
still does not install units or run `nginx -t` against a host config root.

## Evidence shape

PostgreSQL drill JSON includes at least:

- `status`: `pass` or `fail` (process exit is non-zero on fail)
- `fresh_migrate`, `upgrade_path`, `dump_restore` phase objects
- `attachments.covered=false` for the DB dump/restore scope (blobs are a
  separate entrypoint)
- `residual_gaps` noting live Hypnotoad/TLS deploy and private-beta remain open
- `databases_dropped` listing cleaned throwaways

Attachments/deploy drill JSON includes at least:

- `status`: `pass` or `fail`
- `attachments_phase` with throwaway backup/restore file count and digests
- `deploy_phase.deploy_checklist` with per-unit / per-nginx match results
- `residual_gaps` for live systemd/nginx/Hypnotoad and private-beta

## Recording a run

1. Run `script/staging-drill --json` against a staging-like PostgreSQL major version.
2. Run `script/staging-drill-attachments --json` (no DB needed) and paste both
   evidence blobs into the staging ops notes for that commit.
3. Separately note whether a live `var/attachments` (or production object
   storage) tree was backed up/restored outside the throwaway drill.
4. Separately note any host `systemctl` / `nginx -t` / Hypnotoad bring-up.
5. Do not mark private beta ready from these drills alone.
