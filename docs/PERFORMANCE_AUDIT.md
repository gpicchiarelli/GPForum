# GPForum Performance Audit

Date: 2026-05-28.

Scope: vertical throughput on one VPS with Mojolicious, Perl, PostgreSQL,
outbox/event-driven workers, disposable local cache, and no mandatory external
broker.

## Hot Path Ranking

| Rank | Area | Risk | Throughput | CPU | Memory | I/O |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 1 | Outbox dispatch | Queue throughput and duplicate delivery under worker concurrency. | high | medium | low | high |
| 2 | Thread view | Read-heavy page; post/body joins and repeated SSR dominate forum usage. | high | high | medium | medium |
| 3 | Category/home listings | High fan-in reads; must stay keyset/index-only where possible. | high | medium | low | medium |
| 4 | Search/autocomplete | PostgreSQL ranking/trigram paths can sort or scan under broad terms. | medium | high | medium | high |
| 5 | Notifications/feed | Per-user inbox/feed reads can amplify under active users. | medium | medium | medium | medium |
| 6 | Realtime fanout | Optional path; backpressure and coalescing prevent live updates dominating core forum reads. | medium | medium | medium | low |
| 7 | Upload/media | Large body handling and variant work must stay outside request hot paths. | low | medium | high | high |

## Findings

### Critical

1. Outbox must stay on SQL-direct hot paths.
   The dispatcher now uses atomic `FOR UPDATE SKIP LOCKED`, `UPDATE ...
   RETURNING`, lightweight DBI-backed claimed messages, and batch done ack.
   Remaining work: PostgreSQL-backed long-run soak at 1M messages with real
   lock contention and worker process RSS tracking.

2. Query-plan evidence must be a blocking gate.
   `script/query-plan-check` rejects hot-path `OFFSET`, verifies 31 required
   indexes, and runs `script/query-plan-evidence --check --analyze --profile
   medium` whenever `GPFORUM_DATABASE_DSN` is present.

3. Thread view rendering is the next likely throughput limiter.
   The query path is bounded/keyset. Public anonymous category, category-thread,
   and thread SSR now pass through bounded HTTP page cache with `ETag`,
   `Last-Modified`, `Cache-Control`, and `stale-while-revalidate` headers.
   Remaining work: expand the same posture to home/profile/feed fragments and
   add production hit-ratio evidence.

### High

4. Search broad queries need continued DB evidence.
   Existing GIN/trigram/partial indexes are present. Keep broad public search
   under query-plan evidence and add production `pg_stat_statements` review for
   high-frequency terms.

5. Realtime must remain accessory.
   LISTEN/NOTIFY plus outbox polling fallback is correct. Keep event envelopes
   small, coalesce badge updates, and disconnect slow websocket clients before
   they raise process memory.

6. DBIx::Class is acceptable outside hot loops.
   Keep writes and admin/low-volume CRUD in DBIx::Class. For hot reads/outbox
   claim/realtime fetch, prefer fixed SQL with bind parameters and evidence.

### Medium

7. Cache is present but not yet aggressive enough for 95-99% read traffic.
   Local cache is TTL/size bounded and disposable. Public anonymous SSR cache is
   enabled for categories, category pages, and thread pages with invalidation
   tags; home/profile/feed fragments still need the same treatment.

8. Profiling exists but needs a required workflow.
   `script/profile-nytprof`, benchmark JSON artifacts, DB query counters, and
   RSS sampling exist. Performance patches should attach at least one benchmark
   or NYTProf artifact.

## Roundtrip and Lock Notes

| Path | Current posture | Next pressure point |
| --- | --- | --- |
| Outbox claim | one SQL statement claims and locks a batch | real PostgreSQL 1M-message soak |
| Outbox success ack | one batch `UPDATE` per claimed worker batch | batch failed updates after classifying failures |
| Thread/category/home | bounded DBIx reader queries; anonymous category/thread HTML emits conditional GET validators | home/profile/feed fragment cache and hit-ratio evidence |
| Realtime fetch | outbox/LISTEN-NOTIFY with polling fallback | coalesced polling batches and slow-client drop metrics |
| Search | indexed PostgreSQL search projection | broad-term `pg_stat_statements` evidence |

## Next Ordered Work

1. Extend anonymous public HTTP cache/conditional GET to home, profile, feed,
   and reusable template fragments.
2. Add PostgreSQL-backed outbox soak mode for `script/bench-outbox-dispatcher`
   at 1M messages.
3. Add websocket fanout benchmark with slow-client backpressure assertions.
4. Archive benchmark JSON in CI artifacts and gate p95/query-count regressions.
5. Add PostgreSQL operations checklist for `pg_stat_statements`, autovacuum,
   bloat, and slow query review.
