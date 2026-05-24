# GPForum Production Evidence Gate

Evidence date: 2026-05-24.

This document records the current production-evidence gate. It does not add
user features. It makes the existing MVP forum surface measurable against a
deterministic PostgreSQL dataset, static hot-path query rules, DB-backed
`EXPLAIN` checks, and conservative HTTP latency thresholds.

## Evidence Dataset

The canonical deterministic seed command is:

```sh
script/seed-benchmark --profile small
```

The legacy command remains supported:

```sh
script/seed-performance-data --profile small
```

Profiles:

| Profile | Users | Categories | Threads | Posts/thread | Purpose |
| --- | ---: | ---: | ---: | ---: | --- |
| `small` | 5 | 3 | 12 | 8 | CI smoke and quick local checks |
| `medium` | 25 | 8 | 120 | 15 | local PostgreSQL hot-path evidence |
| `hot-thread` | 10 | 3 | 30 | 120 | long-thread pagination and thread view pressure |

Seeded boundaries now include users, roles, permissions, role bindings,
sessions, categories, threads, posts, post bodies, revisions, counters,
search documents, read-state rows, bookmarks, subscriptions, notifications,
feed items, reports, and moderation actions. IDs are deterministic UUIDv7-like
fixtures so the same hot routes can be benchmarked repeatedly.

Deterministic routes:

| Route | Path |
| --- | --- |
| home | `/` |
| categories | `/categories` |
| category | `/c/018f1001-0001-7000-8000-000000000001` |
| thread | `/t/018f1004-0001-7000-8000-000000000001` |
| search | `/search?q=performance` |
| autocomplete | `/search/autocomplete?q=per` |
| health ready | `/health/ready` |
| metrics | `/metrics` |

## Query Plan Gate

Static query topology remains enforced by:

```sh
script/query-plan-check
```

It verifies required hot-path indexes and rejects `OFFSET` in Perl/templates. If
`GPFORUM_DATABASE_DSN` is present, the same command also runs DB-backed query
plan evidence. This makes `script/query-plan-check` a static gate on developer
machines and a PostgreSQL `EXPLAIN` gate in configured CI/runtime evidence
environments.

The static gate now requires `idx_notification_inbox_recipient_created`,
because the existing notification inbox reader orders by `(recipient_user_id,
created_at DESC, notification_id DESC)`.

DB-backed evidence is run with:

```sh
script/query-plan-evidence --check
```

It executes `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for:

| Endpoint | Query label |
| --- | --- |
| home | `threads_public_activity` |
| categories | `categories_space_position` |
| category_threads | `threads_category_activity_visible_locked` |
| thread_view | `posts_visible_thread_position` |
| search | `search_documents_vector` |
| autocomplete | `search_documents_title_trgm` |
| feed | `user_feed_items_user_created` |
| notifications | `notification_inbox_recipient_created` |
| moderation_queue | `reports_queue` |
| health_ready | `readiness_regclass` |
| metrics | `outbox_ready` |

Failure rules are intentionally conservative:

| Risk | Rule |
| --- | --- |
| Sequential scan | fail above 100 estimated/actual rows unless explicitly justified |
| Sort | fail above 1,000 estimated/actual rows |
| Nested loop | fail above 5,000 estimated/actual rows |
| Pagination | fail on SQL page-skipping in hot queries |

Local DB-backed result on this workstation: passing against PostgreSQL 18.4
from Postgres.app, using an isolated evidence cluster on `127.0.0.1:55432`,
the deterministic `small` seed, and `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.

```text
query-plan-check status=ok indexes=23 offset_violations=0 db_evidence=ok
query_plan_evidence status=ok mode=postgres analyze=1
endpoints=11 violations=none warnings=none
```

Dry-run evidence:

```text
query_plan_evidence status=ok mode=dry-run analyze=1
```

## HTTP Benchmark Gate

Fixture benchmark with thresholds:

```sh
script/benchmark-http --fixture --check --iterations 5 --warmup 1
```

The convenience wrapper for the same thresholded hot-path fixture gate is:

```sh
script/bench-hotpaths
```

Saved baseline regression checks are supported with:

```sh
script/benchmark-http --configured --json --write-baseline /tmp/gpforum-benchmark-baseline.json
script/benchmark-http --configured --check --baseline /tmp/gpforum-benchmark-baseline.json
```

`--baseline` compares p95, p99 and req/s route-by-route. The default regression
tolerance is `0.25` (25%); it can be changed with `--regression-tolerance`.
Routes missing from the saved baseline fail the check so benchmark coverage
does not shrink silently. Baseline comparison is optional so ad-hoc runs still
work without a saved historical file.

Latest local fixture result:

| Endpoint | Status | p50 ms | p95 ms | p99 ms | req/s | Budget |
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

`/health/ready` returns `503` in fixture mode because PostgreSQL is not
configured in that benchmark mode. This is expected and does not mean the
threshold gate failed.

Configured PostgreSQL smoke:

```sh
script/bootstrap-deps --postgres
carton exec bin/gpforum-migrate --apply
script/seed-benchmark --profile small
script/benchmark-http --configured --check --iterations 20 --warmup 3
```

Latest configured PostgreSQL result, with PostgreSQL 18.4 from Postgres.app,
isolated evidence cluster, `small` seed, and `GPFORUM_WEB_PROCESSES=1`:

| Endpoint | Status | p50 ms | p95 ms | p99 ms | req/s | Budget |
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

Thresholds are deliberately loose release gates, not performance promises:

| Endpoint class | p95 limit | p99 limit | Minimum req/s |
| --- | ---: | ---: | ---: |
| home | 750 ms | 1500 ms | 1 |
| categories | 500 ms | 1000 ms | 1 |
| category/thread/search/autocomplete | 1000 ms | 2000 ms | 1 |
| health/metrics/default | 1000 ms | 2000 ms | 1 |

## Security Evidence Added

Negative web tests now cover:

* expired session cookie cannot read protected notification inbox;
* user with a moderator-looking identity but without permission cannot read
  suspension queues or suspend users;
* public Atom feed, sitemap, search, autocomplete, profile, notification,
  category and thread responses do not leak hidden fixture content.

Existing security tests already cover missing CSRF, anonymous write routes,
normal user denial on admin/moderation, non-enumerative identity failures, and
suspended-user participation denial.

## CI Gate

The CI pipeline now performs:

```sh
script/benchmark-http --fixture --check --iterations 2 --warmup 1 \
  --route /health/live --route /categories
carton exec bin/gpforum-migrate --apply
script/seed-benchmark --profile small
script/query-plan-evidence --check
script/benchmark-http --configured --check --iterations 3 --warmup 1 \
  --route /categories --route /health/ready
```

This keeps the evidence gate small enough for CI while proving that migrations,
seed data, DB plans, and configured HTTP paths work together.

## Current Limits

* Query count values in fixture HTTP output are release-budget contracts, not
  observed DB query counters.
* DB-backed query-plan evidence detects plan-shape risks; it is not a full
  production load test.
* The first serious PostgreSQL evidence run should use `--profile medium`, then
  repeat with `--profile hot-thread` before tuning thread view further.

## Next Production Evidence Steps

1. Run `script/query-plan-evidence --check --json` against a seeded medium
   PostgreSQL database and archive the JSON output.
2. Add observed DB query counters around configured HTTP benchmark routes.
3. Promote the hot-thread profile into a nightly or manual CI job once runner
   limits allow longer database evidence runs.
