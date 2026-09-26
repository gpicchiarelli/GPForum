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

The local workstation now has a material PostgreSQL evidence path using
PostgreSQL 18.4 from Postgres.app. Fixture p95 numbers are still useful as a
route/rendering regression guard, while PostgreSQL-backed runs prove the real
DBIx::Class query topology, migrations, seed data, readiness probes and
configured HTTP paths together.

## Findings

| Endpoint | Finding | Action |
| --- | --- | --- |
| `/` | The latest public thread list had no dedicated index matching `last_activity_at DESC, thread_id DESC`. | Added `idx_threads_public_activity`. |
| `/c/:category_id` | The category thread index existed, but it only indexed `moderation_state = 'visible'` and omitted the `thread_id` keyset tie-breaker while the reader includes `locked` threads. | Added `idx_threads_category_activity_visible_locked`. |
| `/t/:thread_id` | The visible post index existed, but it omitted the `post_id` keyset tie-breaker and covering columns used by the thread page prefetch path. | Added `idx_posts_visible_thread_position`. |
| `/search` | DB-backed evidence showed medium-profile broad search and autocomplete could choose sequential scans over `search_documents`. | Added partial public/latest and public/title-prefix search indexes. No statement could use them; migration 048 drops them and bounds search instead (see `idx_search_documents_created`). |

## Before / After

| Endpoint | Before | After | Query budget |
| --- | --- | --- | --- |
| `/` | Public latest threads depended on generic thread storage or unrelated category/profile indexes. | Dedicated partial covering index for public, live, readable latest threads. | `home:5`, unchanged |
| `/c/:category_id` | Category order index did not match locked-readable semantics or full keyset order. | Dedicated partial covering index matches category, pinned, activity, and thread-id order. | `category_threads:5`, unchanged |
| `/t/:thread_id` | Post order index matched thread and position only. | Dedicated partial covering index matches thread, position, and post-id order. | `thread_view:8`, unchanged |
| `/search?q=performance` | GIN `search_vector` and trigram title indexes existed, but broad public searches could still seq-scan populated `search_documents`. | Partial public/latest and public/title-prefix indexes, meant to keep broad search/autocomplete bounded; they were never usable (dropped in 048). | `search:2`, unchanged |

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

A signed-in reader also sees their own deleted posts, and `PostReader` asks for
them with `(deleted_at IS NULL OR author_user_id = ?)`. That OR cannot use this
partial index, but it does not need to: the unique `(thread_id, position)` key
serves it in page order with a filter. Measured, and left alone.

### `idx_threads_deleted_category_activity`

The other half of a signed-in category page. A reader also sees their own
deleted threads, and `(deleted_at IS NULL OR author_user_id = ?)` in one
predicate can use no index on `threads`: every category index is partial on
`deleted_at IS NULL`, which the OR does not imply, and PostgreSQL read the
whole table. `ThreadReader` now fetches each half in page order from its own
index, cut at the page size, and takes the page from their union by key, in one
statement:

```sql
WHERE me.thread_id IN (
  (SELECT thread_id ... WHERE category_id = ? AND deleted_at IS NULL ...
    ORDER BY pinned DESC, last_activity_at DESC, thread_id DESC LIMIT ?)
  UNION ALL
  (SELECT thread_id ... WHERE category_id = ? AND deleted_at IS NOT NULL
    AND author_user_id = ? ... ORDER BY ... LIMIT ?))
```

Both halves are index-only scans. This index holds deleted threads only, so it
is small and written once per thread, when the thread is deleted. On 100,000
threads in one category a signed-in page fell from 39.33 ms to 0.29 ms with the
same rows.

### `idx_threads_author_public_activity`

Supports the public profile's thread list and count:

```sql
WHERE author_user_id = ?
  AND deleted_at IS NULL
  AND moderation_state IN ('visible', 'locked')
  AND visibility = 'public'
ORDER BY last_activity_at DESC, thread_id DESC
```

Migration 013 built it for `moderation_state = 'visible'`, which the profile's
`IN ('visible', 'locked')` does not imply, so the profile walked
`idx_threads_public_activity` -- every public thread on the site -- filtering
by author. Migration 041 rebuilds it with the predicate the query states.

### `idx_search_documents_created`

Search ranks only the newest matches (quality program 8.10). Ranking scores
every candidate before the first page is known, so a word most documents hold
was ranked over the whole corpus: 100 ms at 20,000 documents, and linear
beyond. `Searcher` now takes its candidates in an inner query and ranks only
those:

```sql
SELECT me.*, <rank>, count(*) OVER () ...
FROM (
  SELECT me.* FROM search_documents me
    JOIN categories category ... JOIN spaces space ...
  WHERE <readable by the actor>
    AND (<full text> OR <trigram> OR <title contains>)
  ORDER BY me.source_created_at DESC, me.entity_id DESC
  LIMIT 1000            -- GPFORUM_SEARCH_CANDIDATE_LIMIT
) me ...
ORDER BY <rank> DESC, me.source_created_at DESC, ...
LIMIT 21
```

Migration 048 adds this index for the inner order. For a common word the
planner walks it from the newest document and stops once it has the
candidates; a rare word keeps the BitmapOr over the GIN and trigram indexes and
sorts its few matches. `t/integration/postgres-search-plan.t` pins both plans
on 20,000 documents. The index is not partial: readability is judged in the
query, against the live category and space (ADR 0102). When every candidate
slot was filled the page says the results were ranked among the most recent
matches only, and that a word or a filter reaches older ones.

The walk depends on statistics for `categories` and `spaces`: without them the
planner cannot tell how many matches survive the readability join, and it
reads and sorts every match again (32 ms rather than 4 ms at 30,000 documents
on PostgreSQL 18). Both tables are small and written only by an administrator,
so autovacuum's default threshold of 50 changed rows can leave them never
analysed. Migration 048 analyses them and sets
`autovacuum_analyze_threshold = 0` on both, so creating or editing a category
or space gets them analysed within a minute. After restoring a dump, run
`ANALYZE` as usual.

Every search and autocomplete also runs under its own `statement_timeout`,
`GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS` (2,000 ms by default), set with
`set_config('statement_timeout', ?, true)` in the transaction the statement
runs in, so it ends with it. A search that still runs long is cancelled and the
page renders degraded, instead of holding one of the few web workers for the
15 s every other query may take. Zero leaves search under
`GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS`.

### Dropped: the partial `permission_scope` search indexes

Migrations 017 and 018 built `idx_search_documents_public_latest`,
`idx_search_documents_public_title_prefix`,
`idx_search_documents_public_filter_rank` and
`idx_search_documents_source_created`, each partial on `permission_scope`.
PostgreSQL uses a partial index only when the query's `WHERE` implies its
predicate, and no statement in `lib/` states `permission_scope`: search
filters on `visibility` and the live category and space. The queries this
section used to document were never sent.

Checked on PostgreSQL 18.6 on 2026-09-26 against the statements `Searcher`
sends -- search and autocomplete, anonymous and member, with every filter
combination, 84 statements -- with the planner's own choice, with sequential
scans disabled, and with every other `search_documents` index dropped: no plan
used any of the four, and after running every statement `pg_stat_user_indexes`
showed `idx_scan = 0` for each. They were write cost on every document the
indexer writes, and migration 048 drops them. `script/query-plan-check`
requires `idx_search_documents_created` in their place.

Migration 048 is not `CONCURRENTLY`: building the index blocks the indexer's
writes to `search_documents` (not searches) for its duration, and each
`DROP INDEX` holds a brief `ACCESS EXCLUSIVE` lock. On a large forum apply it
in a maintenance window.

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
query-plan-check status=ok indexes=26 offset_violations=0 db_evidence=ok
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

Local `script/query-budget --check` passed against the synchronized PostgreSQL
evidence database.

## Load Observability Evidence

The production load hardening pass adds observed DB query counters to configured
HTTP benchmark output. Current Postgres.app evidence, with deterministic
profiles and 5 measured iterations after 1 warmup, shows no budget mismatch and
no duplicate SQL fingerprints on mapped hot paths:

| Profile | Route | p95 ms | Max DB queries | Duplicate queries |
| --- | --- | ---: | ---: | ---: |
| small | `/t/018f1004-0001-7000-8000-000000000001` | 2.818 | 2 | 0 |
| medium | `/t/018f1004-0001-7000-8000-000000000001` | 3.552 | 2 | 0 |
| hot-thread | `/t/018f1004-0001-7000-8000-000000000001` | 6.279 | 2 | 0 |
| medium | `/search?q=performance` | 2.173 | 1 | 0 |
| hot-thread | `/search?q=performance` | 3.987 | 1 | 0 |

## PostgreSQL Follow-up

After `script/bootstrap-deps --postgres` and a reachable PostgreSQL instance,
rerun:

```sh
script/seed-performance-data
script/seed-benchmark --profile medium
script/benchmark-http --configured --iterations 20 --warmup 3
script/query-plan-evidence --check --analyze --profile medium
```

The DB-backed report now includes `EXPLAIN (ANALYZE, BUFFERS)` for:

* latest public thread list;
* category thread list;
* thread post list;
* search projection query;
* autocomplete projection query;
* feed, notification inbox, moderation queue, readiness and metrics evidence.
