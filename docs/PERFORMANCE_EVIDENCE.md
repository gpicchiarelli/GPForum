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

The seed clears the deterministic benchmark fixture rows before inserting the
requested profile. Running `small`, `medium`, and `hot-thread` sequentially on
the same evidence database is therefore idempotent and profile-specific.

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

DB-backed evidence is run by the gate with:

```sh
script/query-plan-evidence --check --analyze --profile medium
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
| outbox_claim | `outbox_claim_ready` |
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
from Postgres.app, using an isolated evidence cluster on `127.0.0.1:55434`,
the deterministic `small`, `medium`, and `hot-thread` seeds, and
`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.

```text
small      query_plan_evidence status=ok endpoints=12 violations=none
medium     query_plan_evidence status=ok endpoints=12 violations=none
hot-thread query_plan_evidence status=ok endpoints=12 violations=none
```

Dry-run evidence:

```text
query_plan_evidence status=ok mode=dry-run analyze=1
```

## HTTP Cache Evidence

Anonymous public SSR cache is covered by `t/32-forum-web.t`. The test performs
a normal anonymous `GET /categories`, verifies `Cache-Control`, `ETag`, and
`Last-Modified`, then repeats the request with `If-None-Match` and expects
`304 Not Modified` plus `X-GPForum-Cache: revalidated`.

This proves the read-heavy path can avoid repeat Perl rendering and response
body transfer for fresh anonymous clients. The cache remains local and
disposable; event/outbox invalidation tags are attached so stale entries can be
discarded without making cache state authoritative.

## Outbox Dispatcher Claim Benchmark

The outbox dispatcher now claims work with a PostgreSQL-safe atomic batch claim:
ready `pending`/`failed` rows and expired `running` locks are selected in
`next_attempt_at, created_at, outbox_id` order with `FOR UPDATE SKIP LOCKED`,
then marked `running` with `locked_at`, `locked_until`, and `locked_by` in the
same transaction. Supporting claim indexes are enforced by
`script/query-plan-check`. PostgreSQL claims now return lightweight DBI-backed
messages directly, avoiding the former DBIx::Class reload, and successful
dispatches are acknowledged with one batch `UPDATE` per worker claim batch.

Local deterministic harness:

```sh
script/bench-outbox-dispatcher \
  --messages 1000,10000,100000 \
  --workers 1,2,4,8 \
  --batch-size 100 \
  --json \
  --artifact artifacts/outbox-dispatcher.json
```

Latest local DBI-direct dispatcher harness, using batch size 100 and
duplicate/lost-message checks:

| Messages | Workers | Delivered | Lost | Duplicates | Ack batches | msg/s | p95 claim ms |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 1 | 1,000 | 0 | 0 | 10 | 114,130.721 | 0.987 |
| 1,000 | 2 | 1,000 | 0 | 0 | 10 | 114,758.379 | 0.924 |
| 1,000 | 4 | 1,000 | 0 | 0 | 10 | 115,580.589 | 0.898 |
| 1,000 | 8 | 1,000 | 0 | 0 | 10 | 113,060.111 | 0.937 |
| 10,000 | 1 | 10,000 | 0 | 0 | 100 | 115,788.945 | 0.946 |
| 10,000 | 2 | 10,000 | 0 | 0 | 100 | 117,434.218 | 0.930 |
| 10,000 | 4 | 10,000 | 0 | 0 | 100 | 116,737.704 | 0.961 |
| 10,000 | 8 | 10,000 | 0 | 0 | 100 | 116,340.075 | 0.939 |
| 100,000 | 1 | 100,000 | 0 | 0 | 1,000 | 111,959.140 | 1.125 |
| 100,000 | 2 | 100,000 | 0 | 0 | 1,000 | 117,957.619 | 0.926 |
| 100,000 | 4 | 100,000 | 0 | 0 | 1,000 | 117,386.890 | 0.924 |
| 100,000 | 8 | 100,000 | 0 | 0 | 1,000 | 116,702.884 | 0.934 |

This harness proves the dispatcher-level no-duplicate invariant across simulated
worker counts. PostgreSQL row-lock behavior is covered by unit tests that assert
the generated claim SQL uses `FOR UPDATE SKIP LOCKED`.

## Realtime Multi-Process Evidence

Realtime fanout now follows the same outbox boundary: domain events dispatched
from outbox produce bounded realtime envelopes, `PgNotifier` publishes them on
`gpforum_domain_events`, and each web process runs a listener that broadcasts
only to its local websocket clients through `Realtime::Hub`.

Covered event families:

| Realtime event | Source |
| --- | --- |
| `thread.update` | `thread.created`, `post.created` |
| `notification.badge` | notification fanout results produced during outbox dispatch; outbox polling rebuilds missed badges from `notifications`/`notification_inbox` |
| `moderation.queue.invalidate` | moderation/report domain events |

`t/85-realtime-outbox-multiprocess.t` simulates separate worker/listener hubs
on a shared PostgreSQL notification bus and verifies that an outbox event
produced by one process reaches websocket subscribers connected to another.
The same test covers bounded, cursor-based outbox polling fallback for missed
NOTIFY events and verifies that polling advances across batches without
replaying the first row.

Realtime metrics exposed through `/metrics` include `broadcast`, `delivered`,
`failed`, `malformed`, and listener-side `listen_notify_received`.

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
isolated evidence cluster, observed DB query counters, and 5 measured
iterations after 1 warmup iteration:

| Profile | Endpoint | p95 ms | p99 ms | req/s | Max DB queries | Duplicate queries | Budget |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| small | `/` | 2.794 | 2.794 | 362.134 | 1 | 0 | ok |
| small | `/c/...0001` | 2.197 | 2.197 | 450.574 | 2 | 0 | ok |
| small | `/t/...0001` | 2.818 | 2.818 | 350.062 | 2 | 0 | ok |
| small | `/search?q=performance` | 1.744 | 1.744 | 559.778 | 1 | 0 | ok |
| medium | `/` | 3.839 | 3.839 | 266.878 | 1 | 0 | ok |
| medium | `/c/...0001` | 3.325 | 3.325 | 295.074 | 2 | 0 | ok |
| medium | `/t/...0001` | 3.552 | 3.552 | 280.995 | 2 | 0 | ok |
| medium | `/search?q=performance` | 2.173 | 2.173 | 448.311 | 1 | 0 | ok |
| hot-thread | `/` | 4.569 | 4.569 | 224.698 | 1 | 0 | ok |
| hot-thread | `/c/...0001` | 4.543 | 4.543 | 242.670 | 2 | 0 | ok |
| hot-thread | `/t/...0001` | 6.279 | 6.279 | 167.302 | 2 | 0 | ok |
| hot-thread | `/search?q=performance` | 3.987 | 3.987 | 247.183 | 1 | 0 | ok |

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
script/query-plan-evidence --check --analyze --profile medium
script/benchmark-http --configured --check --iterations 3 --warmup 1 \
  --route /categories --route /health/ready
script/bench-hypnotoad --check --profile small --workers 2 \
  --iterations 2 --warmup 1 --no-compare \
  --route /categories --route /health/ready
```

This keeps the evidence gate small enough for CI while proving that migrations,
seed data, DB plans, configured HTTP paths, and a minimal Hypnotoad prefork
runtime work together.

## Concurrent stress / load (operator)

For external concurrency targets of **100 / 500 / 1000** in-flight request
slots against a **running** Hypnotoad or reverse-proxy front end, use:

```sh
script/stress-load --dry-run --profile 100 --human
script/stress-load --profile smoke --base-url http://127.0.0.1:8080 --human
script/stress-load --profile 1000 --base-url https://forum.example --check --json
```

See [docs/ops/stress-load.md](ops/stress-load.md). This is intentionally **not**
part of `make check` / default CI; optional `make stress-load` /
`make stress-load-dry`. It complements `script/bench-hypnotoad-scaling` rather
than replacing sequential Hypnotoad route benches.

### Live Hypnotoad + PostgreSQL evidence (2026-09-20)

Recorded on a Cloud Agent VM (4 vCPU, PostgreSQL 16, system Perl 5.38,
Hypnotoad 4 workers, seed `medium`) against `http://127.0.0.1:8080`, base
commit `1d16c69`. Full table and JSON notes:
[docs/ops/stress-load.md](ops/stress-load.md) live evidence appendix.

| Profile | Peak in-flight | req/s | p95 ms | Err % | `--check` |
| --- | ---: | ---: | ---: | ---: | --- |
| `smoke` | 4 | 137 | 49 | 0 | pass |
| `100` (with `GPFORUM_FORUM_READ_RATE_LIMIT=100000`) | 100 | 572 | 605 | 0 | pass |
| `500` (elevated read limit) | 500 | 587 | 1113 | 0 | pass |
| `1000` (elevated read limit) | 1000 | 531 | 4739 | 0 | fail (p95 > 2000 ms) |

Without the read-limit override, profile `100` hits the default
`forum_retrieval` 60/60s ceiling (`429`, ~8% errors). Profile `1000` opened
1000 concurrent slots with zero HTTP errors on this host; latency under the
default p95 gate remains a residual for larger/staging hardware.

## Hypnotoad Worker Scaling

`script/bench-hypnotoad-scaling` is the local evidence gate for worker-count
changes. It runs real forum/search routes across multiple prefork sizes and
records the same route metrics as `script/bench-hypnotoad`:

* p50/p95/p99 latency;
* requests per second;
* observed DB query counts;
* duplicate SQL fingerprint counts;
* route query-budget status;
* OS runtime evidence, including actual Mojolicious reactor class.

Recommended local scaling command:

```sh
script/bench-hypnotoad-scaling --seed --check --profile hot-thread \
  --worker-set 2,4,8 --iterations 20 --warmup 3 \
  --route /categories \
  --route /c/018f1001-0001-7000-8000-000000000001 \
  --route /t/018f1004-0001-7000-8000-000000000001 \
  --route '/search?q=performance'
```

The command should be run before increasing production worker count. On macOS,
the current evidence reports `Mojo::Reactor::Poll`; operators testing high
socket concurrency should compare this with an environment where the optional
`EV` module activates `Mojo::Reactor::EV`.

Current local smoke result on Postgres.app with a temporary migrated database:

| Workers | Thread p95 ms | Search p95 ms | Thread DB max | Search DB max | Duplicate SQL |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 3.688 | 2.122 | 2 | 1 | 0 |
| 4 | 4.140 | 2.522 | 2 | 1 | 0 |
| 8 | 3.398 | 2.005 | 2 | 1 | 0 |

The smoke shows no DB query-budget regression when moving between 2, 4 and 8
workers. It does not prove multicore saturation because the local macOS
preflight reports a conservative CPU count and the run is deliberately short.

## Hypnotoad Deployment Evidence

`script/bench-hypnotoad` starts a temporary Hypnotoad server, uses a free local
port, enables benchmark-only query-count headers, runs warmup separately from
measured requests, and stops the server after the run.

Latest local Postgres.app evidence against `gpforum_visible_evidence`, with 2
Hypnotoad workers, 1 warmup request and 3 measured iterations:

| Route | Hypnotoad p95 ms | In-process p95 ms | Req/s | Max DB queries | Duplicate queries | Budget |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `/categories` | 1.317 | 1.428 | 670.695 | 0 | 0 | ok |
| `/t/018f1004-0001-7000-8000-000000000001` | 3.612 | 3.954 | 260.489 | 2 | 0 | ok |
| `/search?q=performance` | 2.111 | 2.048 | 472.296 | 1 | 0 | ok |
| `/health/ready` | 4.030 | 4.020 | 242.993 | 5 | 0 | none |

The route-level query budget remained clean under Hypnotoad: no HTTP errors, no
budget breaches, and no duplicate SQL fingerprints on the measured forum hot
path.

## Current Limits

* Configured HTTP benchmark output now includes observed DB query counters;
  fixture mode remains useful as a route/rendering threshold gate.
* DB-backed query-plan evidence detects plan-shape risks; it is not a full
  production load test.
* Medium and hot-thread evidence now pass locally; longer soak runs and
  reverse-proxy measurements are still separate work.

## Next Production Evidence Steps

1. Archive medium/hot-thread JSON evidence as CI artifacts when runner limits
   allow longer database evidence runs.
2. Add optional reverse-proxy benchmark evidence in front of Hypnotoad.
3. Add long-running memory drift checks for hot-thread SSR rendering.
