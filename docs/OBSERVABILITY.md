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
`X-GPForum-Metrics-Token`, decided by `Web::OperationsAccess`. Reverse
proxy/network restrictions remain part of the production posture.

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
heartbeats. `realtime_listener.listener.notifications` is the process's one
notification queue, shared by the listener and the L1 invalidation bus: its
`gaps` and `relistens` count reconnects to a new connection (each clears L1
once and re-sends badge snapshots) and LISTENs that failed and were issued
again, `listen_failures` counts failed LISTEN attempts (while it rises, L1 is
cleared on every read), `dropped` counts notifications on channels nobody
registered, and each channel reports whether it is `listening`. See
`docs/realtime.md`.

`notifications` is the notification dispatcher's: a member's unread badge is
counted and NOTIFYed after the write that changed it commits (a mark-read, a
mention, the worker's fanout), and a count or NOTIFY that fails there leaves
the write standing and the badge to the next snapshot. The section reports
them:

| Field | Meaning |
| --- | --- |
| `badge_failures` | badges this process could not count or NOTIFY after a write, since it started |
| `last_badge_error` | the last of them, `{at, message}`, or `null`; `message` is the error's first line (at most 300 characters) without the SQL statement and bind values DBI appends, and with an inline `password=` (the DSN DBI's connect error repeats) shown as `[redacted]` |

The process logs the same failure as a warning, `notification badge not
sent: MESSAGE`, at most once every five minutes per message: an outage that
fails every badge the same way writes one line per process every five
minutes, not one per request, and a badge that still goes out in between
does not start the lines again. The next line for a message ends with how
many failed the same way meanwhile, `(N more since last logged)`.

A rising `badge_failures` with `database.status` `ok` points at the unread
count query (cancelled by `statement_timeout`, or failing on the readability
lookup it joins) or at NOTIFY (`badge NOTIFY failed: notify_unavailable`,
`notify_failed`, or a serialization reason such as `payload_too_large`).

The counter is per process. A web worker reports its own on `/metrics`; the
outbox worker (`bin/gpforum-outbox-dispatch`, or a Minion worker) serves no
`/metrics`, so its fanout's badge failures are visible only in its log, where
the `(N more since last logged)` of each line is their count.

Outbox metrics include pending rows, failed rows, ready retry backlog, and dead
letter count. Failure classification is persisted as `failure_type` with the
canonical values `transient`, `permanent`, `serialization`, `authorization`, and
`transport`.

## Replication Signals

ADR 0058 requires replication lag to be monitored. `/metrics` carries a
`replication` section, read on every scrape from PostgreSQL's in-memory
views -- three short queries that take no lock -- as the node the process is
connected to sees it:

* on a primary, `standbys[]` from `pg_stat_replication`: each standby's
  `application_name`, `state`, `sync_state`, `replay_lag_seconds` and
  `bytes_behind` (WAL not yet replayed, from the primary's write position);
* on both, `slots[]` from `pg_replication_slots`: `slot_name`, `slot_type`,
  `active`, `wal_status` and the WAL each one keeps (`retained_bytes`);
* on a standby, `replay_age_seconds` (since the last replayed transaction),
  `replay_pending_bytes` (received, not yet replayed) and `receiving` (1
  while its WAL receiver is connected): the age grows on an idle primary
  too, and a standby cut off from its primary has nothing pending, so only
  `receiving` tells the two apart.

`role` says which the node is. The standby rows need `pg_read_all_stats` on
the application role -- not `pg_monitor`, whose `pg_read_all_settings` reads
a standby's `primary_conninfo` -- and without it `standby_details_visible` is
0 and their fields are empty. A database that cannot answer turns the section
into `status: unavailable` with the `error`, and the rest of `/metrics` is
still served.

`/health/ready` carries a `replication_slots` check: `degraded`, never
`fail`, when an inactive slot keeps more than 1 GiB of WAL or a slot is
`lost`, with the slots and the problems in its `report`. A slot nobody reads
costs the primary disk, not service. The runbook --
[ops/standby-and-failover.md](ops/standby-and-failover.md#watch-the-lag) --
says which fields to read together and when to drop a slot.

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
| categories | `categories_position` |
| category thread list, anonymous | `threads_category_activity_visible_locked` |
| category thread list, signed in | `threads_category_viewer_union` |
| thread view | `posts_visible_thread_position` |
| search | `search_documents_vector` |
| autocomplete | `search_documents_title_trgm` |
| feed | `user_feed_items_user_created` |
| notifications | `notification_inbox_recipient_created` |
| outbox claim | `outbox_claim_ready` |
| moderation queue | `reports_queue` |
| health ready | `readiness_event_log_probe` |
| metrics | `outbox_retry_backlog` |
| home, signed in | `threads_public_activity_viewer` |
| home, halfway down | `threads_public_activity_keyset` |
| category thread list, halfway down | `threads_category_activity_keyset` |
| category thread list, halfway down, signed in | `threads_category_viewer_union_keyset` |
| thread view, signed in | `posts_thread_position_viewer` |
| thread view, halfway down the longest thread | `posts_visible_thread_position_keyset` |
| thread view, halfway down, signed in | `posts_thread_position_viewer_keyset` |

Each statement is the one the application executes, rendered from the method
that builds it; [PERFORMANCE_EVIDENCE.md](PERFORMANCE_EVIDENCE.md) names each
source.

Signed in is a member (ADR 0102) with a `category.read` grant on another
category than the one paged, passed to the readers as the controllers pass
it: the account, and its grants decided for the category. Its plans cover
what a member adds -- the members' level, their own private and deleted
rows, and on the home page the granted category.

A first page proves nothing about the hundredth. A keyset predicate the
index cannot start from reads every row before the cursor and filters it
out, and costs nothing on page one (`Infrastructure::Keyset` records page 800
of a 50,000-post thread filtering 39,008 rows). Each `_deep` endpoint
EXPLAINs the page halfway down the longest thread, the largest category or
the latest public threads, with the cursor its reader mints and the
reader's own predicate (`Infrastructure::Keyset`'s, or the category list's,
which leads with `pinned`), and the first page of the same list. Its
`summary.depth` records `rows_before_cursor` and the
`rows_removed_first_page` and `rows_removed_deep_page` (Rows Removed by
Filter over every scan and loop, but a sequential scan of a table under the
small-table threshold or small by construction, which reads all of it at any
depth), and the text report ends the endpoint's line with
`depth=N rows_removed=FIRST/DEEP`.

Failure rules:

| Risk | Gate |
| --- | --- |
| no usable index | fail when a sequential scan survives with sequential scans disabled, at any table size |
| unbounded sequential scan | fail above configured row threshold unless allowlisted |
| heavy sort | fail above configured row threshold |
| explosive nested loop | fail above configured row threshold |
| page-skipping pagination | fail on `OFFSET` in hot-path application/template code |
| filtering that grows with depth | `filter_grows_with_depth:FIRST:DEEP` when the deep page filters out more than a page (26 rows) more than the first page |
| a cursor the reader ignores | `cursor_ignored` when the deep page's statement is the first page's: the reader did not accept the cursor |

The deep pages also warn, without failing: `no_deep_page` when the database
has nothing to page through; `shallow_page:N` when fewer than 52 rows precede
the cursor -- too few to tell a scan that reads its way there from one that
does not; the small seed's longest thread has eight posts;
`filter_growth_unmeasured` under `--no-analyze`, which records no removed
rows; and `filter_growth_unmeasured:TABLE` when the deep page reads a table
under the small-table threshold whole and that scan filters out more than a
page more than the first page's. Reading it whole is the planner's right
plan there, and it hides the growth instead of showing it: the `medium`
seed's 120 threads put the latest list's deep page 59 rows down, and it is
read that way with its keyset bound or without. The deep-page rule only
bites on a dataset with long lists the planner reads by index: the
`hot-thread` seed's 120-post threads measure the thread pages, the category
and latest lists need more threads than any seed profile writes (a
`--threads` seed, or a production-sized copy).
`t/integration/postgres-query-plan-depth.t` builds a 3,000-post thread and a
1,500-thread category and checks both that the readers pass and that every
deep page, signed in or not, fails once its predicate loses the bound on the
sort column (Keyset's, or the category list's own).

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
offsets does not mutate canonical state. A second `record_progress` of the same
`last_event_id` keeps the original `updated_at`. A second `mark_failed` of an
already-failed offset keeps the original timestamp. Ready, active, and failed
generation status writes skip when the stored status already matches. Rebuild
and generation switches remain projection-only operations:

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
* PostgreSQL LISTEN failure makes the listener poll the outbox backstop,
  while the process has sockets, until the LISTEN is re-issued on the next
  poll;
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
