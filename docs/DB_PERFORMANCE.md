# GPForum DB Performance Hardening

Date: 2026-05-24.

This document records commit 3 query/index hardening. The change is intentionally
conservative: no cache, no SQL views, no denormalization, and no new external
infrastructure were introduced.

## Measurement Basis

The profiling and benchmark harness from commit 2 is the source of truth for
this pass.

Local command used for the prior baseline:

```sh
script/benchmark-http --fixture --iterations 5 --warmup 1
```

The local workstation does not currently have optional `DBD::Pg` installed in
the Carton tree, so PostgreSQL-backed p95 and observed query counters were not
available locally. Fixture p95 numbers are still useful as a route/rendering
regression guard, while this patch hardens the measured hot endpoint query
topology before any runtime optimization.

## Findings

| Endpoint | Finding | Action |
| --- | --- | --- |
| `/` | The latest public thread list had no dedicated index matching `last_activity_at DESC, thread_id DESC`. | Added `idx_threads_public_activity`. |
| `/c/:category_id` | The category thread index existed, but it only indexed `moderation_state = 'visible'` and omitted the `thread_id` keyset tie-breaker while the reader includes `locked` threads. | Added `idx_threads_category_activity_visible_locked`. |
| `/t/:thread_id` | The visible post index existed, but it omitted the `post_id` keyset tie-breaker and covering columns used by the thread page prefetch path. | Added `idx_posts_visible_thread_position`. |
| `/search` | Existing GIN and trigram indexes already support the current PostgreSQL-native search projection. | No new search index was added. |

## Before / After

| Endpoint | Before | After | Query budget |
| --- | --- | --- | --- |
| `/` | Public latest threads depended on generic thread storage or unrelated category/profile indexes. | Dedicated partial covering index for public, live, readable latest threads. | `home:5`, unchanged |
| `/c/:category_id` | Category order index did not match locked-readable semantics or full keyset order. | Dedicated partial covering index matches category, pinned, activity, and thread-id order. | `category_threads:5`, unchanged |
| `/t/:thread_id` | Post order index matched thread and position only. | Dedicated partial covering index matches thread, position, and post-id order. | `thread_view:8`, unchanged |
| `/search?q=performance` | GIN `search_vector` and trigram title indexes already present. | Unchanged. | `search:2`, unchanged |

Fixture p95 should not materially change from these SQL-only additions. The DB
impact is expected to appear only in configured PostgreSQL runs through stable
plans and fewer heap visits on the hot read paths.

## Fixture Regression Check

Post-patch fixture command:

```sh
script/benchmark-http --fixture --iterations 5 --warmup 1
```

| Endpoint | Before p95 ms | After p95 ms | Query budget |
| --- | ---: | ---: | --- |
| `/` | 2.255 | 2.241 | `home:5` |
| `/categories` | 1.121 | 1.263 | `categories:3` |
| `/c/category-1` | 2.199 | 2.234 | `category_threads:5` |
| `/t/thread-1` | 1.584 | 1.704 | `thread_view:8` |
| `/search?q=performance` | 1.343 | 1.292 | `search:2` |
| `/health` | 1.139 | 1.007 | none |
| `/health/ready` | 3.572 | 9.521 | none |
| `/metrics` | 0.547 | 0.720 | none |

`/health/ready` remains a fixture-mode `503` because configured PostgreSQL is
not available locally. The higher post-patch fixture latency is readiness
failure-path noise, not a DB query-plan result.

## New Indexes

### `idx_threads_public_activity`

Supports the home/latest-discussions path:

```sql
WHERE deleted_at IS NULL
  AND visibility = 'public'
  AND moderation_state IN ('visible', 'locked')
ORDER BY last_activity_at DESC, thread_id DESC
```

The index is partial because hidden, deleted, private, and member-only content
must not participate in public discovery. Included columns cover the metadata
rendered by `HomePageReader` without loading post bodies.

### `idx_threads_category_activity_visible_locked`

Supports category pages:

```sql
WHERE category_id = ?
  AND deleted_at IS NULL
  AND moderation_state IN ('visible', 'locked')
ORDER BY pinned DESC, last_activity_at DESC, thread_id DESC
```

This fixes the mismatch between the older visible-only category index and the
current product rule that locked threads remain readable.

### `idx_posts_visible_thread_position`

Supports thread pages:

```sql
WHERE thread_id = ?
  AND deleted_at IS NULL
  AND moderation_state = 'visible'
ORDER BY position ASC, post_id ASC
```

The `post_id` suffix matches the keyset tie-breaker used by `PostReader`.
Included columns cover current body/revision pointers and render metadata while
keeping hidden/deleted posts out of the hot read path.

## Query Budget Status

`script/query-plan-check` now requires the forum, notification, abuse-control
and rate-limit hot-path indexes while still rejecting `OFFSET` in
application/template paths. Budgets did not change because the service query
topology did not change:

```sh
script/query-budget --check
script/query-plan-check
```

Local `script/query-plan-check` result:

```text
query-plan-check status=ok indexes=23 offset_violations=0 db_evidence=skipped
```

The production evidence gate adds
`idx_notification_inbox_recipient_created` for the existing notification inbox
reader. That reader filters by `recipient_user_id` and orders by
`created_at DESC, notification_id DESC`; without this index, populated inboxes
would require avoidable sort work on a user hot path.

The security hardening gate adds
`idx_rate_limit_buckets_scope_action_window` for PostgreSQL-backed rate-limit
windows and `idx_reports_reporter_target_open` for duplicate open-report
detection. Both support abuse-control checks that run before writes and must
remain bounded under repeated hostile requests.

Local `script/query-budget --check` could not reach the budget table because
`DBD::Pg` is not installed in this Carton tree. The check remains a CI/runtime
gate for configured PostgreSQL environments.

## PostgreSQL Follow-up

After `script/bootstrap-deps --postgres` and a reachable PostgreSQL instance,
rerun:

```sh
script/seed-performance-data
script/seed-benchmark --profile medium
script/benchmark-http --configured --iterations 20 --warmup 3
script/query-plan-evidence --check
```

The next DB-backed report should include `EXPLAIN (ANALYZE, BUFFERS)` for:

* latest public thread list;
* category thread list;
* thread post list;
* search projection query;
* autocomplete projection query;
* feed, notification inbox, moderation queue, readiness and metrics evidence.
