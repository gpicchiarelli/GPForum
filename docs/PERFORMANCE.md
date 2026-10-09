# GPForum Performance

The one document on performance and the database: the principles and the
budgets, how the schema and the queries stay fast and how that is checked,
the caches, what search costs, how to profile, the operating-system posture,
and where the evidence is and how to reproduce it. Checked against the code
on 2026-10-03.

The target is one host, scaled vertically first: Mojolicious under
Hypnotoad, PostgreSQL, the outbox workers, and GlifiStore as a disposable
shared cache. No broker, search engine or load tool beyond those is
required. The hot paths, in the order the May 2026 audit ranked them:
outbox dispatch, the thread page, the category and home lists, search and
autocomplete, notifications and the feed, realtime fan-out, uploads.

## Principles

1. **Measure before tuning.** A change made for speed cites a benchmark, a
   plan or a profile produced by the commands below.
2. **PostgreSQL is the source of truth.** Every cache can lose any entry at
   any time and the page is still right.
3. **A hot read is bounded.** Keyset pages with a `LIMIT`, never `OFFSET`;
   a fixed number of statements per page, whatever its rows.
4. **The gate checks what the application sends.** The plan gate EXPLAINs
   the statement the reader method builds, not a transcription of it.
5. **DBIx::Class outside hot loops.** Writes, admin and the page readers use
   it (the plan gate renders their SQL from it); the loops -- the outbox claim
   and acknowledgement, and the feed fan-out -- use fixed SQL with bind
   parameters.
6. **Gates fail on change, not on absolute speed.** Latency thresholds are
   deliberately loose release gates; plan shape, statement counts and the
   saved-baseline comparison are what catch a regression.
7. **Realtime and uploads stay off the request's critical path.** Realtime
   is an enhancement (see [realtime.md](realtime.md)); large files go
   through the reverse proxy.

A performance change is incomplete unless it states the command, the dataset
or seed profile, before and after (or the current baseline), p50/p95/p99
where they apply, the plan gate's status, and lost and duplicate counts for
the outbox or realtime delivery.

## Budgets

| Budget | Value | Enforced by |
| --- | --- | --- |
| Statements per page | 15 pages, anonymous and signed in, 1 to 8 statements each, the same for 1 row and 50 | `t/integration/postgres-query-budget.t` |
| Endpoint catalog | `max_queries` from 2 (search) to 8 (thread view, admin status), at most 1 transaction, no duplicate statement | `QueryBudget`; readiness, platform check, benchmarks |
| Query plan | the rules under [The plan gate](#the-plan-gate) | `script/query-plan-evidence --check` |
| Single-client latency | p95 500 to 1,000 ms, p99 1,000 to 2,000 ms, at least 1 req/s per route | `script/benchmark-http --check` |
| Regression | 25% on p95, p99 or req/s against a saved baseline | `--baseline`, `--regression-tolerance` |
| Concurrent load | p95 at most 2,000 ms | `script/stress-load --check` |
| PostgreSQL session | `statement_timeout` 15 s, `lock_timeout` 3 s, `idle_in_transaction_session_timeout` 10 s | `GPFORUM_DATABASE_*_TIMEOUT_MS` |
| Search | its own `statement_timeout` of 2 s; ranks the newest 1,000 matches | `GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS`, `GPFORUM_SEARCH_CANDIDATE_LIMIT` |

The session timeouts are set on connect with `application_name=gpforum`; 0
disables one. `gpforum-migrate --apply` clears `statement_timeout`, so DDL is
not capped at the web budget.

## Database

### Hot-path indexes

| Index | Serves | Key, and the rows it holds | Migration |
| --- | --- | --- | --- |
| `idx_threads_public_activity` | home: latest public threads | `last_activity_at DESC, thread_id DESC`; live, public, visible or locked; covers the listed columns | 014 |
| `idx_threads_category_activity_visible_locked` | category page | `category_id, pinned DESC, last_activity_at DESC, thread_id DESC`; live, visible or locked; covering | 014 |
| `idx_threads_deleted_category_activity` | signed-in category page: the reader's own deleted threads | the same key; deleted threads only | 041 |
| `idx_posts_visible_thread_position` | thread page | `thread_id, position, post_id`; live, visible; covers the body and revision pointers | 014 |
| `idx_threads_author_public_activity` | public profile: thread list and count | `author_user_id, last_activity_at DESC, thread_id DESC`; live, visible or locked, public | 013, rebuilt in 041 |
| `idx_search_documents_created` | search candidates, newest first | `source_created_at DESC, entity_id DESC`; not partial | 048 |
| `idx_search_documents_vector`, `idx_search_documents_title_trgm` | full text (GIN) and fuzzy title (trigram) | | 003 |
| `idx_notification_inbox_recipient_created` | notification inbox | `recipient_user_id, created_at DESC, notification_id DESC` | 015 |
| `idx_user_feed_items_user_created`, `idx_user_feed_items_ranked`, `idx_user_feed_items_item` | feed pages; removing a thread from every feed in one statement | | 047 for `_item` |
| `idx_outbox_messages_claim_ready`, `_stale_locks`, `_status_created`, `_retry_backlog`, `_realtime_poll` | outbox claim, lease recovery, retention and console, retry metric, realtime polling | | 022, 022, 037, 021, 023 |
| `idx_rate_limit_buckets_scope_action_window` | rate-limit windows, checked before writes | | 016 |
| `idx_reports_reporter_target_open_unique` | one open report per reporter and target | unique | 026 |

PostgreSQL uses a partial index only when the query's `WHERE` implies its
predicate. Two defects came from that rule. The profile index was built for
`moderation_state = 'visible'` while the profile asks for `IN ('visible',
'locked')`, so the profile walked every public thread on the site filtering
by author, until 041 rebuilt it with the predicate the query states. Four
search indexes were partial on `permission_scope`, a column no statement
names, and were never used (see [Search costs](#search-costs)).

`script/query-plan-check` requires 26 indexes by name: every one above but
the feed's `_item` and the outbox's `_retry_backlog`, and the category,
session, event-log, audit and notification indexes (the list is in the
script). It replays every migration's `CREATE INDEX` and `DROP INDEX`
in order, so an index a later migration drops no longer counts: four
required names were dropped by 037 while the gate, matching migration text,
kept passing on their `CREATE`.

### Signed-in readers

A signed-in reader also sees their own deleted rows, asked for as
`(deleted_at IS NULL OR author_user_id = ?)`. That predicate implies no
`deleted_at IS NULL` partial index.

- **Category page.** No index on `threads` could answer it and PostgreSQL
  read the whole table. `ThreadReader` now fetches each half in page order
  from its own index, cut at the page size, and takes the page from their
  `UNION ALL` by key, in one statement; both halves are index-only scans.
  The deleted-only index is small and written once per thread, when it is
  deleted. On 100,000 threads in one category a signed-in page fell from
  39.33 ms to 0.29 ms with the same rows.
- **Thread page.** The unique `(thread_id, position)` key serves the same
  predicate in page order with a filter. Measured, and left alone.

`t/integration/postgres-viewer-plan.t` asserts the plans and who sees which
thread, and fails in four places without migration 041.

### Keyset pagination

Every paged list -- posts, threads, profiles, bookmarks, mentions, feed,
moderation and audit history -- orders by a sort column and an id and
resumes after the last row shown. `GPForum::Infrastructure::Keyset` writes
that condition once: the lexicographic comparison, plus a bound on the sort
column, which lets PostgreSQL start the index scan at the cursor rather than
at the first row. Page 800 of a 50,000-post thread read 39,008 rows (5.7 ms)
before the bound; it now reads five (0.03 ms). A cursor is a position or a
timestamp and a uuid; anything else is the first page (a junk `?after=` used
to reach PostgreSQL as a timestamp and fail the request).

`OFFSET` is refused twice: `script/query-plan-check` fails on it anywhere in
`lib/` or `templates/` (a line that names `query-plan-check` is exempt), and
the plan evidence fails a statement that contains it (`offset_in_hot_query`).

### The plan gate

Two commands. `script/query-plan-check` is the gate CI and the operator run:

1. the 26 required indexes, as the migrations leave the schema;
2. no `OFFSET` in application or template code;
3. with `GPFORUM_DATABASE_DSN` set, `script/query-plan-evidence --check
   --analyze --profile medium`. Without a DSN that half is reported as
   `db_evidence=skipped`; CI passes `--require-db`, which turns a missing DSN
   into a failure, so the EXPLAIN half cannot quietly stop running.

`script/query-plan-evidence` EXPLAINs, on the configured database, the
statement each endpoint really sends. Nothing is transcribed: the SQL is
rendered from the resultset the named method returns -- the method the
application calls -- or, for the outbox claim, taken from `ClaimQuery::sql`
with a worker's binds. Changing a reader's query changes what the gate
EXPLAINs, and `t/54-query-plan-evidence.t` pins that the SQL is the reader's,
byte for byte.

| Endpoints | Query labels | Source |
| --- | --- | --- |
| `home`, `home_signed_in`, `home_deep` | `threads_public_activity`, `_viewer`, `_keyset` | `ThreadReader::latest_threads_resultset` |
| `category_threads`, `_signed_in`, `_deep`, `_deep_signed_in` | `threads_category_activity_visible_locked`, `threads_category_viewer_union`, `threads_category_activity_keyset`, `threads_category_viewer_union_keyset` | `ThreadReader::category_threads_resultset` |
| `thread_view`, `_signed_in`, `_deep`, `_deep_signed_in` | `posts_visible_thread_position`, `posts_thread_position_viewer`, `posts_visible_thread_position_keyset`, `posts_thread_position_viewer_keyset` | `PostReader::thread_posts_resultset` |
| `categories` | `categories_position` | `CategoryReader::categories_resultset` |
| `search` | `search_documents_vector` | `Searcher::search_resultset`, at the configured candidate cap |
| `autocomplete` | `search_documents_title_trgm` | `Searcher::autocomplete_resultset` |
| `feed` | `user_feed_items_user_created` | `FeedReader::feed_resultset` |
| `notifications` | `notification_inbox_recipient_created` | `Notification::Dispatcher::inbox_resultset` |
| `outbox_claim` | `outbox_claim_ready` | `Outbox::ClaimQuery::sql` |
| `moderation_queue` | `reports_queue` | `ReportStore::queue_resultset` |
| `health_ready` | `readiness_event_log_probe` | `Readiness::probe_resultset('EventLog')` |
| `metrics` | `outbox_retry_backlog` | `MetricsSnapshot::retry_backlog_resultset` |

Signed in is a member (ADR 0102) with a `category.read` grant on another
category than the one paged, passed to the readers as the controllers pass
it, so the plans cover what a member adds: the members' level, their own
private and deleted rows, and on the home page the granted category.

Each statement gets two plans, inside a transaction that is rolled back
(`EXPLAIN ANALYZE` executes the statement, and the claim is an `UPDATE`):
the planner's own choice, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`, which
carries the timings and row counts; and a second taken with `SET LOCAL
enable_seqscan = off`.

| Rule | Fails when |
| --- | --- |
| `no_usable_index:TABLE` | a sequential scan survives with sequential scans disabled, at any table size |
| `seq_scan:TABLE` | a sequential scan returns over 100 rows from a table above 10,000 live rows |
| `heavy_sort:N` | a sort handles over 1,000 rows |
| `explosive_nested_loop:N` | a nested loop produces over 5,000 rows from more than one outer row |
| `offset_in_hot_query` | the statement contains `OFFSET` |
| `filter_grows_with_depth:FIRST:DEEP` | a deep page filters out more than a page (26 rows) more than its first page |
| `cursor_ignored` | the deep page's statement is the first page's: the reader dropped the cursor |

The first rule is the one that works on a test-sized database: it is a fact
about the schema, true on ten rows and on ten million. It is a floor, not a
proof of the best plan -- it catches a query no index can answer, not one
answered by the wrong index. A scan of a table small by construction
(`categories`, `schema_versions`, `projection_offsets`,
`projection_generations`) always passes, and so does `health_ready`'s
one-row probe. Recorded without failing:

- `seq_scan_small_table:TABLE` -- a sequential scan of a table under 10,000
  rows, often the planner's right answer (the medium seed's 120 threads used
  to fail the gate on correct plans);
- `seq_scan_most_rows:TABLE` -- search or autocomplete scanning at least
  half of `search_documents`: relevance order must score every match;
- `bitmap_heap_scan` -- a bitmap heap scan over 1,000 rows;
- for the deep pages, `no_deep_page` (nothing to page through),
  `shallow_page:N` (fewer than 52 rows before the cursor -- too few to tell
  a scan that starts at the cursor from one that reads its way there),
  `filter_growth_unmeasured` (under `--no-analyze`) and
  `filter_growth_unmeasured:TABLE` (a small table read whole hides the
  growth).

A first page proves nothing about the hundredth. Each `_deep` endpoint
EXPLAINs the page halfway down the longest thread, the largest category or
the latest public threads, with the cursor its reader mints, and that list's
first page; `summary.depth` records the rows before the cursor and the rows
each page filtered, and the text report ends the line with
`depth=N rows_removed=FIRST/DEEP`. The deep-page rule only bites on long
lists the planner reads by index: the `hot-thread` seed's 120-post threads
measure the thread pages, while the category and latest lists need more
threads than any seed profile writes (a `--threads` seed, or a
production-sized copy). `t/integration/postgres-query-plan-depth.t` builds a
3,000-post thread and a 1,500-thread category and checks both that the
readers pass and that every deep page fails once its keyset bound is
removed.

Options: `--endpoint NAME` (repeatable) isolates plans, `--json` for the
report, `--dry-run` lists the endpoints without a database, `--no-analyze`
plans without executing. `--profile small|medium|hot-thread` names the seed
in the report; it does not seed.

### Migrations and `CONCURRENTLY`

A migration whose first line is `-- gpforum:no-transaction` runs one
statement at a time, each in its own transaction, so it can use `CREATE
INDEX CONCURRENTLY` and leave writes to the table running. Each statement
must be safe to repeat: drop a half-built index first with `DROP INDEX
CONCURRENTLY IF EXISTS`, because a failed concurrent build leaves an invalid
one behind. Such a file holds plain statements, each ending with a semicolon
at the end of a line, and no dollar-quoted bodies.

From migration 049 on, an index on a table that already exists must be
built that way, or the file must say why not on a
`-- gpforum:blocking-index REASON` line (a partitioned parent cannot be
built concurrently). `t/209-migration-indexes.t` enforces it, and
`t/integration/postgres-migration-concurrently.t` runs it on PostgreSQL.

Migrations 041, 047 and 048 predate the runner's support and build their
indexes inside a transaction, under a `SHARE` lock that blocks writes to the
table for the build -- 041 every reply's `last_activity_at` update, 047 feed
writes, 048 the search indexer's (not searches) -- and 048 takes a brief
`ACCESS EXCLUSIVE` lock for each `DROP INDEX`. On a large forum apply them in
a maintenance window. After restoring a dump, run `ANALYZE` as usual.

### The outbox claim

The dispatcher claims work in one statement (`GPForum::Service::Outbox::ClaimQuery`):
ready `pending` and `failed` rows with `next_attempt_at <= now`, and `running`
rows whose lease (`locked_until`) has expired, ordered by `next_attempt_at,
created_at, outbox_id`, locked `FOR UPDATE SKIP LOCKED` so several workers
consume without a global lock, and marked `running` with `locked_at`,
`locked_until` and `locked_by` in the same statement. On PostgreSQL the
claimed rows come back as lightweight DBI-backed messages, with no
DBIx::Class reload. Each message then costs two single-row `UPDATE`s by
primary key, each conditional on `locked_by` and `status`: its claim renewed
before the dispatch and its outcome written after it, so a slow batch cannot
outlive its lease and have its tail delivered twice
([OUTBOX_LIFECYCLE.md](OUTBOX_LIFECYCLE.md), Claims and Leases). Each is a
commit of its own. On the development laptop (PostgreSQL 18.6, one worker,
batches of 100, a transport that does nothing, 10,000 messages) that is
about 2,150 messages a second, 46 ms a batch, where acknowledging the batch
in one `UPDATE` at its end managed 9,000 to 11,600 and 8 to 11 ms
(2026-10-08). That is one worker's ceiling with nothing to do: a real
handler writes its own rows for each message, and several workers take from
the queue without waiting for each other's rows. The indexes are
`idx_outbox_messages_claim_ready` and `idx_outbox_messages_stale_locks`;
migration 037 dropped the pending- and failed-only ones the claim no longer
used.

## Query budgets

`GPForum::Service::Operations::QueryBudget` is the catalog of how much
database work each named endpoint may do: `max_queries` (2 for search and
autocomplete, 3 for the category index, 4 for notifications, 5 or 6 for the
lists, writes, staff pages and `/metrics`, 8 for the thread view and the
admin status page), at most one transaction and no duplicate statement, at the
`release-gate` level. The request hook in `GPForum::Bootstrap::Operations`
observes every request that carries an endpoint name: statements,
transactions, duplicate normalized SQL fingerprints (the N+1 signal), the
route, and the budget's status.

Observation is always on. Failing is opt-in, for tests and benchmarks:

```sh
GPFORUM_QUERY_BUDGET_ENFORCE=1 script/gpforum-carton exec prove -lr t
```

throws after dispatch when a request breaks its budget; the response it
breaks is never sent, so the client waits out its timeout. Every server
profile ignores the flag -- `production` and `staging` -- and a breach there
shows in metrics and the release gates instead of failing a response. Only
`development`, `test` and names outside the profiles honour it.

`t/integration/postgres-query-budget.t` holds the measured budgets: 15
pages, anonymous and signed in, against the seeded forum, from 1 statement
(the anonymous category index) to 8 (a signed-in thread page). Each page must
send the same number of statements for one row as for fifty, so an N+1
fails, and stay within the budget measured on 2026-09-26; raising one is a
decision to write down in the commit.

**When readiness reports `query_budget_drift`:** the `endpoint_query_budgets`
table no longer matches the catalog in the code -- an endpoint missing,
extra, or stored with other limits, usually after a deploy that changed the
catalog. The check fails until the table matches:

```sh
script/query-budget --sync     # bin/gpforum-query-budget --sync; makes the table match the catalog
script/query-budget --check    # exits non-zero while drift remains, naming each endpoint
```

`--sync` inserts missing rows, updates rows that differ and deletes the rows
of endpoints the catalog no longer has, naming them (`removed` with
`--json`), so `--check` passes after it.

`--print` shows the catalog, and `--json` answers in JSON. The platform
check, `/metrics` and the admin console report the same drift.

`/metrics` has a budget of its own, `metrics`: 5 statements (rate limit
buckets, the budget drift read, the outbox by status, the retry backlog and
dead letters), no duplicate. The replication and `SELECT 1` reads go through
the raw handle and are not counted. It used to count pending and failed
outbox messages with two statements that differed only in their bind value,
one statement sent twice on every scrape; they are one grouped statement
now.

With `GPFORUM_BENCHMARK_QUERY_HEADERS=1` every response carries
`X-GPForum-DB-Queries`, `-Transactions`, `-Duplicate-Queries`, `-Budget`,
`-Budget-Endpoint` and `-Budget-Max-Queries`; `script/bench-hypnotoad` sets
it to read the counts back from a real server.

## Caching

### The public page cache

Anonymous `GET` and `HEAD` requests for the category index, a category page
and a thread page go through `GPForum::Web::PublicHttpCache`;
`GPForum::Web::PublicCacheAccess` decides whether a request may use it.
Signed-in visitors, other methods, the home page, profiles and feeds are
rendered as usual.

- **Key:** `forum-ssr:NAME:LOCALE:THEME:PATH:limit=N` -- the page, the
  visitor's language and theme, the path without the parts that do not
  change it, and the effective page size. Junk query parameters do not mint
  entries, a page past the first (with a cursor) is not cached, and a thread
  under a wrong slug is a 301 to its own path rather than a new entry.
- **Before the queries:** a page asks the cache before running its queries,
  so a hit costs no statement (`t/integration/postgres-public-cache.t`).
- **Headers:** `Cache-Control: public, max-age=N,
  stale-while-revalidate=N`, a weak `ETag` (SHA-1 of the body),
  `Last-Modified` (when it was rendered), `Vary: Accept, Accept-Language,
  Cookie`, `X-GPForum-Source: public-http-cache` and `X-GPForum-Cache`
  (`hit`, `miss`, `revalidated`, `miss-revalidated`). A matching
  `If-None-Match` or `If-Modified-Since` gets an empty 304.
- **Lifetime:** `GPFORUM_CATEGORY_CACHE_TTL_SECONDS` (60), both the entry's
  life and the `max-age` sent.
- **Invalidation:** entries are tagged `forum:public-html`,
  `forum:categories`, `forum:category:<id>` and `forum:thread:<id>`; events
  through the outbox and moderation actions retire them at once. The miss
  takes the cache's ticket for its tags before the queries, so a purge that
  lands while the page renders retires the entry it stores. `/admin/jobs`
  purges the whole page cache, and says when GlifiStore was not reached.

### The tiers

`GPForum::Service::Operations::CacheFactory` builds the application cache:

- **L1, `LocalCache`:** one per process, `GPFORUM_LOCAL_CACHE_MAX_ENTRIES`
  (4,096) entries with a TTL, evicting the least recently used in a fixed
  number of hash operations. It used to scan every key once full: measured
  with 2,000 entries, a write went from 0.005 ms to 4.375 ms (960x) once the
  cache filled; now 1.5x, and `t/189` fails it past 20x.
- **L2, `SharedCache` on GlifiStore:** shared by every process,
  `GPFORUM_GLIFISTORE_URL`, optional (left empty, each process keeps L1
  alone in front of PostgreSQL). `TieredCache` reads L1 then L2, copies
  an L2 hit into L1 with the lifetime it has left, and writes and
  invalidates both. A tag is a token in GlifiStore: invalidating it is one
  `ERASE`, and an entry whose token changed is a miss. After a failed call a
  process skips GlifiStore for 15 seconds (`retry_after_epoch` and
  `stats.skipped` in `/metrics`), so a hung server does not stall every
  request.
- **Across workers:** an invalidation in one Hypnotoad worker reaches the
  others through `CacheInvalidationBus`, a `NOTIFY` on
  `gpforum_cache_invalidation` that PostgreSQL delivers only if the writing
  transaction commits; every `get` applies its siblings' invalidations
  before trusting L1. One notification queue per process routes the cache
  and realtime channels (ADR 0111). A process that cannot `LISTEN` -- one
  pointed at a standby -- clears its L1 on every read until it can
  (`listen_failures` in `/metrics`).

Open: the cache is bounded by entries, never by bytes; expired L1 entries are
dropped when read, and nothing purges unread ones on a timer; the home page,
profiles and feeds are not page-cached. A time rendered relative ("3 hours
ago") would be wrong in cached HTML minutes later, so relative times are a
client-side enhancement over `<time datetime>`.

Static assets carry `?v=` and the first 12 hex digits of the file's SHA-256
(`GPForum::Web::AssetManifest`): a 200, 206 or 304 for the current digest is
served `public, max-age=31536000, immutable`, a bare or stale one
`max-age=3600`, and an error response neither. The shipped nginx and Caddy
configurations call any `v` immutable; the module's POD says when that
shows. Large static files and attachments should be sent by the reverse
proxy (see [OS tuning](#os-tuning)).

## Search costs

Search reads the `search_documents` projection, which the outbox keeps in
step with the forum.

- **Indexable arms.** The full-text arm binds the text-search configuration
  the documents are built with (it used to read `me.language` from every
  row, which no index qual may do), and the fuzzy-title arm uses the `%`
  operator under `pg_trgm.similarity_threshold = 0.18`, set per connection.
  The plan is a `BitmapOr` over the GIN and trigram indexes. On 100,000
  documents a query with no match fell from 128.5 ms to 14.3 ms and a
  misspelling from 145.6 ms to 55.4 ms.
- **A capped candidate set.** Ranking scores every candidate before the
  first page is known, so a word most documents hold was ranked over the
  whole corpus: 100 ms at 20,000 documents, linear beyond. `Searcher` now
  takes the newest `GPFORUM_SEARCH_CANDIDATE_LIMIT` (1,000) matches in an
  inner query, ordered `source_created_at DESC, entity_id DESC`, and ranks
  only those. For a common word the planner walks
  `idx_search_documents_created` from the newest document and stops at the
  cap; a rare word keeps the `BitmapOr` and sorts its few matches.
  `t/integration/postgres-search-plan.t` pins both plans on 20,000
  documents. When the cap was filled the page says the results were ranked
  among the most recent matches, and that a word or a filter reaches older
  ones.
- **Statistics on `categories` and `spaces`.** The walk needs them: without
  them the planner cannot tell how many matches survive the readability
  join, and reads and sorts every match again (32 ms rather than 4 ms at
  30,000 documents). Both tables are small and written only by an
  administrator, so autovacuum's default threshold of 50 changed rows could
  leave them never analysed. Migration 048 analyses them and sets
  `autovacuum_analyze_threshold = 0`, so a change to more than a tenth of
  their rows triggers an analyse.
- **Live placement.** A document is searched only while its category is
  still its thread's and its space that category's (ADR 0102); a moved
  thread's documents are hidden until the outbox reindexes them. The
  thread's category is read with scalar subqueries by primary key, which the
  planner cannot flatten into a join, so neither `threads` nor `posts` is
  scanned. Two lookups per candidate, bounded by the cap: a word every one
  of 20,000 documents holds went from 4 to 6.4 ms on PostgreSQL 18, a rare
  word did not change, and a single joined subquery was slower (8.2 ms).
- **A timeout of its own.** Each search and autocomplete runs under
  `GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS` (2,000), set with
  `set_config('statement_timeout', ?, true)` inside its transaction. A
  search that runs long is cancelled and the page renders degraded, instead
  of holding one of the few web workers for the 15 s any other query may
  take; the log line no longer carries the search text. 0 leaves search
  under the connection's timeout, and a value above it is lowered to it, so
  an operator who lowers the connection's timeout to shed load lowers
  search's with it.
- **The dropped partial indexes.** Migrations 017 and 018 built
  `idx_search_documents_public_latest`, `_public_title_prefix`,
  `_public_filter_rank` and `_source_created`, each partial on
  `permission_scope`. Recreated on 20,000 documents on PostgreSQL 18.6
  (2026-09-26 and 2026-10-01), 134 statements -- search and autocomplete,
  anonymous and member, every filter combination -- gave 670 plans under
  the planner's choice, with sequential scans, sorts, bitmap scans and every
  other index disabled in turn: none used any of the four, and
  `pg_stat_user_indexes` showed `idx_scan = 0` for each. They were write cost
  on every document, and 048 drops them.
- **Bounded indexer work.** Removing a large thread deletes its documents
  500 per transaction, title first; renaming, moving or restoring it
  reindexes 500 posts at once and the rest as `search.thread_posts_requested`
  outbox messages. An unchanged document is not rewritten.

The plan gate EXPLAINs search at the configured candidate cap, because the
cap is the inner `LIMIT` that decides between the walk and the sort.
Rebuilding the whole index is `bin/gpforum-search-rebuild`
([ops/search-rebuild.md](ops/search-rebuild.md)).

## Profiling

Devel::NYTProf, locally; every profile lands in `var/profile/`, named with
the process id.

```sh
# one route through the benchmark harness (3 iterations, 1 warmup)
script/profile-nytprof --route /t/thread-1 --fixture
# one GET through Test::Mojo, as performance.yml does
script/profile-route /categories
# any Perl program
script/profile script/bench-outbox-dispatcher --messages 10000 --workers 4

script/gpforum-carton exec nytprofcsv -f var/profile/route-nytprof.out.<pid> \
  --out var/profile/route-nytprof.csv
script/gpforum-carton exec nytprofhtml -f var/profile/route-nytprof.out.<pid> \
  --out var/profile/html
```

In fixture mode a route's profile is dominated by start-up, not rendering
(May 2026): dynamic `require` in `Class::C3::Componentised`, accessors
generated by `Class::Accessor::Grouped`, DBIx::Class result-source
registration, and the harness's own RSS sampling. That is a measurement, not
an instruction. One measured rendering cost is still open: a thread page
renders every post body from Markdown on each request, 5.70 ms of CPU per
page, instead of using the stored `body_rendered_safe` (quality program
8.4); the page cache hides it from anonymous visitors.

Memory: the benchmark reports carry `memory_rss_kb`. For a soak, record the
RSS of the processes before, during and after (`ps -o pid,rss,command -p
PID`) and look for growth that does not level off under thread rendering,
websocket fan-out, outbox dispatch and upload processing.

## OS tuning

GPForum reports the operating-system posture; it does not change it. It
never modifies sysctl values, raises limits, requires root, pins CPU
affinity, installs service units, or patches socket behaviour outside the
Mojolicious and Hypnotoad runtime. The supervisor -- systemd, rc.d and
jails, launchd -- owns the Hypnotoad process count, unit hardening,
file-descriptor limits and kernel tuning; the reverse proxy owns TLS,
compression, buffering and static transfer.

```sh
script/os-preflight            # human report; fails only on fail
script/os-preflight --json
script/os-preflight --strict   # also each finding on stderr, as the units run it
```

The preflight reports the OS profile (`darwin`, `freebsd`, `linux` or
`unknown`) and its expected event backend (`kqueue` on macOS and FreeBSD,
`epoll` on Linux, `select` elsewhere, reported degraded); the CPU count and
recommended web workers; the configured web, worker and realtime processes;
open file descriptors (from `/proc/$pid/fd` or `/dev/fd`) and the limit
(`sysconf(_SC_OPEN_MAX)`); the socket posture; and the nice plan. The event
backend is diagnostic: Mojolicious and Hypnotoad own the loop, and the
actual reactor is in [ops/reactor-backend.md](ops/reactor-backend.md).

| Setting | Values | Meaning |
| --- | --- | --- |
| `GPFORUM_OS_REUSEPORT` | `auto`, `on`, `off` | `SO_REUSEPORT` on the listen URL where supported |
| `GPFORUM_OS_SENDFILE` | `auto`, `on`, `off` | sendfile, delegated to the reverse proxy |
| `GPFORUM_OS_STATIC_XSENDFILE` | `auto`, `on`, `off` | static transfer through the proxy |
| `GPFORUM_OS_WORKER_PRIORITY` | `auto`, `on`, `off` | report the nice plan below as one the supervisor applies (`supervisor-nice`) rather than observed (`observe`) |
| `GPFORUM_OS_AFFINITY` | retired | accepted and ignored, with a warning at start (it was a declaration, never applied) |
| `GPFORUM_OS_MIN_RECOMMENDED_WORKERS` | integer | floor for the worker recommendation |
| `GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS` | integer | the descriptor floor, 65,536 by default |

`SO_REUSEADDR`, `SO_KEEPALIVE` and `TCP_NODELAY` are expected
(`GPForum::OS::Socket`). A feature set to `on` where the platform lacks it is
reported degraded; `auto` stays conservative. A descriptor limit under the
floor is deployment drift: production expects `LimitNOFILE=65536` or its
equivalent, since sockets, database connections, logs, uploads and worker
pipes all draw on it.

| Process class | Nice delta |
| --- | ---: |
| `web_worker` | 0 |
| `projection_worker`, `search_worker` | 5 |
| `mail_worker` | 8 |
| `maintenance_worker` | 10 |

The plan is a declaration, whatever the setting: nothing in GPForum calls
`setpriority`, and the report says so: policy `declared-for-the-supervisor`,
action `supervisor-nice` when enabled (it used to read
`setpriority-if-permitted`, a call nothing made). No GPForum process starts
knowing its class -- the web workers run under Hypnotoad, the outbox
dispatcher and the scheduled jobs under their own units -- so there is no
start hook that could pick a delta. The supervisor sets the nice value;
the shipped scheduled-jobs units (systemd and launchd) set 10.

What the application does apply, through `GPForum::OS::RuntimePolicy`:
Hypnotoad's workers, backlog, keep-alive, graceful shutdown and, where
supported, `reuseport` listen URLs. The OS posture is on `/metrics`, in
readiness (`os_preflight`) and in the platform check, with warnings for an
excessive web worker count. Enforcement and production profiles are in
[OS_RUNTIME_ENFORCEMENT.md](OS_RUNTIME_ENFORCEMENT.md), captured runtime
evidence in [OS_RUNTIME_EVIDENCE.md](OS_RUNTIME_EVIDENCE.md), and the deploy
units in [DEPLOYMENT.md](DEPLOYMENT.md).

## Evidence and how to reproduce it

### Datasets

`script/seed-benchmark --profile NAME` writes a deterministic dataset:
users, roles, permissions and bindings, sessions, categories, threads,
posts with bodies and revisions, counters, search documents, read state,
bookmarks, subscriptions, notifications, feed items, reports and moderation
actions, with fixed UUIDv7-like ids. It clears its own fixture rows first,
so running profiles one after another on the same database is idempotent
and leaves the last one. `script/seed-performance-data` is the older name
for the same command; `--users`, `--categories`, `--threads` and
`--posts-per-thread` make a custom size.

| Profile | Users | Categories | Threads | Posts per thread | For |
| --- | ---: | ---: | ---: | ---: | --- |
| `small` | 5 | 3 | 12 | 8 | CI and quick checks |
| `medium` | 25 | 8 | 120 | 15 | hot-path plans |
| `hot-thread` | 10 | 3 | 30 | 120 | long threads, deep thread pages |

The seeded routes are `/`, `/categories`,
`/c/018f1001-0001-7000-8000-000000000001`,
`/t/018f1004-0001-7000-8000-000000000001`, `/search?q=performance`,
`/search/autocomplete?q=per`, `/health/ready` and `/metrics`. None of the
profiles is the reference dataset the quality program asks for (1M threads,
20M posts, 200k users, a 50k-post thread); the plan tests build what they
need on top of the small seed (20,000 search documents, a 3,000-post thread,
a 1,500-thread category).

### Reproduce

```sh
script/bootstrap-deps --postgres
script/gpforum-carton exec bin/gpforum-migrate --apply
script/seed-benchmark --profile medium
script/query-budget --sync

script/query-plan-check                  # static half; the plans too when GPFORUM_DATABASE_DSN is set
script/query-plan-evidence --check --profile medium
script/query-budget --check
make integration                         # plans, budgets, page cache, migrations, on PostgreSQL

script/benchmark-http --configured --check --iterations 20 --warmup 3 --profile medium
script/benchmark-http --fixture --check --iterations 5 --warmup 1 \
  --route /health/live --route /categories
```

`script/benchmark-http` drives the app in process through `Test::Mojo`, one
client, warmup apart from the measured requests. `--configured` uses the
configured PostgreSQL and the seeded routes; `--fixture` uses fixture
services and no database, so it measures routing and rendering only. With no
`--route` it runs the eight routes above plus `/health`. In fixture mode
`/health/ready` answers 503 (there is no database) and fails its route, so
the default set exits 1 there: run the fixture gate with explicit routes, as
CI does. In configured or production mode an anonymous `/health` answers
the status alone, without the OS, socket and process snapshots, so `/health`
figures measured since 2026-10-03 time that fast path and do not compare with
older ones; fixture runs without a token still time the full summary. `script/bench-hotpaths` is `benchmark-http --fixture --check` with
your arguments. Thresholds by endpoint:

| Endpoint | p95 | p99 | Minimum req/s |
| --- | ---: | ---: | ---: |
| home | 750 ms | 1,500 ms | 1 |
| categories | 500 ms | 1,000 ms | 1 |
| category, thread, search, autocomplete, and any other route | 1,000 ms | 2,000 ms | 1 |

They are hundreds of times looser than the measured values (quality program
8.8): they catch a broken route, not a slow one. The comparison that catches
a regression is the saved baseline:

```sh
mkdir -p var    # the benchmark does not create the baseline's directory
script/benchmark-http --configured --json --write-baseline var/benchmark-baseline.json
script/benchmark-http --configured --check --baseline var/benchmark-baseline.json
```

It compares p95, p99 and req/s route by route, with `--regression-tolerance`
0.25 by default, and a route missing from the baseline fails, so coverage
cannot shrink silently. On an anonymous configured run, the category, thread
and category-index pages are page-cache hits after the warmup: they measure
the cache, not PostgreSQL.

Against real processes:

```sh
# a temporary Hypnotoad on a free port, query-count headers on
script/bench-hypnotoad --check --profile medium --workers 4 \
  --iterations 10 --warmup 2 --route / --route /t/018f1004-0001-7000-8000-000000000001
# the same routes across worker counts: run it before raising GPFORUM_WEB_PROCESSES
script/bench-hypnotoad-scaling --seed --check --profile hot-thread \
  --worker-set 2,4,8 --iterations 20 --warmup 3 --route /categories \
  --route /t/018f1004-0001-7000-8000-000000000001 --route '/search?q=performance'
# concurrent clients against a running deployment; not part of make check
script/stress-load --dry-run --profile 100 --human
script/stress-load --profile 1000 --base-url https://forum.example --check --json
```

`bench-hypnotoad` also runs behind a local nginx or HAProxy
(`--reverse-proxy --proxy auto`, see [BASELINE.md](BASELINE.md)), and the
scaling run records the reactor class: macOS reports
`Mojo::Reactor::Poll`, so compare high socket concurrency with a host where
`EV` is installed. `stress-load` profiles are `smoke`, `100`, `500` and
`1000` in-flight requests ([ops/stress-load.md](ops/stress-load.md)); a
single address hits the `forum_retrieval` read limit (60 per 60 s) unless
`GPFORUM_FORUM_READ_RATE_LIMIT` is raised for the run.

```sh
mkdir -p artifacts    # nor does this benchmark create its artifact's directory
script/gpforum-carton exec script/bench-outbox-dispatcher --messages 1000,10000,100000 \
  --workers 1,2,4,8 --batch-size 100 --json --artifact artifacts/outbox-dispatcher.json
```

The outbox benchmark runs the real dispatcher against in-memory doubles. It
is a Perl script, not a wrapper like the other benchmark commands, so it runs
through `gpforum-carton`, as `performance.yml` runs it. It proves the
invariants -- `status=ok`, `lost=0` (no message left undelivered),
`duplicates=0` -- and records how long each `dispatch_pending` call takes
(`p95_claim_ms`): a whole batch, its claim, its dispatches and, for each
message, the renewal and the acknowledgement. `acknowledged` counts the
messages acknowledged, one by one, and must equal the messages; a run where
it does not reports `status=fail`. `claimed_batches` counts the batches
claimed (it was called `ack_batches` when a batch was acknowledged with one
statement). Its messages per second are the dispatcher's own overhead,
not PostgreSQL's; [The outbox claim](#the-outbox-claim) has PostgreSQL's.
Row locking on PostgreSQL is covered by the claim's SQL contract and the
plan gate's `outbox_claim`.

### Current results

Taken on 2026-10-03 on the development laptop (Apple arm64, 10 cores,
Perl 5.44.0, PostgreSQL 18.6 from Homebrew), each on a fresh migrated
database:

- **Plan gate:** `query-plan-check` with a DSN: `status=ok indexes=26
  offset_violations=0 db_evidence=ok`. `query-plan-evidence --check` passes
  all 20 endpoints on the `small`, `medium` and `hot-thread` seeds. The deep
  pages warn `shallow_page` except `home_deep` on `medium` and the thread
  pages on `hot-thread` (59 rows before the cursor, filtering 0 rows on the
  first page and 1 on the deep one); the signed-in category pages on
  `medium` warn `seq_scan_small_table:threads`.
- **Configured HTTP, `medium` seed, 20 requests after 3 warmup, one client,**
  two runs with other work on the machine: the spread in milliseconds is
  that noise, the statement counts were the same in both.

  | Route | p95 ms | Statements | Note |
  | --- | ---: | ---: | --- |
  | `/` | 13.9 to 15.3 | 1 | not page-cached |
  | `/categories`, `/c/...`, `/t/...` | 1.9 to 11.1 | 0 | page-cache hits |
  | `/search?q=performance` | 21.9 to 27.4 | 1 | in a transaction, for its timeout |
  | `/search/autocomplete?q=per` | 6.7 to 7.1 | 1 | the same |
  | `/health/ready` | 6.4 to 10.1 | 5 | no budget |
  | `/metrics` | 7.6 to 9.9 | 6 | no budget then; one statement sent twice (since fixed: 5 statements, budget `metrics`) |

- **Fixture HTTP:** p95 from about 1 ms (`/metrics`) to under 10 ms (search)
  per route; `/health/ready` 503 as described above.
- **Outbox dispatcher on the doubles:** 1,000 and 10,000 messages with 1, 4
  and 8 workers, every message delivered once, about 70,000 msg/s, p95 claim
  about 1.5 ms. On 2026-10-08, once each message renewed its claim and was
  acknowledged on its own, the same runs gave about 37,000 msg/s and 3 ms a
  batch, where the code before gave 138,000 msg/s and 0.7 ms that afternoon.

### Where a signed-in page's time goes

Taken on 2026-10-08 on the development laptop (Apple M4: four performance
and six efficiency cores; PostgreSQL 18 from Homebrew), `medium` seed,
Hypnotoad with 4 and then 8 workers, ApacheBench without keep-alive (its
HTTP/1.0 keep-alive stalls against Hypnotoad), one address with the read
rate limit raised.

| Page | One client | 4 workers, max req/s | 8 workers, max req/s |
| --- | ---: | ---: | ---: |
| Thread, anonymous (page-cache hit) | 1-2 ms | 4,300 | 3,100 |
| Home, anonymous (2 statements) | 20 ms | 177 | 255 |
| Thread, signed in (8 statements) | 32 ms | 110 | 124 |
| Search | 32 ms | 130 | -- |

Under the signed-in load the workers used about six cores and PostgreSQL
one sixth of one; no table was written per request and no backend waited on
a lock. The server is bound by Perl's CPU, and from 4 to 8 workers it gains
little because the added cores are the efficiency ones and the cost of a
request rises to about 55 ms of CPU under contention. The p95 of 3.5 to 4.7
seconds at 1,000 clients recorded above is this throughput's queue (1,000
in flight at 120 a second), not a defect on the page.

NYTProf on 20 signed-in thread pages (15 posts), before the changes below:
the 8 statements took 2.5 ms; DBIx::Class took seven times that to build
them; rendering took 60%, of which 74 `render` calls (an `include` is one
each: a post, its three sheets, its report form, its time), 61 `url_for`,
923 escapes and 243 `t()` lookups. `BodyRenderer` took 0.8 ms for 15 posts,
not the 5.7 ms recorded in May.

What changed on that evidence: the posts of a thread are one partial whose
sheets and report form are blocks and whose time is the `ui_timestamp`
helper (the `include` count fell from 74 to 16); the i18n service resolves
each message once per process and skips interpolation when a message has no
placeholder; on Apple silicon the automatic worker count takes a performance
core as one worker and two efficiency cores as one. The signed-in thread
page went from 32.5 to 26.7 ms; category and home, which were already one
partial each, stayed at about 20 ms.

Since then: the two statements are prepared (below), and every path a
template writes for a named route goes through `ui_path`, which renders the
route without the URL object `url_for` builds and parses (146 calls across
the templates; `url_for` remains where a query or a fragment is added); the
signed-in thread page is at 19.7 ms, the category page at 16.4 and the home
at 18.3. Measured again on 2026-10-08 with 4 workers
and 32 clients: 156 signed-in thread pages a second without keep-alive
(ApacheBench; 110 before this work) and 172 with it (`curl --parallel`,
which reuses its connections; ApacheBench's HTTP/1.0 keep-alive stalls
against Hypnotoad), 4,770 cached pages a second with keep-alive.

The six statements over budget on a cold worker's first request were not
the page's: they are the connection's own, the session settings every
connection runs once it is made (`Config::database_session_settings`:
timeouts, application name, message locale, search similarity). The
statistics now know them by their text and count them as the connection's
(`connection_queries`, `total_connection_queries`), so a worker's first
request is 7 statements like every other and keeps its budget.

### Prepared statements

The two statements a thread page runs most, the thread's row and its page of
posts, are built by DBIx::Class once per shape and run again with the
request's values (`GPForum::Infrastructure::PreparedQuery`): the SQL is
DBIx::Class's own text and never sees a value, every value is a bind, and a
request fills only the slots bound for its columns and the page size; every
other slot keeps the constant the resultset bound. A shape is what changes
the text: the viewer's standing, whether their own deleted posts are listed,
whether a cursor bounds the page. A statement whose slots are not those is
not kept and the resultset runs as it is; so does a reader built on a test
double. `t/integration/postgres-prepared-queries.t` holds every shape to
the resultset's rows, column for column, and counts the statements the
statistics see. In process, the signed-in thread page went from 26.7 to
22.5 ms and the category page from 21.1 to 19.5.

### Fragments

The thread page can ask for the part of itself an action changed instead of
the page: a request with `HX-Request: true` (the header htmx sends; the
library is served from `assets/js` and the page carries `hx-` attributes)
gets a fragment with no layout and never from the public cache. `GET /t/ID`
answers the posts and the way on; a reply answers the new post, a composer
with a fresh command id and the message, each marked for its place with
`hx-swap-oob`; following, muting, bookmarking, marking as read and
reporting the thread answer the toolbar; editing, deleting, restoring and
reporting a post answer that post; a new title, another category, deletion
and restoration answer the page's head, with the breadcrumbs, the notices
and the composer's place out of band, since each may have changed. A request
that fails gets its message
for the message's place and `HX-Reswap: none` for the target, so the page
keeps what it had. A browser without the script sends no header and gets
the page or the redirect as before (`t/480-thread-fragments.t`). In process, the next page of posts
cost 21.6 ms as a fragment against 26.6 ms as a page: the posts are most of
either. The gain is on the actions, which no longer render the page at all.

### Rendering

With the statements prepared and the paths written through `ui_path`,
NYTProf on the signed-in thread page (25 posts of a 120-post thread, 79 KB)
said rendering was 62% of the request and the database 10%, and inside the
rendering most of the time went to values that do not change between
requests, or between the forms of one page. ADR 0121 records the decision;
this is what changed, each held to the page it replaced: the HTML and the
headers of fourteen pages, anonymous and signed in, with the per-request
values masked, are the same before and after.

- `csrf_field` on each of the page's 33 forms masked the session's token
  anew against BREACH, and each mask opened `/dev/urandom` (Mojolicious reads
  it there without `Crypt::PRNG`): 33 opens a request. The token is masked
  once per response and the field written once; one mask per response
  protects as well, since BREACH compares responses with each other.
- Each of 25 timestamps built two `DateTime` objects in the viewer's zone
  and formatted three strings. The strings are kept by locale, zone and
  value (`GPForum::Service::I18N::Formatter`, 8,192 entries); a miss builds
  one object.
- 365 `t()` lookups went through seven subroutines to read one hash entry;
  a plain message is now read from the service's resolved table in one step.
- 64 route paths each walked the route's chain and every token of every
  pattern; a route is read once into a writer and a path is a join.
- The four asset URLs built a URL object each; they are strings kept by base
  path and name. Rendered post bodies are kept by source (2,048 entries).
- The response was gzipped at zlib level 6 through `IO::Compress::Gzip`
  (1.6 ms, 0.3 of them the module's layers); it is gzipped at level 3
  through `Compress::Raw::Zlib`, one stream per process reset between
  responses (0.7 ms, 900 bytes more).
- The viewer's read state, bookmark and subscription for the thread, and the
  session the cookie names, were `find`s built by DBIx::Class on every
  request; they go through `PreparedQuery` like the posts, as do the
  category, the post (listed, visible, or by id, for the store too) and
  the attachment by their ids. `PreparedQuery` also sends no statement for
  a value bound to a uuid column that PostgreSQL would not read as one:
  `/t/anything` is a 404 before any statement, where PostgreSQL refusing
  the bound value answered 500 and wrote the error log.
- The attachments of a page's posts, an IN list of post ids, were the one
  statement still built per request; `PreparedQuery` binds a list once per
  element, kept by page size (`attachment_links:posts:25`). A post's
  fifteen columns are read with one `get_columns` call rather than fifteen
  `get_column` calls dispatched by the row's kind.
- Every worker compiled the page's templates on its first request (the home
  page's first request took 95 ms under `prefork`, the second 16). The
  manager renders the main pages before it forks (`GPForum::Web::Warmup`,
  `GPFORUM_WARMUP_ENABLED`); the first request to a worker takes 21.

In process, the signed-in thread page went from 24.7 to about 14 ms, the
category page from 15.1 to about 12, the home page from 17.5 to about 12
and the anonymous cached page from 2.7 to 1.8; NYTProf's profiled time per
request fell from 65 to 37 ms, with `DateTime`, the formatter and the
random reads gone from it. What is left is the templates' own code (a
quarter of the request), an escape per expression (1,269 a page, a
subroutine call each) and the 8 statements' round trips.

### Where the evidence lives

| Evidence | Where |
| --- | --- |
| Plans, budgets, page cache, feed fan-out and migrations on PostgreSQL | `t/integration/postgres-{search-plan,viewer-plan,query-plan-depth,query-budget,public-cache,feed-projection,migration-concurrently}.t`, run by `make integration` |
| The plan gate's own logic | `t/54-query-plan-evidence.t`, `t/47-query-plan-check.t` |
| Realtime fan-out across processes, and the bounded polling backstop | `t/85-realtime-outbox-multiprocess.t`; [realtime.md](realtime.md) |
| 100, 500 and 1,000 concurrent clients | [ops/stress-load.md](ops/stress-load.md), JSON under [ops/evidence/](ops/evidence) |
| OS and runtime posture | [OS_RUNTIME_EVIDENCE.md](OS_RUNTIME_EVIDENCE.md) |
| Nightly JSON and a NYTProf profile | `.github/workflows/performance.yml`, kept as artifacts |
| The May 2026 tables | git history: `git show 0d0ec4a:docs/PERFORMANCE_EVIDENCE.md`, and `PERFORMANCE_BASELINE.md` and `DB_PERFORMANCE.md` at the same commit |

The load evidence, from a 4-vCPU Linux VM with PostgreSQL 16 and the
`medium` seed (2026-09-20): `smoke`, `100` and `500` pass; `1000` held 1,000
requests in flight with no HTTP error but failed the 2 s p95 gate in every
run, from 2.1 s to 4.7 s with 4 workers. A re-run with 8 workers gave 3.5 s,
better than the 4.7 s run it was compared with, and 16 workers 5.2 s,
oversubscribing the four CPUs. Without a raised read limit, `100` gets 429s
(about 8%).

The May 2026 tables are superseded: measured on Perl 5.42 and Postgres.app,
one client, before the page cache answered ahead of the queries, the keyset
bound, the search cap and the budgets above. They showed single-digit
millisecond p95 on every route, 1 or 2 statements on the thread page and
search, no duplicate statement, and no change in statement counts between
2, 4 and 8 Hypnotoad workers.

`ci.yml` runs the static and EXPLAIN plan gates, the budget sync and check,
a fixture smoke, a configured smoke and a two-worker Hypnotoad smoke on the
`small` seed; `performance.yml` runs the wider set nightly and keeps the
JSON. Neither starts today -- the Actions jobs do not run (the account's
budget) -- so every gate above is run locally.

## Open work

Tracked in [QUALITY_PROGRAM.md](QUALITY_PROGRAM.md); the performance items:

- the reference dataset (1M threads, 20M posts, 200k users), built by one
  command;
- p95 within budget at 1,000 clients, scaling with workers;
- benchmarks with concurrent clients rather than one serial client, and a
  `pg_stat_statements` comparison in CI that fails a 20% regression;
- `LISTEN` on a dedicated connection, so PgBouncer can pool the rest
  (ADR 0111);
- post bodies rendered once (8.4); a byte bound on the cache; the page cache
  for the home page, profiles and feeds;
- an outbox soak on PostgreSQL at 1M messages, a websocket fan-out benchmark
  with slow clients, and a long-running memory drift check on thread
  rendering.
