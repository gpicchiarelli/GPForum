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
| Benchmark mode used locally | fixture services through `Test::Mojo` |
| Cache posture | one warmup request per route; fixture/local warm cache is declared |
| PostgreSQL local status | optional `DBD::Pg` is not installed in this Carton tree |

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

Deterministic seeded routes:

| Route | Path |
| --- | --- |
| category | `/c/018f1001-0001-7000-8000-000000000001` |
| thread | `/t/018f1004-0001-7000-8000-000000000001` |
| search | `/search?q=performance` |

Local dry-run command:

```sh
script/seed-performance-data --dry-run --json
```

Local real seed attempt failed clearly because `DBD::Pg` is not installed. This
is expected on the current workstation until `script/bootstrap-deps --postgres`
is run and PostgreSQL is reachable.

## Fixture HTTP Baseline

Command:

```sh
script/benchmark-http --fixture --iterations 5 --warmup 1
```

Process memory reported by `ps`: `memory_rss_kb=1312`.

| Endpoint | Status | p50 ms | p95 ms | p99 ms | req/s | Query budget |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `/` | 200 | 2.172 | 2.255 | 2.255 | 462.784 | home:5 |
| `/categories` | 200 | 1.034 | 1.121 | 1.121 | 935.268 | categories:3 |
| `/c/category-1` | 200 | 2.070 | 2.199 | 2.199 | 472.768 | category_threads:5 |
| `/t/thread-1` | 200 | 1.448 | 1.584 | 1.584 | 647.349 | thread_view:8 |
| `/search?q=performance` | 200 | 1.303 | 1.343 | 1.343 | 781.965 | search:2 |
| `/health` | 200 | 1.012 | 1.139 | 1.139 | 934.227 | none |
| `/health/ready` | 503 | 3.420 | 3.572 | 3.572 | 288.884 | none |
| `/metrics` | 200 | 0.538 | 0.547 | 0.547 | 1766.171 | none |

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

## Current Limits

* PostgreSQL-backed benchmark execution is implemented but not run locally
  because optional `DBD::Pg` is absent.
* Fixture mode measures route/rendering shape and framework overhead; it does
  not measure PostgreSQL latency.
* Query count values in the fixture table are budget contracts, not observed DB
  counters.
* No optimization has been performed from these numbers yet.

## Acceptance

This baseline is acceptable only as a measurement starting point. Any later
performance patch must cite a benchmark or NYTProf profile generated by these
scripts and must keep query budgets explicit.
