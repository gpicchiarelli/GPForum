# GPForum Production Readiness Checklist

Date: 2026-05-29.

This checklist is the production gate for GPForum. New product behavior should
not be added until the items here remain green in CI and in a staging database
that matches the production PostgreSQL major version.

## Architecture Map

| Boundary | Current implementation |
| --- | --- |
| Web | `bin/gpforum`, `GPForum.pm`, `Bootstrap::*`, `Controller::*`, SSR templates, `Web::*Payload`, `Web::RenderPolicy`, `Web::PublicHttpCache` |
| Application | Bootstrap composition and command orchestration in `Bootstrap::*`, CLI command classes in `Command::*`, workflow boundaries such as `PostingWorkflow` |
| Domain/Service | `Service::*`, `Domain::EventEnvelope`, `Infrastructure::EventRecorder`; controllers delegate reads/writes to these services |
| Persistence | `GPForum::Schema`, `Schema::Result::*`, SQL migrations in `migrations/`, PostgreSQL as the authority |
| Worker | `Command::OutboxDispatch`, `Worker::MinionRegistrar`, `Worker::Handler::*`, `Service::Outbox::*`, optional Minion PostgreSQL backend |
| Realtime | `/realtime`, `Service::Realtime::*`, PostgreSQL LISTEN/NOTIFY plus outbox polling fallback; SSR remains authoritative |
| Infra | `deploy/nginx`, `deploy/systemd`, `deploy/freebsd`, `deploy/launchd`, `script/gpforum-os-preflight`, runtime policy classes |
| Observability | `/health/live`, `/health/ready`, `/metrics`, DB query observer, query budget gates, query plan evidence, benchmarks |

Entrypoints:

- Web: `carton exec hypnotoad -f bin/gpforum`
- Development web: `carton exec morbo bin/gpforum`
- Migration: `carton exec bin/gpforum-migrate --apply`
- Outbox worker: `carton exec bin/gpforum-outbox-dispatch --loop --limit 100 --sleep 5`
- Optional Minion worker: `GPFORUM_MINION_ENABLED=1 carton exec perl -Ilib bin/gpforum minion worker`
- Admin bootstrap: `carton exec bin/gpforum-admin-bootstrap --user-id USER_ID`

Route surface is registered in `lib/GPForum/Bootstrap/Routes.pm`: home,
discovery, health, metrics, admin, forum, moderation, notifications, identity,
privacy, attachment download/upload, search, and websocket realtime.

Architecture audit result as of this document:

- `script/architecture-check` rejects DBIx::Class/resultset usage in
  controllers and templates.
- `script/architecture-check` now fails on internal `GPForum::*` dependency
  cycles; current result is no cycles.
- No direct controller persistence access was found.
- Controllers still contain large HTTP orchestration and response helpers:
  `Controller::Forum`, `Controller::Identity`, `Controller::Admin`, and
  `Controller::Moderation` are the main debt. Do not expand them before moving
  shared auth/CSRF/error/redirect helpers into `Web::*`.
- Business rules that must stay out of controllers are already covered by
  service tests for posting, identity, moderation, privacy, attachments,
  outbox, notifications, search, and realtime.

## Runtime Requirements

Minimum:

- Perl `5.38.0` or newer.
- Carton with dependencies locked by `cpanfile.snapshot`.
- PostgreSQL with `pg_trgm` support for search migrations.
- A non-root application user.
- Reverse proxy for TLS/static transfer: nginx or Caddy.
- systemd, rc.d, launchd, or another supervisor for persistent processes.

Recommended production posture:

- PostgreSQL role split: `gpforum_web`, `gpforum_worker`, `gpforum_migrator`.
- `statement_timeout`, `idle_in_transaction_session_timeout`, and migration
  `lock_timeout` configured at role or deployment level.
- `LimitNOFILE=65536` or equivalent OS limit.
- `/metrics` restricted by reverse proxy allowlist or private network, with
  `GPFORUM_METRICS_TOKEN` set for app-level protection.

## Required Environment

Production must set:

- `GPFORUM_ENV=production`
- `GPFORUM_SESSION_SECRET` to a high-entropy secret, not the development default
- `GPFORUM_PUBLIC_BASE_URL`
- `GPFORUM_DATABASE_DSN`
- `GPFORUM_DATABASE_USER`
- `GPFORUM_DATABASE_PASSWORD`
- `GPFORUM_METRICS_TOKEN` for production metrics scrapes unless `/metrics` is
  isolated by a private listener with equivalent network controls
- `GPFORUM_RUNTIME_LISTEN`
- `GPFORUM_LOG_LEVEL=info` or stricter

Optional but production-relevant:

- `GPFORUM_WEB_PROCESSES`
- `GPFORUM_WORKER_PROCESSES`
- `GPFORUM_REALTIME_PROCESSES`
- `GPFORUM_RUNTIME_WORKER_POLICY`
- `GPFORUM_RUNTIME_MAX_WEB_PER_CPU`
- `GPFORUM_RUNTIME_BACKLOG`
- `GPFORUM_RUNTIME_CLIENTS`
- `GPFORUM_RUNTIME_REQUESTS`
- `GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT`
- `GPFORUM_RUNTIME_INACTIVITY_TIMEOUT`
- `GPFORUM_REALTIME_LISTENER_ENABLED`
- `GPFORUM_MINION_ENABLED`
- `GPFORUM_MINION_PG_URL`
- `GPFORUM_LOCAL_CACHE_MAX_ENTRIES`
- `GPFORUM_CATEGORY_CACHE_TTL_SECONDS`

The built-in runtime defaults are the small-production professional profile:
loopback listen behind a reverse proxy, `4` web processes, `2` worker
processes, `1` realtime process, backlog `256`, Hypnotoad clients `250`,
request recycle `1000`, keep-alive `5s`, inactivity timeout `30s`, graceful
timeout `20s`, heartbeat `5s/5s`, upgrade timeout `60s`, realtime listener
enabled, local cache `2048` entries, category cache TTL `60s`, and a
`65536` open-file-descriptor floor. Override these values only with staging or
benchmark evidence for the target host.

## Bootstrap

```sh
script/bootstrap-deps --postgres
carton check
carton exec bin/gpforum-migrate --plan
carton exec bin/gpforum-migrate --apply
carton exec bin/gpforum-admin-bootstrap --user-id USER_ID
```

For local deterministic performance data:

```sh
script/seed-benchmark --profile small
```

## Verification Gates

Run locally before a production candidate:

```sh
carton exec script/perl-syntax-check
script/perltidy-check
script/perlcritic
script/architecture-check
script/query-plan-check
carton exec prove -lr t
script/query-budget --check
script/gpforum-os-preflight --strict --json
```

With a real PostgreSQL evidence database:

```sh
carton exec bin/gpforum-migrate --apply
script/seed-benchmark --profile small
script/query-plan-evidence --check --profile small
script/benchmark-http --configured --check --iterations 20 --warmup 3
carton exec bin/gpforum-platform-check --with-db
```

CI must keep the same gates. If Perl::Critic violations are intentionally
resolved, update `etc/perlcritic-baseline.txt` in the same review; the gate
normalizes line and column drift but still fails on new policy/file/message
violations.

## Database And Migrations

Migrations are ordered SQL files in `migrations/` and are tracked in
`schema_versions` with checksums. From migration `004` onward, application also
records `migration_safety` metadata.

Rules:

- Migrations must be additive or forward-fix unless a reviewed rollback script
  exists.
- Use `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, and
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` where possible.
- Never edit an applied migration in production; create a new forward migration.
- Index coverage must include forum threads/posts, sessions, outbox, dead
  letters, jobs/import/export, notifications, feeds, reports, rate limits, and
  search.
- Query-shape changes must update `script/query-plan-check`,
  `script/query-plan-evidence`, and query-budget docs/tests together.

Rollback stance:

- Code rollback is allowed only to a version compatible with the already
  applied schema.
- Schema rollback is forward-fix by default.
- If a migration breaks production, stop deploy, restore service from previous
  code if compatible, then ship a new corrective migration.

## Worker And Outbox

Outbox guarantees:

- Rows are claimed using PostgreSQL `FOR UPDATE SKIP LOCKED` when available.
- Claim order is deterministic on `next_attempt_at, created_at, outbox_id`.
- Stale `running` locks are claimable after `locked_until`.
- Retry attempts increment `attempt_count` and legacy `attempts`.
- Exhausted messages are marked `cancelled` and copied to `dead_letters`.
- Failure type is classified as `transient`, `permanent`, `serialization`,
  `authorization`, or `transport`.

Worker verification:

```sh
carton exec prove -lr t/13-outbox-dispatcher.t \
  t/16-workers-phase.t \
  t/83-outbox-worker-wiring.t \
  t/84-outbox-concurrent-dispatcher.t \
  t/85-realtime-outbox-multiprocess.t
```

Operational commands:

```sh
carton exec bin/gpforum-outbox-dispatch --once --limit 100
carton exec bin/gpforum-outbox-dispatch --loop --limit 100 --sleep 5
```

## Security Gate

Covered controls:

- Argon2id password hashing.
- Random session token service and server-side session validation.
- Production `Secure`, `HttpOnly`, `SameSite=Lax` session cookies.
- CSRF on state-changing SSR routes.
- Authorization gates for admin, moderation, privacy, attachments, realtime
  channel subscription, and notification writes.
- Input validation in service composers/validators.
- Attachment upload lifecycle, scan status, media processing boundary, and safe
  download filename handling.
- Browser security headers through `Security::BrowserHeaders`.
- PostgreSQL-backed rate limiting with local fallback telemetry.
- No secrets committed for production; development defaults are rejected when
  `GPFORUM_ENV=production`.

Security test gate:

```sh
carton exec prove -lr t/06-identity-web.t \
  t/08-identity-store.t \
  t/48-browser-security.t \
  t/50-security-hardening.t \
  t/55-security-abuse-hardening.t
```

Known residual risk:

- `/metrics` supports app-level token protection through
  `GPFORUM_METRICS_TOKEN`; reverse proxy allowlists or private networking are
  still required before production exposure.
- Controllers still duplicate CSRF/auth/error response helpers, increasing
  drift risk.

## Health, Logs, Metrics

Endpoints:

- `GET /health/live`: process liveness.
- `GET /health/ready`: readiness, including database/resultset availability.
- `GET /health`: summary for operators; keep internal.
- `GET /metrics`: process-local operational snapshot; keep internal. When
  `GPFORUM_METRICS_TOKEN` is configured, scrape with `Authorization: Bearer
  $GPFORUM_METRICS_TOKEN` or `X-GPForum-Metrics-Token`.

Every HTTP response carries `X-Request-ID`. If a safe incoming `X-Request-ID`
header is supplied, GPForum echoes it; otherwise it generates a UUID. DB query
observations include the same correlation id and `duration_ms`.

Minimum metrics currently exposed:

- process pid and uptime;
- runtime and OS preflight;
- realtime connection/subscription/fanout counters;
- rate-limit allowed/blocked/degraded state;
- security telemetry counters;
- DB query counts, duplicate query warnings, query-budget mismatches, request
  duration, and recent request envelopes;
- DB readiness latency;
- outbox pending/failed/retry/dead-letter counts.

Production diagnosis:

```sh
curl -fsS http://127.0.0.1:8080/health/live
curl -fsS http://127.0.0.1:8080/health/ready
curl -fsS -H "Authorization: Bearer $GPFORUM_METRICS_TOKEN" \
  http://127.0.0.1:8080/metrics
journalctl -u gpforum -n 200 --no-pager
journalctl -u gpforum-outbox -n 200 --no-pager
```

## Local Start

```sh
script/bootstrap-deps --postgres
carton exec bin/gpforum-migrate --apply
carton exec morbo bin/gpforum
```

Open `http://127.0.0.1:3000/health/live`.

## Production Start

Using the provided unit examples:

```sh
sudo install -d -o gpforum -g gpforum /srv/gpforum /run/gpforum
sudo systemctl daemon-reload
sudo systemctl enable --now gpforum.service
sudo nginx -t
sudo systemctl reload nginx
```

See:

- `deploy/systemd/gpforum.service`
- `deploy/systemd/gpforum-outbox.service`
- `deploy/systemd/gpforum-unix-socket.service`
- `deploy/nginx/gpforum.conf`
- `deploy/nginx/gpforum-unix-socket.conf`

## Backup And Restore

Before production:

- Schedule `pg_dump` or physical backups according to RPO/RTO.
- Include attachment/object storage under `var/attachments` or the configured
  production storage root.
- Restore into a staging database at least once before launch.
- Run migrations and readiness after restore.

Example logical backup:

```sh
pg_dump --format=custom --file=gpforum.dump "$GPFORUM_DATABASE_DSN"
```

Example restore drill:

```sh
createdb gpforum_restore
pg_restore --dbname=gpforum_restore --clean --if-exists gpforum.dump
GPFORUM_DATABASE_DSN='dbi:Pg:dbname=gpforum_restore;host=127.0.0.1' \
  carton exec bin/gpforum-migrate --plan
```

## Deploy Procedure

1. Build artifact from a commit that passed CI.
2. Install dependencies with `script/bootstrap-deps --postgres`.
3. Run `carton check`.
4. Run `script/gpforum-os-preflight --strict --json`.
5. Backup database and attachment storage.
6. Apply migrations with the migrator role.
7. Start/reload Hypnotoad through systemd.
8. Start/reload outbox worker.
9. Validate `/health/live`, `/health/ready`, and internal `/metrics`.
10. Run a smoke route set: `/`, `/categories`, `/health/ready`, `/metrics`.
11. Watch logs and outbox/dead-letter counts.

## Performance Baseline

Do not tune without measurement. Required evidence:

- cold start: `script/bench-hypnotoad --check`;
- request latency: `script/benchmark-http --configured --check`;
- DB query shape and latency: `script/query-plan-evidence --check`;
- worker throughput: `script/bench-outbox-dispatcher`;
- query counts: benchmark-only DB query headers and query budget catalog.

Current numbers and methodology live in:

- `docs/PERFORMANCE_BASELINE.md`
- `docs/PERFORMANCE_EVIDENCE.md`
- `docs/DB_PERFORMANCE.md`

## Production Verdict Rule

GPForum is production-ready only when all are true:

- CI gates pass without local-only assumptions.
- Migrations have been applied to staging from an empty and restored database.
- Backups and restores have been drilled.
- `/metrics` is not publicly exposed and token protection is enabled when the
  endpoint shares the application listener.
- Worker retry/dead-letter handling has been observed in staging.
- Query-plan evidence is green on a representative dataset.
- Rollback/forward-fix steps are rehearsed with the exact systemd/nginx shape.
