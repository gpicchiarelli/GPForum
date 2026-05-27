# GPForum Deployment Evidence

This document records the repeatable evidence gate for running GPForum under a
deployment-like Mojolicious runtime: Hypnotoad prefork, PostgreSQL authoritative
storage, and the existing query-budget observer.

The goal is not to claim production capacity. The goal is to prove that the MVP
forum paths keep the same architectural guarantees when they leave the
in-process `Test::Mojo` harness and run through a persistent multi-worker server.

## Gate

Reduced CI gate:

```sh
script/bench-hypnotoad --check --profile small --workers 2 \
  --iterations 2 --warmup 1 --no-compare \
  --route /categories --route /health/ready
```

Local deployment evidence gate:

```sh
script/bench-hypnotoad --check --profile small --workers 2 \
  --iterations 20 --warmup 3 \
  --route /categories \
  --route /t/018f1004-0001-7000-8000-000000000001 \
  --route /search?q=performance \
  --route /health/ready \
  --route /metrics
```

Optional seeded run:

```sh
script/bench-hypnotoad --seed --check --profile medium --workers 2 \
  --iterations 20 --warmup 3
```

The script requires a configured PostgreSQL database:

```sh
export GPFORUM_DATABASE_DSN='dbi:Pg:dbname=gpforum_visible_evidence;host=127.0.0.1;port=5432'
export GPFORUM_DATABASE_USER='gpicchiarelli'
export GPFORUM_DATABASE_PASSWORD=''
```

## Runtime Methodology

`script/bench-hypnotoad`:

* creates a temporary Hypnotoad app file that returns a `GPForum` application
  object;
* selects an available local TCP port automatically unless `--port` is passed;
* sets benchmark-only runtime environment for listen address, PID file,
  worker count, backlog, clients, accepts, keep-alive and graceful timeout;
* enables benchmark-only DB query headers with
  `GPFORUM_BENCHMARK_QUERY_HEADERS=1`;
* waits for `/health/live`;
* runs warmup requests separately from measured iterations;
* records p50/p95/p99, req/s, status codes, DB query count, duplicate query
  count and query-budget status;
* records OS runtime evidence, including actual Mojolicious reactor class,
  socket option probes, PostgreSQL settings and temporary filesystem mount;
* optionally compares each route with the existing configured in-process
  benchmark;
* stops Hypnotoad with `hypnotoad -s` and then falls back to process-group
  termination if necessary.

The temporary runtime is isolated from normal deployment files. It does not
modify sysctl, does not require root, does not require Redis, and does not
require a reverse proxy.

## OS Runtime Evidence

The Hypnotoad report now includes `runtime.os_evidence`.

Current macOS evidence classifies:

| Capability | State |
| --- | --- |
| Hypnotoad prefork | active |
| `reuse=1` listen URL | active |
| `SO_REUSEPORT` socket probe | active |
| `SO_KEEPALIVE` socket probe | active |
| `TCP_NODELAY` socket probe | active |
| declared event backend | `kqueue` |
| actual Mojolicious reactor | `Mojo::Reactor::Poll` |
| sendfile/X-Sendfile | configurable, not materialized |
| PostgreSQL tuning | settings observed, not applied by GPForum |
| temp filesystem | APFS `/System/Volumes/Data` on this macOS host |

The event backend mismatch is intentional evidence, not hidden failure:
GPForum's Darwin profile declares the desired `kqueue` posture, but the current
local Perl runtime does not have a native kqueue reactor module installed.

## Worker Scaling Evidence

`script/bench-hypnotoad-scaling` repeats the Hypnotoad benchmark across a worker
set, usually `2,4,8`, using the real forum/search route surface. It reuses the
same benchmark implementation as `script/bench-hypnotoad`, so query headers,
duplicate-query detection, OS runtime evidence and route thresholds remain
consistent.

Local scaling smoke:

```sh
script/bench-hypnotoad-scaling --seed --check --profile small \
  --worker-set 2,4,8 --iterations 2 --warmup 1 \
  --route /categories \
  --route /t/018f1004-0001-7000-8000-000000000001 \
  --route '/search?q=performance'
```

The command is not a CI default because it starts multiple prefork runtimes.
Use it before changing worker counts, reactor dependencies, reverse proxy
settings or socket policy.

Latest local Postgres.app scaling smoke, using a temporary migrated database
and deterministic `small` seed:

| Workers | Route | p95 ms | Req/s | Max DB queries | Duplicate queries | Budget |
| ---: | --- | ---: | ---: | ---: | ---: | --- |
| 2 | `/categories` | 1.460 | 587.026 | 0 | 0 | ok |
| 2 | `/t/018f1004-0001-7000-8000-000000000001` | 3.688 | 241.371 | 2 | 0 | ok |
| 2 | `/search?q=performance` | 2.122 | 437.522 | 1 | 0 | ok |
| 4 | `/categories` | 1.972 | 471.482 | 0 | 0 | ok |
| 4 | `/t/018f1004-0001-7000-8000-000000000001` | 4.140 | 234.136 | 2 | 0 | ok |
| 4 | `/search?q=performance` | 2.522 | 372.496 | 1 | 0 | ok |
| 8 | `/categories` | 1.516 | 606.245 | 0 | 0 | ok |
| 8 | `/t/018f1004-0001-7000-8000-000000000001` | 3.398 | 224.186 | 2 | 0 | ok |
| 8 | `/search?q=performance` | 2.005 | 461.267 | 1 | 0 | ok |

All three worker counts used `Mojo::Reactor::Poll` on this machine. The run is
too small to claim saturation behavior; it proves that the real forum/search
routes stay budget-clean under prefork worker count changes.

## Current Local Evidence

Environment:

| Field | Value |
| --- | --- |
| PostgreSQL | Postgres.app, PostgreSQL 18.4 |
| DSN | `dbi:Pg:dbname=gpforum_visible_evidence;host=127.0.0.1;port=5432` |
| Perl | v5.42.2 |
| Mojolicious | 9.45 |
| Dataset | deterministic `small` profile |
| Workers | 2 |
| Warmup | 1 |
| Iterations | 3 measured requests per route |

Observed local run:

```sh
script/bench-hypnotoad --check --profile small --workers 2 \
  --iterations 3 --warmup 1 \
  --route /categories \
  --route /t/018f1004-0001-7000-8000-000000000001 \
  --route /search?q=performance \
  --route /health/ready
```

| Route | Hypnotoad p95 ms | In-process p95 ms | Req/s | Max DB queries | Duplicate queries | Budget |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `/categories` | 1.317 | 1.428 | 670.695 | 0 | 0 | ok |
| `/t/018f1004-0001-7000-8000-000000000001` | 3.612 | 3.954 | 260.489 | 2 | 0 | ok |
| `/search?q=performance` | 2.111 | 2.048 | 472.296 | 1 | 0 | ok |
| `/health/ready` | 4.030 | 4.020 | 242.993 | 5 | 0 | none |
| `/metrics` | 4.132 | not captured in comparison sample | 237.566 | 3 | 0 | none |

The `/categories` route may report zero DB queries after warmup because the
local disposable cache is warm. This is acceptable for the benchmark as long as
the route remains permission-safe and the query budget remains observed.

## Correctness Assertions

The Hypnotoad gate verifies:

* all measured routes return 2xx/3xx responses;
* budgeted routes do not exceed their DB query budget;
* budgeted routes do not emit duplicate SQL fingerprints;
* comparison against in-process mode stays within conservative regression
  tolerance when comparison is enabled;
* the server starts, answers `/health/live`, and shuts down cleanly.

Multi-worker correctness remains grounded in existing service tests for
PostgreSQL-backed rate limiting, server-side session expiry, CSRF, authorization
denial, disposable cache behavior, and realtime degradation. The Hypnotoad gate
proves those paths can run in a real prefork runtime; it does not replace the
deeper workflow tests.

## Reverse Proxy Status

Reverse proxy evidence is optional and not a CI requirement. Deployment examples
exist for nginx and Caddy in `deploy/`. The next external load-test step should
place nginx or Caddy in front of the same Hypnotoad harness and compare:

* connection reuse;
* static transfer behavior;
* WebSocket upgrade behavior;
* request buffering;
* TLS and compression overhead.

## Limitations

* The gate is a smoke evidence benchmark, not a saturation benchmark.
* Short local runs are intentionally conservative and repeatable.
* It does not measure TLS, compression, or reverse-proxy buffering.
* It does not prove long-running RSS stability.
* It does not make process-local realtime authoritative.
