# GPForum Deployment

GPForum is a Perl-first Mojolicious application intended to run as a persistent
Hypnotoad process behind a reverse proxy. PostgreSQL remains authoritative.
Redis, OpenSearch, Kubernetes, and SaaS control planes are not required.
Staging and production require GlifiStore as a disposable shared L2 cache.

## Production Shape

Recommended baseline:

```text
nginx or Caddy
-> Hypnotoad / Mojolicious
-> PostgreSQL
-> gpforum-outbox-dispatch (required worker)
-> optional Minion workers
```

The reverse proxy should handle TLS, compression, static files, large
attachments, request buffering, and coarse network limits. GPForum should handle
identity, authorization, forum domain workflows, event/audit/outbox writes,
SSR, and API responses.

## Preflight

Run before starting or reloading:

```sh
script/gpforum-os-preflight --json
script/gpforum-os-preflight --strict --json
```

`--strict` treats degraded OS/runtime posture as a deployment failure. This is
appropriate for production once limits and worker counts have been tuned.

## Deployment Evidence

Run the Hypnotoad evidence gate before treating a deployment profile as
measured:

```sh
script/bench-hypnotoad --check --profile small --workers 2 \
  --iterations 20 --warmup 3 \
  --route /categories \
  --route /t/018f1004-0001-7000-8000-000000000001 \
  --route /search?q=performance \
  --route /health/ready \
  --route /metrics
```

The benchmark starts an isolated temporary Hypnotoad runtime, records worker
metadata, compares against in-process evidence when enabled, observes DB query
counts through benchmark-only headers, and stops the server gracefully. See
`docs/DEPLOYMENT_EVIDENCE.md` for current local values and methodology.

## Perl dependencies

GPForum runs on the **OS system Perl** only (`/usr/bin/perl` on
Debian/Ubuntu with `Config{prefix}=/usr`, or FreeBSD ports/pkg perl under
`/usr/local`). Perl 5.38+ is required (Ubuntu 24.04 provides 5.38.x).
Version managers and custom PREFIX builds are unsupported.
`script/gpforum-system-perl` and `script/bootstrap-deps` refuse them.
Confirm the host with:

```sh
which perl
perl -v
make system-perl   # script/gpforum-system-perl --preflight
```

Host packages (before Carton):

- Debian/Ubuntu: `perl`, `build-essential`, `cpanminus`, `libpq-dev`,
  `postgresql-client`
- FreeBSD: `perl5`, `p5-App-cpanminus`, `postgresql16-client`
- macOS (MacPorts): system/MacPorts `perl5.38+`, `cpanminus`, and a matching
  PostgreSQL port such as `postgresql16-server` / `postgresql16`; keep
  `/opt/local/lib/postgresql16/bin` and `/opt/local/bin` on `PATH` so
  `pg_config`, `psql`, `pg_dump`, and `pg_restore` resolve from MacPorts
- Then: `cpanm -M https://cpan.metacpan.org/ Carton` for that system Perl

GPForum recognizes runtime modules from `cpanfile`, PostgreSQL modules from
`cpanfile.postgres` (Carton feature `postgres`), and exact distribution pins
from `cpanfile.snapshot`. Install only through Carton under system Perl:

```sh
make install-deps-postgres
# equivalent: script/bootstrap-deps --postgres
```

That runs `carton install --deployment` against the committed snapshot, using
`PERL_CARTON_MIRROR=https://cpan.metacpan.org/` unless the operator sets
another **HTTPS** official PAUSE/MetaCPAN mirror or a local `carton bundle`
cache (`--cached`). Carton itself runs module tests as `--notest` (Carton
1.0.35 built-in). GPForum does not sideload CPAN distributions with
`cpanm --notest` and does not fetch GitHub tarballs.

`carton install --deployment` populates `local/lib/perl5` and scripts such as
`local/bin/hypnotoad`. It does **not** install `local/bin/carton`. Carton is a
host tool for system Perl. Locate it with `script/gpforum-carton` (same
wrapper `script/bootstrap-deps` uses). If Carton is not next to system perl,
set `GPFORUM_CARTON` in the environment file. The provided systemd, rc.d, and
launchd units start the app with `script/gpforum-carton exec`, not
`local/bin/carton`.

Reproduce an install:

1. Use the same system Perl major/minor that produced `local/` (do not delete
   `local/` to paper over a mismatch after a distro Perl upgrade).
2. Keep `cpanfile`, `cpanfile.postgres`, and `cpanfile.snapshot` from the
   same git commit.
3. Run `script/bootstrap-deps --postgres` then `script/gpforum-carton check`.
4. Optional air-gap: `carton bundle` on a trusted host, copy `vendor/cache`,
   then `script/bootstrap-deps --postgres --cached`.

## Linux With systemd

Example:

```text
deploy/systemd/gpforum.service
deploy/nginx/gpforum.conf
```

Recommended operator actions:

- install Carton for the OS system Perl that will run the app, then install
  dependencies with `make install-deps-postgres` (`script/bootstrap-deps --postgres`);
- set `GPFORUM_SESSION_SECRET`;
- set `GPFORUM_SESSION_SECRETS` to comma-separated previous secrets when
  rotating, so existing cookies still validate;
- set database credentials with environment or an environment file;
- install `/etc/gpforum/gpforum.env` with `GPFORUM_SESSION_SECRET`,
  optional `GPFORUM_SESSION_SECRETS`,
  `GPFORUM_DATABASE_DSN`, `GPFORUM_DATABASE_USER`,
  `GPFORUM_DATABASE_PASSWORD`, `GPFORUM_PUBLIC_BASE_URL`,
  `GPFORUM_METRICS_TOKEN`, optional `GPFORUM_METRICS_TOKENS`, and
  `GPFORUM_GLIFISTORE_URL`;
- set `GPFORUM_CARTON` when Carton is not on the service `PATH`;
- set `LimitNOFILE=65536`;
- run migrations before first start;
- run `script/query-budget --sync` and `script/query-budget --check` before
  readiness validation;
- keep the app behind nginx or Caddy;
- use `kill -QUIT` or `systemctl stop` for graceful shutdown.

The systemd units create `/run/gpforum` with `RuntimeDirectory=gpforum`.

Hourly operational sweeps are a timer, not a daemon:

```text
deploy/systemd/gpforum-scheduled-jobs.timer
deploy/systemd/gpforum-scheduled-jobs.service
```

```sh
systemctl enable --now gpforum-scheduled-jobs.timer
```

The oneshot unit runs `bin/gpforum-scheduled-jobs --once --limit 100` through
`script/gpforum-carton`. It deletes stale sessions, rate-limit buckets,
identity tokens, completed outbox rows, and dead letters in bounded
batches, then calls attachment orphan cleanup and partition
policy/evidence. It does not loop and does not execute partition DDL.
See `docs/ops/scheduled-jobs.md`.

## FreeBSD With rc.d

Example:

```text
deploy/freebsd/gpforum
deploy/nginx/gpforum.conf
```

Recommended operator actions:

- install under `/usr/local/www/gpforum`;
- run as a dedicated `gpforum` user;
- use rc.conf to set `gpforum_enable=YES`;
- tune file descriptor limits through login class or service wrapper;
- use nginx, Caddy, or another local reverse proxy for TLS/static transfer;
- consider jails for process isolation;
- install an hourly crontab for `bin/gpforum-scheduled-jobs --once` (no
  rc.d periodic sample is shipped; see `docs/ops/scheduled-jobs.md`).

## macOS With launchd

Example:

```text
deploy/launchd/com.gpforum.app.plist
deploy/launchd/com.gpforum.scheduled-jobs.plist
```

`com.gpforum.scheduled-jobs` is a 3600s interval sample for the same oneshot
command. It is not KeepAlive.

macOS remains primarily a development and profiling platform. It is supported
for local persistent runs, but production throughput tuning should be measured
on the target FreeBSD or Linux deployment host.

## Reverse Proxy

Examples:

```text
deploy/nginx/gpforum.conf
deploy/nginx/gpforum-unix-socket.conf
deploy/caddy/Caddyfile
```

The proxy should preserve:

- `Host`
- `X-Forwarded-For`
- `X-Forwarded-Proto`
- WebSocket upgrade headers for `/realtime`

Static `/assets/` files live in the repository `assets/` tree
(`/opt/gpforum/assets` after install). Do not point the proxy at
`public/assets`; that path does not exist.

`GET /attachments/:attachment_id/download` is an application route. Nginx must
proxy that URL to Hypnotoad. A `location /attachments/ { internal; }` prefix
intercepts the download and returns 404. Keep an internal alias on a different
prefix (`/internal-attachments/`) for `X-Accel-Redirect` after the app
authorizes; point that alias at the attachment store root (default
`var/attachments`, or an operator path such as `/srv/gpforum/attachments`).
The app still streams bytes itself until an `X-Accel-Redirect` header is
implemented. Caddy has no `internal` alias in the sample; downloads go through
`reverse_proxy`.

For static assets and attachments, prefer web-server file transfer with cache
headers and sendfile support. GPForum can authorize access, but Perl should not
be the ordinary large-file transfer path.

## UNIX Socket Mode

UNIX socket mode is optional:

```text
GPFORUM_RUNTIME_LISTEN=http+unix://%2Frun%2Fgpforum%2Fgpforum.sock
```

When using UNIX sockets, `reuseport` is not applied. The systemd socket unit
creates `/run/gpforum` with `RuntimeDirectory=gpforum` (mode `0750`, owned by
the service user). Other supervisors must create that directory with safe
ownership before start.

## GlifiStore (required L2)

Staging and production fail closed when `GPFORUM_GLIFISTORE_URL` is missing.
PostgreSQL remains the only source of truth. An unreachable GlifiStore degrades
readiness to process-local L1 and PostgreSQL; it does not become authoritative.

`GlifiStore::Client` is **not** a Carton or `cpanfile` pin: it is not published
on PAUSE, and this repository does not vendor a GlifiStore server or Perl
client. `Service::Operations::SharedCache` loads the client at runtime:

```perl
require GlifiStore::Client;
GlifiStore::Client->connect(%endpoint);
```

The expected client surface is `connect`, `get`, `put`, `erase`, and `ping`
(`t/lib/GPForum/Test/SharedCacheClient.pm` is the in-tree stand-in). There is
no installable GlifiStore binary or CPAN distribution in this project.

Operator steps before a staging or production start:

1. Run a GlifiStore server that listens on `GPFORUM_GLIFISTORE_URL`
   (sample configs use `tcp://127.0.0.1:7379`; `unix://path` is also valid).
2. Install `GlifiStore::Client` onto the same Perl that owns `local/` (private
   distribution or extra `PERL5LIB`).
3. Set `GPFORUM_GLIFISTORE_URL` in `/etc/gpforum/gpforum.env`.

Without the operator-supplied server and client, shared L2 cannot connect.
The profile still requires the URL.

## PostgreSQL Baseline

Minimum recommended posture:

- application role is not PostgreSQL superuser;
- migrations use a separate role;
- `statement_timeout` defaults to 15s on app connect
  (`GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS`; `gpforum-migrate --apply`
  clears it);
- `idle_in_transaction_session_timeout` defaults to 10s on app connect
  (`GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS`);
- `lock_timeout` defaults to 3s on app connect
  (`GPFORUM_DATABASE_LOCK_TIMEOUT_MS`);
- `application_name=gpforum` is set on connect;
- backups and restore tests exist before production launch.

For a repeatable local/staging migrate + `pg_dump`/`pg_restore` rehearsal on
throwaway databases, see `docs/ops/staging-drills.md`
(`script/staging-drill`). Attachment files under `var/attachments` and full
nginx/systemd deploy are out of scope for that script.

## Tuning By OS

Linux:

- use `epoll` through Mojolicious runtime selection;
- prefer systemd unit limits over application-side tuning;
- use nginx/Caddy for TLS, compression, static files, and sendfile;
- inspect sockets with `ss` and process limits with `/proc`.

FreeBSD:

- use `kqueue`;
- prefer rc.d and login class limits;
- consider jails for isolation;
- inspect runtime with `sockstat`, `systat`, `top`, and `netstat`.

macOS:

- use `kqueue`;
- keep runtime simple for development;
- do not treat macOS benchmark results as production throughput proof.

## Non-Goals

GPForum does not automatically:

- modify sysctl;
- require root;
- pin CPU affinity;
- install systemd/rc.d/launchd files;
- require Redis;
- require Kubernetes;
- replace PostgreSQL as authoritative storage.
