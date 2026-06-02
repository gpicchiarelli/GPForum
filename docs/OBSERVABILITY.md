# GPForum Observability

Date: 2026-05-24.

This document defines the current observability surface for GPForum production
evidence. It is intentionally operational: every signal listed here must help
diagnose load, query topology, replay safety, degradation behavior, or release
regression without adding external mandatory infrastructure.

## Request DB Query Counters

Configured HTTP requests now attach a DBIx::Class storage statistics observer
through `GPForum::Service::Operations::DbQueryStats`.

Observed per-request data includes:

| Field | Meaning |
| --- | --- |
| `query_count` | SQL statements observed during the request |
| `transaction_count` | transaction begin/commit/rollback events observed |
| `duplicate_queries` | repeated normalized SQL fingerprints in the request |
| `route_name` | Mojolicious route name when available |
| `method` | request method |
| `path` | request path |
| `duration_ms` | request duration measured by the observer |
| `query_budget` | budget result when the route maps to the catalog |

The observer is wired before session validation so session lookup queries are
included in the same request envelope.

Every HTTP response includes `X-Request-ID`. GPForum accepts a safe incoming
`X-Request-ID` from the reverse proxy or generates one through the application
id service. The same value is recorded as the DB query observation
`correlation_id`, and finished request observations include `duration_ms`.

## Benchmark Integration

`script/benchmark-http --configured` and `bin/gpforum-benchmark --configured`
now include observed DB query data in both text and JSON output.

Example text field:

```text
db_queries=max=2,avg=2.000,transactions=0,duplicates=0,budget=ok
```

Example JSON field:

```json
{
  "db_queries": {
    "observed": 1,
    "max_queries": 2,
    "avg_queries": "2.000",
    "max_transactions": 0,
    "max_duplicate_queries": 0,
    "budget_status": "ok"
  }
}
```

Hot-path route checks fail when an observed query budget is exceeded. Duplicate
query detection is also enforced for routes mapped to the query-budget catalog.

## Metrics Surface

`/metrics` now includes `db_query_stats` from `MetricsSnapshot`. If
`GPFORUM_METRICS_TOKEN` is set, the endpoint requires either
`Authorization: Bearer $GPFORUM_METRICS_TOKEN` or
`X-GPForum-Metrics-Token`; reverse proxy/network restrictions remain part of
the production posture.

The snapshot exposes:

| Field | Meaning |
| --- | --- |
| `attached` | whether the DBIx::Class storage observer is active |
| `requests_observed` | number of finished observed requests kept in memory |
| `total_queries` | process-local total SQL query observations |
| `total_transactions` | process-local total transaction observations |
| `duplicate_query_warnings` | cumulative duplicate SQL fingerprint warnings |
| `query_budget_mismatches` | cumulative query-budget mismatches |
| `last_request` | latest observed request envelope |
| `recent_requests` | bounded recent request observations |

This is process-local observability. It is sufficient for local debugging and
single-process benchmark evidence. Multi-process production aggregation remains
the responsibility of logs, scrape configuration, or a future optional metrics
adapter.

## Realtime And Outbox Signals

Realtime metrics include active websocket connections, subscription count,
broadcast attempts (`broadcast`/`broadcasts`), delivered messages, failed
websocket sends, malformed events, and configured connection/subscription
quotas.

PostgreSQL LISTEN/NOTIFY services expose local snapshots for degraded transport,
notify failures, invalid payloads, duplicate event suppression, reconnect count,
`listen_notify_received`, cursor-based outbox polling receives, delivered
fanout count, supervisor running state, scheduled polls, poll failures and
heartbeats.

Outbox metrics include pending rows, failed rows, ready retry backlog, and dead
letter count. Failure classification is persisted as `failure_type` with the
canonical values `transient`, `permanent`, `serialization`, `authorization`, and
`transport`.

## Benchmark Methodology

Current benchmark discipline:

* warmup is separate from measured iterations;
* profile is explicit: `fixture`, `small`, `medium`, or `hot-thread`;
* routes are deterministic;
* configured runs require a reachable PostgreSQL DSN;
* output is available in text and JSON;
* regression checks compare p95, p99 and req/s against a saved baseline;
* regression checks fail only beyond configurable percentage drift;
* absolute thresholds remain deliberately conservative release gates.

Recommended commands:

```sh
script/benchmark-http --fixture --check --iterations 5 --warmup 1

script/seed-benchmark --profile medium
script/benchmark-http --configured --check --profile medium \
  --iterations 20 --warmup 3 --json

script/seed-benchmark --profile hot-thread
script/benchmark-http --configured --check --profile hot-thread \
  --iterations 20 --warmup 3 --json
```

## PostgreSQL Plan Evidence

`script/query-plan-evidence --check --profile small|medium|hot-thread`
executes `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` over the current configured
database.

Covered endpoints:

| Endpoint | Query label |
| --- | --- |
| home | `threads_public_activity` |
| categories | `categories_space_position` |
| category thread list | `threads_category_activity_visible_locked` |
| thread view | `posts_visible_thread_position` |
| search | `search_documents_vector` |
| autocomplete | `search_documents_title_trgm` |
| feed | `user_feed_items_user_created` |
| notifications | `notification_inbox_recipient_created` |
| moderation queue | `reports_queue` |
| health ready | `readiness_regclass` |
| metrics | `outbox_ready` |

Failure rules:

| Risk | Gate |
| --- | --- |
| unbounded sequential scan | fail above configured row threshold unless allowlisted |
| heavy sort | fail above configured row threshold |
| explosive nested loop | fail above configured row threshold |
| page-skipping pagination | fail on `OFFSET` in hot-path application/template code |

## PostgreSQL Operational Visibility

The following PostgreSQL features are recommended but not required for startup:

| Signal | How to enable/use | Purpose |
| --- | --- | --- |
| `pg_stat_statements` | preload extension, then query by total/mean time | identify repeated slow SQL |
| lock waits | inspect `pg_stat_activity` wait fields | detect blocking writes or migrations |
| slow query logs | set `log_min_duration_statement` in staging/production | capture plans needing evidence |
| dead tuples | inspect `pg_stat_user_tables` | detect vacuum pressure |
| index bloat | inspect `pg_stat_user_indexes` and size functions | detect oversized indexes |
| buffer evidence | `EXPLAIN (ANALYZE, BUFFERS)` | distinguish CPU/query-shape vs I/O pressure |

Example diagnostic SQL:

```sql
SELECT query, calls, mean_exec_time, rows
  FROM pg_stat_statements
 ORDER BY mean_exec_time DESC
 LIMIT 20;

SELECT pid, wait_event_type, wait_event, query
  FROM pg_stat_activity
 WHERE wait_event IS NOT NULL;

SELECT relname, n_live_tup, n_dead_tup, vacuum_count, autovacuum_count
  FROM pg_stat_user_tables
 ORDER BY n_dead_tup DESC
 LIMIT 20;

SELECT relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
  FROM pg_stat_user_indexes
 ORDER BY idx_scan ASC, idx_tup_read DESC
 LIMIT 20;
```

`pg_stat_statements` is intentionally optional. GPForum must still boot and pass
tests without it.

## Worker Model Assumptions

The evidence harness measures the in-process Mojolicious test client. It is not
a replacement for Hypnotoad or reverse-proxy load tests. Production deployment
should still observe:

* configured worker count;
* effective worker count;
* process RSS;
* file descriptor usage;
* queue depth;
* projection lag;
* outbox pending/dead messages;
* readiness degradation state.

The benchmark JSON includes process pid, worker count mode and RSS where the OS
can expose it.

## Replay And Projection Guarantees

Projection tests now validate that replay/idempotent observation of projection
offsets does not mutate canonical state. Rebuild and generation switches remain
projection-only operations:

* event/audit/canonical tables remain authoritative;
* projection offsets are operational state;
* projection generations are switchable derived read models;
* replay failure must not corrupt canonical forum rows;
* projection lag must remain observable.

## Degradation Guarantees

Realtime and notification dispatch are enhancement boundaries.

Validated degradation behavior:

* websocket send failure is contained inside the local realtime hub;
* failed realtime delivery records a failed count and keeps SSR continuity;
* PostgreSQL NOTIFY failure is classified as degraded transport and does not
  make canonical writes fail;
* PostgreSQL LISTEN failure makes the listener degraded while cursor polling
  fallback remains valid;
* notification fanout records per-recipient failure without aborting the whole
  fanout;
* core forum rendering does not depend on websocket availability;
* notification delivery failure does not make canonical writes authoritative in
  any external system.

## Remaining Operational Risks

| Risk | Current stance |
| --- | --- |
| multi-process aggregation | process-local metrics are observable but not aggregated |
| long benchmark runs | medium/hot-thread evidence is local/manual, not yet nightly |
| pg_stat_statements | documented, optional, not required by startup |
| production memory growth | RSS is sampled in benchmark output; long-running worker drift still needs soak tests |
| projection rebuild scale | idempotency is covered; full large replay duration still needs bigger datasets |
