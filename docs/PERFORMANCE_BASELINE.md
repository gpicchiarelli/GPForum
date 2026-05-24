# GPForum Performance Baseline

GPForum performance work must begin with measurement. The current baseline
harness is intentionally local and deterministic: it runs Mojolicious through
`Test::Mojo`, installs explicit benchmark fixture services, and reports latency
percentiles without requiring Redis, OpenSearch, wrk, k6, or a preloaded
production database.

## Commands

Run the default hot-route benchmark:

```sh
script/bench-http
```

Run a smaller smoke benchmark:

```sh
script/bench-http --iterations 5 --warmup 1 --route /health/live --route /t/thread-1
```

Emit JSON for later comparison:

```sh
script/bench-http --json --iterations 20 --warmup 3 > var/profile/http-benchmark.json
```

Profile one route with NYTProf:

```sh
script/profile-route /t/thread-1
```

## Report Fields

Each route reports:

* `requests`
* `req_per_sec`
* `p50_ms`
* `p95_ms`
* `p99_ms`
* `max_ms`
* `statuses`

The process header reports `pid` and `memory_rss_kb` when the local `ps`
implementation exposes RSS.

## Initial Conservative Thresholds

These are not product promises. They are initial regression alarms for fixture
benchmarks on a developer machine:

| Route class | Fixture p95 target |
| --- | --- |
| health/live | <= 20 ms |
| metrics | <= 50 ms |
| home/category/thread/search/feed/login | <= 100 ms |

Real PostgreSQL-backed benchmarks must be added after the seed database command
exists. Fixture results prove route/rendering shape; they do not replace query
plan analysis or production load testing.
