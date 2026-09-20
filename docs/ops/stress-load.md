# Stress / load harness (100 / 500 / 1000 concurrency)

Operator-runnable HTTP stress harness aimed at **100 / 500 / 1000 concurrent
request slots** (equivalent concurrency targets for private-beta capacity
evidence). It extends the existing Hypnotoad/benchmark route set and reporting
style rather than introducing a second load-tool stack.

Passing a profile does **not** mean private beta is ready. Record JSON/human
evidence on representative hardware; full staging deploy remains separate.

## What this covers

| Profile | Concurrency | Default requests/slot | Total requests |
| --- | ---: | ---: | ---: |
| `smoke` | 4 | 5 | 20 |
| `100` | 100 | 10 | 1 000 |
| `500` | 500 | 10 | 5 000 |
| `1000` | 1 000 | 10 | 10 000 |

Default routes match the seeded Hypnotoad bench hot paths (`/`, `/categories`,
seeded category/thread, search, `/health/live`, `/health/ready`).

Evidence includes wall time, completed/errors, error rate, peak in-flight,
req/s, and p50/p95/p99/max latency.

## What this does not cover

- Starting Hypnotoad for you (point `--base-url` at a running instance).
- Attachment deploy drills, dump/restore, or nginx/systemd rehearsal.
- Claiming multicore saturation solely from a laptop smoke run.

Related sequential benches remain:

- `script/bench-hypnotoad` / `script/bench-hypnotoad-scaling`
- `script/benchmark-http` / `bin/gpforum-benchmark`
- `script/bench-outbox-dispatcher`

## Prerequisites

1. App dependencies: `make install-deps-postgres` (or existing Carton local lib).
2. Migrated PostgreSQL for the **server** process:

```sh
export GPFORUM_DATABASE_DSN='dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432'
export GPFORUM_DATABASE_USER='…'
export GPFORUM_DATABASE_PASSWORD='…'
carton exec bin/gpforum-migrate --apply
script/seed-performance-data --profile small
```

3. Running Hypnotoad (or reverse proxy) serving that database, for example:

```sh
# operator-managed process; ports/workers per docs/DEPLOYMENT.md
script/bench-hypnotoad --seed --profile small --workers 2 ...
# or a long-lived Hypnotoad started from the normal deploy unit
```

4. Client only needs network reachability to `--base-url` (optional
   `GPFORUM_STRESS_BASE_URL`).

## Commands

Dry-run plan (safe; no HTTP; fine for CI unit tests):

```sh
script/stress-load --dry-run --profile 100 --human
script/gpforum-carton exec bin/gpforum-stress-load --dry-run --profile 1000 --json
```

Local smoke against a live base URL:

```sh
script/stress-load --profile smoke \
  --base-url http://127.0.0.1:8080 \
  --human
```

Capacity profiles:

```sh
script/stress-load --profile 100 --base-url https://forum.example --check --json
script/stress-load --profile 500 --base-url https://forum.example --check --json
script/stress-load --profile 1000 --base-url https://forum.example --check --json
```

Concurrency knobs without changing the named profile:

```sh
script/stress-load --profile 100 --concurrency 120 \
  --requests-per-client 20 \
  --base-url http://127.0.0.1:8080 \
  --route /categories --route /health/live \
  --human
```

Optional Make target (**not** part of `make check` / default CI):

```sh
make stress-load PROFILE=smoke BASE_URL=http://127.0.0.1:8080
# defaults: PROFILE=smoke, FORMAT=human; BASE_URL required for a live run
make stress-load-dry   # dry-run only
```

## Evidence shape

JSON includes at least:

- `status`: `dry-run`, `ok`/`pass` (with `--check`), `fail`, or `ok` without check
- `plan.profile`, `plan.concurrency`, `plan.total_requests`, `plan.routes`
- `prerequisites` reminding operators about DSN, seed, and running app
- live runs: `wall_seconds`, `completed`, `errors`, `error_rate_pct`,
  `peak_inflight`, `req_per_sec`, `p50_ms` / `p95_ms` / `p99_ms` / `max_ms`,
  `status_codes`
- `residual_gaps` stating this is not a private-beta gate by itself

With `--check`, exit status is non-zero when `error_rate_pct` exceeds
`--max-error-rate` (default 1%) or `p95_ms` exceeds `--p95-limit-ms`
(default 2000).

## Recording a run

1. Run the intended profile on staging-like hardware with a seeded DB and live
   Hypnotoad.
2. Paste JSON (or `--human` lines) into ops notes for that commit.
3. Keep `script/bench-hypnotoad-scaling` worker evidence alongside this external
   concurrency evidence.
4. Do not mark private beta ready from a smoke profile alone.

## Rate limit note for single-IP capacity runs

Anonymous forum reads use `forum_retrieval` at **60 requests / 60 seconds** per
client address by default. A single load-generator IP will therefore see HTTP
`429` under profile `100+` unless the operator raises the ceiling for the
capacity window:

```sh
export GPFORUM_FORUM_READ_RATE_LIMIT=100000   # Hypnotoad/process env
```

Unset the variable (or restart without it) to restore the product default.
Health routes are not subject to that forum retrieval limit; the default
stress route set includes seeded forum pages, so capacity profiles should set
the override when measuring stack throughput rather than abuse-protection
behaviour.

Also run `script/query-budget --sync` after migrate so `/health/ready` returns
`200` (an empty budget catalog yields `503` and inflates error rate).

## Prep evidence archive pointer (2026-09-20)

Live Cloud Agent Hypnotoad verify + stress profile `100` JSON:
[`docs/ops/evidence/2026-09-20-cloud-agent-live/`](../evidence/2026-09-20-cloud-agent-live/).
Partial prep / drills-only archives remain under
[`docs/ops/evidence/2026-09-20-cloud-agent/`](../evidence/2026-09-20-cloud-agent/)
and
[`docs/ops/evidence/2026-09-20-cloud-agent-drills/`](../evidence/2026-09-20-cloud-agent-drills/).
**PRIVATE BETA NOT YET.** Earlier completed stress appendix rows below are
unchanged.

## Live evidence appendix (Cloud Agent VM, 2026-09-20)

Host: Linux 4 vCPU / ~15 GiB RAM, PostgreSQL 16, system Perl 5.38, Hypnotoad
`GPFORUM_WEB_PROCESSES=4`, seed profile `medium`, base
`http://127.0.0.1:8080`, commit base `1d16c69`. Harness:
`script/stress-load --check --json`. Capacity rows used
`GPFORUM_FORUM_READ_RATE_LIMIT=100000` unless noted.

| Profile | Status | Peak in-flight | Completed | Errors | Err % | req/s | p50 ms | p95 ms | p99 ms | max ms | Wall s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `smoke` | pass | 4 | 20 | 0 | 0.000 | 137.344 | 26.845 | 48.809 | 48.809 | 95.230 | 0.146 |
| `100` (elevated read limit) | pass | 100 | 1 000 | 0 | 0.000 | 572.060 | 89.792 | 604.892 | 713.722 | 865.432 | 1.748 |
| `100` (default 60/60s limit) | fail | 100 | 1 000 | 83 | 8.300 | 538.634 | — | 458.798 | — | — | — |
| `500` (elevated) | pass | 500 | 5 000 | 0 | 0.000 | 587.128 | 803.277 | 1112.640 | 1265.341 | 1512.191 | 8.516 |
| `1000` (elevated) | fail\* | 1000 | 10 000 | 0 | 0.000 | 530.567 | 1671.467 | 4738.720 | 4878.393 | 8471.037 | 18.848 |

\*Profile `1000` sustained peak in-flight **1000** with **zero** HTTP errors on
this VM; `--check` failed solely because p95 (4738 ms) exceeded the default
`--p95-limit-ms 2000`. Treat as **attempted / latency residual** on 4 vCPU,
not as an inability to open 1000 concurrent slots.

Default-limit `100` status codes included `429` (83) + `200` (917): the
product abuse ceiling, not a harness failure.

### Harness fix under live load

Mojo::UserAgent sets `$tx->error` for HTTP 4xx/5xx as well as transport
failures. The harness now prefers `$tx->res->code` when present so evidence
records `503`/`429` instead of a bare `error` bucket. Live runs without
`--check` report `status=ok` (with `--check`: `pass`/`fail`).

### Residuals

- Private-beta / staging multicore gate still open (representative staging
  host, TLS front door, SMTP, deploy target).
- Profile `1000` p95 under default `--check` thresholds on this 4-vCPU VM.
- Single-IP default rate limit remains the correct production behaviour;
  capacity evidence requires an explicit `GPFORUM_FORUM_READ_RATE_LIMIT`.

## Tuned re-run (Cloud Agent VM, 2026-09-20, workers=8)

Same host class (Linux 4 vCPU / ~15 GiB RAM, PostgreSQL 16, system Perl 5.38,
seed `medium`, `GPFORUM_FORUM_READ_RATE_LIMIT=100000`, base
`http://127.0.0.1:8080`), but Hypnotoad restarted with
`GPFORUM_WEB_PROCESSES=8` and `GPFORUM_RUNTIME_WORKER_POLICY=configured`
(eight live workers confirmed). Commit base `603f0c7` plus this branch’s
deploy-drill nginx `-t` fixes. Harness:
`script/stress-load --profile 1000 --check --json`.

| Profile | Workers | Status | Peak | Completed | Errors | Err % | req/s | p50 ms | p95 ms | p99 ms | max ms | Wall s |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `1000` (elevated) | 8 | fail\* | 1000 | 10 000 | 0 | 0.000 | 589.564 | 1382.150 | 3495.282 | 4290.943 | 4522.971 | 16.962 |
| `1000` (elevated, probe) | 16 | fail | 1000 | 10 000 | 0 | 0.000 | 544.596 | 607.802 | 5163.724 | 5352.445 | 5586.727 | 18.362 |

\*Still fails default `--p95-limit-ms 2000` only. Versus the earlier 4-worker
row (p95 4739 ms / ~531 req/s), **8 workers** improved throughput and p95 on
this VM; **16 workers** raised p95 again (oversubscription on 4 vCPU). Peak
in-flight **1000** and zero HTTP errors held in both tuned runs. Residual:
default p95 gate on larger/staging hardware remains open.
