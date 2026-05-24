# GPForum Performance Baseline

Baseline date: 2026-05-24.

This is commit 2 for GPForum consolidation: profiling and benchmark harness.
It intentionally measures before optimizing. No Redis, OpenSearch, external load
tool, or new infrastructure is required.

## Environment

| Field | Value |
| --- | --- |
| Host OS | Darwin 25.5.0 arm64 |
| GPForum OS profile | darwin, kqueue |
| Reported CPU count | 1 |
| Perl | v5.42.2 darwin-thread-multi-2level |
| Benchmark mode used locally | fixture services and configured PostgreSQL through `Test::Mojo` |
| Cache posture | one warmup request per route; fixture/local warm cache is declared |
| PostgreSQL local status | PostgreSQL 18.4 from Postgres.app verified through an isolated evidence cluster |

## Harness Commands

Seed a PostgreSQL database after migrations:

```sh
script/bootstrap-deps --postgres
carton exec bin/gpforum-migrate --apply
script/seed-performance-data
```

Run the canonical local HTTP benchmark routes:

```sh
script/benchmark-http --fixture --iterations 5 --warmup 1
```

Run the same route set against configured PostgreSQL state:

```sh
script/benchmark-http --configured --iterations 20 --warmup 3
```

Profile a route with Devel::NYTProf:

```sh
script/profile-nytprof --route /t/thread-1 --fixture --iterations 3 --warmup 1
carton exec nytprofcsv -f var/profile/route-nytprof.out.<pid> --out var/profile/route-nytprof.csv
```

## Dataset

`script/seed-performance-data` creates an idempotent PostgreSQL seed:

| Entity | Default count |
| --- | ---: |
| users | 5 |
| categories | 3 |
| threads | 12 |
| posts per thread | 8 |
| posts | 96 |
| sessions | 5 |
| read-state rows | 15 |
| notifications | 15 |

The production evidence gate extends this seed through
`script/seed-benchmark --profile small|medium|hot-thread`. The default `small`
profile preserves the counts above and additionally seeds roles, permissions,
role bindings, bookmarks, subscriptions, feed items, reports, and moderation
actions.

Deterministic seeded routes:

| Route | Path |
| --- | --- |
| category | `/c/018f1001-0001-7000-8000-000000000001` |
| thread | `/t/018f1004-0001-7000-8000-000000000001` |
| search | `/search?q=performance` |
| autocomplete | `/search/autocomplete?q=per` |

Local dry-run command:

```sh
script/seed-performance-data --dry-run --json
```

Local real seed now passes against a PostgreSQL 18.4 Postgres.app evidence
cluster on `127.0.0.1:55432`.

## Fixture HTTP Baseline

Command:

```sh
script/benchmark-http --fixture --iterations 5 --warmup 1
```

Process memory reported by `ps`: `memory_rss_kb=1312`.

| Endpoint | Status | p50 ms | p95 ms | p99 ms | req/s | Query budget |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `/` | 200 | 2.150 | 2.329 | 2.329 | 460.275 | home:5 |
| `/categories` | 200 | 1.049 | 1.059 | 1.059 | 914.071 | categories:3 |
| `/c/category-1` | 200 | 2.056 | 2.208 | 2.208 | 466.282 | category_threads:5 |
| `/t/thread-1` | 200 | 1.436 | 1.518 | 1.518 | 673.502 | thread_view:8 |
| `/search?q=performance` | 200 | 1.214 | 1.249 | 1.249 | 771.494 | search:2 |
| `/search/autocomplete?q=per` | 200 | 1.563 | 1.737 | 1.737 | 589.966 | search_autocomplete:2 |
| `/health` | 200 | 1.144 | 1.178 | 1.178 | 817.380 | none |
| `/health/ready` | 503 | 3.612 | 3.849 | 3.849 | 272.343 | none |
| `/metrics` | 200 | 0.677 | 0.736 | 0.736 | 1346.572 | none |

`/health/ready` returns `503` in fixture mode because no configured PostgreSQL
connection is available. That is a readiness signal, not a benchmark harness
failure.

Query counts above are the current release-gate query-budget contracts. Runtime
observed DB query counts require the configured PostgreSQL run, because fixture
mode deliberately avoids database I/O.

## NYTProf Baseline

Profile command:

```sh
script/profile-nytprof --route /t/thread-1 --fixture --iterations 3 --warmup 1
```

Top measured line-level hotspots from `nytprofcsv`:

| Time s | File | Observed hotspot |
| ---: | --- | --- |
| 0.016567 | `Class-C3-Componentised.pm` | dynamic `require` during class loading |
| 0.015397 | `Class-Accessor-Grouped.pm` | generated accessor eval |
| 0.009063 | generated accessor eval | generated accessor body |
| 0.006279 | `GPForum::Command::Benchmark` | RSS measurement via `ps` pipe |
| 0.004134 | `DBIx::Class::ResultSet` | resultset fallback load path |

Observed bottleneck pattern: this local profile is dominated by startup,
module loading, DBIx::Class result graph registration, generated accessors, and
benchmark harness RSS sampling. Route rendering is not yet the dominant cost in
fixture mode. That is a measurement result, not an optimization instruction.

## First 5 Real Hotspots

1. Startup class loading through `Class::C3::Componentised`.
2. Generated accessor creation through `Class::Accessor::Grouped`.
3. Generated accessor execution from DBIx::Class/Mojo bootstrapping.
4. Benchmark harness memory sampling through `ps`.
5. DBIx::Class resultset/result-source load path during app startup.

## Configured PostgreSQL Baseline

Command:

```sh
script/benchmark-http --configured --check --iterations 20 --warmup 3
```

Environment: PostgreSQL 18.4 from Postgres.app, isolated evidence cluster,
`small` seed, `GPFORUM_WEB_PROCESSES=1`.

| Endpoint | Status | p50 ms | p95 ms | p99 ms | req/s | Query budget |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `/` | 200 | 2.820 | 4.003 | 4.003 | 322.908 | home:5 |
| `/categories` | 200 | 1.223 | 1.641 | 1.641 | 754.690 | categories:3 |
| `/c/018f1001-0001-7000-8000-000000000001` | 200 | 2.310 | 2.949 | 2.949 | 408.205 | category_threads:5 |
| `/t/018f1004-0001-7000-8000-000000000001` | 200 | 4.329 | 5.105 | 5.105 | 221.998 | thread_view:8 |
| `/search?q=performance` | 200 | 1.852 | 2.702 | 2.702 | 499.227 | search:2 |
| `/search/autocomplete?q=per` | 200 | 1.860 | 2.255 | 2.255 | 516.235 | search_autocomplete:2 |
| `/health` | 200 | 1.172 | 1.388 | 1.388 | 812.283 | none |
| `/health/ready` | 200 | 3.178 | 3.728 | 3.728 | 301.514 | none |
| `/metrics` | 200 | 3.135 | 3.653 | 3.653 | 312.418 | none |

## Current Limits

* Fixture mode measures route/rendering shape and framework overhead; it does
  not measure PostgreSQL latency.
* Query count values in the fixture table are budget contracts, not observed DB
  counters.
* No optimization has been performed from these numbers yet.
* Thresholded benchmark checks and DB-backed query plan evidence are documented
  in `docs/PERFORMANCE_EVIDENCE.md`.

## Acceptance

This baseline is acceptable only as a measurement starting point. Any later
performance patch must cite a benchmark or NYTProf profile generated by these
scripts and must keep query budgets explicit.
