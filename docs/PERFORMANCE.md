# GPForum Performance Readiness

Date: 2026-05-28.

This freeze keeps the product surface unchanged and focuses on vertical
throughput for a single Mojolicious + PostgreSQL deployment.

## Outbox Hot Path

The outbox dispatcher uses PostgreSQL as the source of truth and claims work in
one transactional SQL statement:

* ready `pending` and `failed` rows are filtered by `next_attempt_at <= now()`;
* stale `running` rows are reclaimable when `locked_until <= now()`;
* rows are ordered by `next_attempt_at, created_at, outbox_id`;
* `FOR UPDATE SKIP LOCKED` lets multiple workers consume without global locks;
* the same statement marks rows `running` with `locked_at`, `locked_until`, and
  `locked_by`;
* the update CTE returns the claimed rows, while dispatcher compatibility keeps
  `transport->dispatch($message)` unchanged.
* the PostgreSQL hot path wraps returned rows in lightweight DBI-backed message
  objects and avoids a DBIx::Class reload after claim;
* successful dispatches are acknowledged with one batch `UPDATE` per claimed
  worker batch instead of one `UPDATE` per message.

Supporting partial indexes:

```sql
idx_outbox_messages_claim_ready
idx_outbox_messages_pending_ready
idx_outbox_messages_failed_ready
idx_outbox_messages_stale_locks
```

## Benchmark

Smoke run:

```sh
script/bench-outbox-dispatcher
```

Full reproducible matrix:

```sh
mkdir -p artifacts
script/bench-outbox-dispatcher \
  --messages 1000,10000,100000 \
  --workers 1,2,4,8 \
  --batch-size 100 \
  --json \
  --artifact artifacts/outbox-dispatcher.json
```

Latest local fixture result:

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

The fixture benchmark proves dispatcher invariants and throughput shape. Real
PostgreSQL lock behavior remains covered by the generated SQL contract tests and
DB-backed query-plan evidence when `GPFORUM_DATABASE_DSN` is configured.

## Query Plan Gate

The static and configured DB gate is:

```sh
script/query-plan-check
```

Without a DSN it verifies required hot-path indexes and rejects `OFFSET` in
application/template hot paths. With `GPFORUM_DATABASE_DSN`, it also runs:

```sh
script/query-plan-evidence --check --analyze --profile medium
```

The evidence set covers home, category threads, thread view, search,
autocomplete, feed, notifications, outbox claim, moderation queue, readiness,
and metrics.

## Public Read Cache

Anonymous public SSR for categories, category pages, and thread pages is cached
through `GPForum::Web::PublicHttpCache`. Cacheability and ETag/Last-Modified
freshness are decided by `GPForum::Web::PublicCacheAccess`. The cache is
a disposable L1/L2 stack (`LocalCache` plus required GlifiStore), TTL-bounded,
and max-entry bounded; PostgreSQL readers and view models remain the source of
truth.

The response contract is reverse-proxy friendly:

* `Cache-Control: public, max-age=N, stale-while-revalidate=N`;
* weak `ETag` generated from the rendered HTML body;
* `Last-Modified` from the cache entry creation time;
* `Vary: Accept, Cookie` so authenticated sessions do not share anonymous HTML;
* `304 Not Modified` when `If-None-Match` or `If-Modified-Since` proves the
  client copy is fresh.

Cache tags are attached as `forum:public-html`, `forum:categories`,
`forum:category:<id>`, and `forum:thread:<id>` so existing event/outbox-driven
cache invalidation can discard stale local entries without making cache state
authoritative.
