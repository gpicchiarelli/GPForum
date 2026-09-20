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
