# Staging drills (migrate / dump / restore)

Operator-runnable rehearsal for private-beta *preparation*. Passing these drills
does **not** mean GPForum is private-beta ready. Full nginx/systemd/Hypnotoad
deploy on a staging host remains a separate manual runbook.

## What this covers

| Phase | PASS means |
| --- | --- |
| Fresh migrate | Throwaway empty DB applies every migration; `schema_versions` count matches `migrations/`; a second `--apply` adds zero versions |
| Upgrade path | Throwaway DB applies all but the latest migration, then `bin/gpforum-migrate --apply` reaches the full count |
| Dump / restore | `pg_dump -Fc` of a migrated (optionally seeded) DB restores into a second throwaway DB with matching `schema_versions`, `users`, and `threads` counts |

## What this does not cover

- Attachment **blob** storage under `var/attachments` (`FilesystemStorage`). Metadata rows in PostgreSQL are restored; files on disk are not. Back up and restore that tree separately for a complete RPO/RTO drill.
- nginx / Caddy reverse proxy, systemd / rc.d / launchd units, Hypnotoad process management.
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
ahead of other installs on `PATH`:

```sh
# example: PostgreSQL 16 from MacPorts
sudo port install postgresql16-server postgresql16
export PATH="/opt/local/lib/postgresql16/bin:/opt/local/bin:$PATH"
# data directory is typically under /opt/local/var/db/postgresql16
```

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

## Evidence shape

JSON includes at least:

- `status`: `pass` or `fail` (process exit is non-zero on fail)
- `fresh_migrate`, `upgrade_path`, `dump_restore` phase objects
- `attachments.covered=false` with the filesystem storage limitation text
- `residual_gaps` noting full deploy remains manual
- `databases_dropped` listing cleaned throwaways

## Recording a run

1. Run `script/staging-drill --json` against a staging-like PostgreSQL major version.
2. Paste the JSON (or `--human` lines) into the staging ops notes for that commit.
3. Separately note whether `var/attachments` (or production object storage) was backed up/restored outside this script.
4. Do not mark private beta ready from this drill alone.
