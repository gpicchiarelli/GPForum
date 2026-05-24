# GPForum Deployment

GPForum is a Perl-first Mojolicious application intended to run as a persistent
Hypnotoad process behind a reverse proxy. PostgreSQL remains authoritative.
Redis, OpenSearch, Kubernetes, and SaaS control planes are not required.

## Production Shape

Recommended baseline:

```text
nginx or Caddy
-> Hypnotoad / Mojolicious
-> PostgreSQL
-> Minion workers
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

## Linux With systemd

Example:

```text
deploy/systemd/gpforum.service
deploy/nginx/gpforum.conf
```

Recommended operator actions:

- install dependencies with Carton;
- set `GPFORUM_SESSION_SECRET`;
- set database credentials with environment or an environment file;
- set `LimitNOFILE=65536`;
- run migrations before first start;
- keep the app behind nginx or Caddy;
- use `kill -QUIT` or `systemctl stop` for graceful shutdown.

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
- consider jails for process isolation.

## macOS With launchd

Example:

```text
deploy/launchd/com.gpforum.app.plist
```

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

For static assets and attachments, prefer web-server file transfer with cache
headers and sendfile support. GPForum can authorize access, but Perl should not
be the ordinary large-file transfer path.

## UNIX Socket Mode

UNIX socket mode is optional:

```text
GPFORUM_RUNTIME_LISTEN=http+unix://%2Frun%2Fgpforum%2Fgpforum.sock
```

When using UNIX sockets, `reuseport` is not applied. The supervisor is
responsible for creating the runtime directory with safe ownership.

## PostgreSQL Baseline

Minimum recommended posture:

- application role is not PostgreSQL superuser;
- migrations use a separate role;
- `statement_timeout` is set per role or deployment;
- `idle_in_transaction_session_timeout` is enabled;
- `lock_timeout` is used for migrations;
- `application_name=gpforum` is configured where possible;
- backups and restore tests exist before production launch.

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
