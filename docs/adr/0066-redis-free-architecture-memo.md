# ADR 0066: Redis-Free Architecture Exploration

## Status

Accepted. Converted on 2026-09-19 from `prompt/18.txt` ("GPForum -
Redis-Free Architecture Exploration Memo"); this ADR replaces the prompt as
the binding source.

The source is an exploration memo, not a rule set. It records the reasoning
that led to the PostgreSQL-centric, Redis-optional coordination model. The
binding cache and coordination rules are in ADR 0067, which prevails where
the two differ.

## Context

The memo (written in Italian, translated here) answered whether GPForum can
run without Redis. Dropping Redis requires a different architectural
philosophy: PostgreSQL and Perl together become the persistence layer, the
distributed coordination layer, and the cache orchestration layer. The memo
judged this harder, but more elegant and more coherent with the Perl-first
approach (ADR 0049, ADR 0052).

It concerns infrastructure, caching, events, workers, and realtime.

## Decision

The memo concluded:

### Target Architecture

GPForum is built on PostgreSQL, Perl event orchestration, shared-memory
local caches, and event propagation, without Redis as a required component:

| Concern | Mechanism |
| --- | --- |
| Canonical state | PostgreSQL |
| Event persistence | `event_log` |
| Distributed signaling | PostgreSQL LISTEN/NOTIFY |
| Local caches | per-node in-memory caches |
| Realtime sync | Perl websocket nodes |

### Signaling Instead Of Redis

- PostgreSQL LISTEN/NOTIFY is the distributed pub/sub backbone. Example:
  node A issues `NOTIFY post_created`; node B invalidates its local cache;
  node C pushes a websocket update.
- LISTEN/NOTIFY is not Kafka: payloads are small, throughput is limited,
  and delivery is transient. NOTIFY is signaling, not event persistence.
  Event persistence stays in `event_log`.

### Coordinated Local Caches

- The model is coordinated local caches, not a centralized distributed
  cache.
- Every Perl node keeps in-memory local caches with short TTLs,
  event-driven invalidation, and fast rebuild.
- Caches are local, disposable, and synchronized by events.
- Candidate building blocks: CHI, Mojo::Cache, a custom LRU, shared
  memory, possibly mmap. Preferred direction: a custom GPForum cache
  subsystem, because caches must be permission-aware, event-driven, and
  projection-aware.

### Reference Workflow

1. `post.created`
2. `event_log` append
3. NOTIFY
4. nodes invalidate local caches
5. workers rebuild projections
6. websocket propagation

### Critical Rule

- Caches MUST be fully disposable, always. Losing every cache is not a
  problem: replay, rebuild, and restart.

### Adopt And Reject

- Adopt: PostgreSQL LISTEN/NOTIFY; local caches; `event_log`; projection
  rebuild; Perl orchestration.
- Reject: Redis as a database; a giant distributed cache mesh; opaque cache
  clusters.

### Resulting Direction

- GPForum becomes a PostgreSQL-centric, Perl-native, event-driven
  distributed coordination platform.

## Alternatives Considered

- Redis everywhere as a centralized distributed cache: rejected. It adds
  moving parts (Redis cluster, failover, persistence, memory tuning) and
  is less coherent than coordinated local caches. ADR 0067 later kept
  Redis/KeyDB as optional, disposable acceleration rather than banning it.
- Redis as a database: rejected.
- Giant distributed cache mesh or opaque cache clusters: rejected.
- LISTEN/NOTIFY as a durable event log or Kafka substitute: rejected
  because of small payloads, limited throughput, and transient delivery.
- Generic cache libraries alone (CHI, Mojo::Cache, custom LRU, shared
  memory, mmap): usable as building blocks, but a GPForum-specific
  permission-, event-, and projection-aware cache subsystem is preferred.

## Consequences

- Fewer moving parts: no Redis cluster, failover, persistence, or memory
  tuning. The backbone is only Perl and PostgreSQL, in a Unix-like style.
- More work on the Perl side: cache invalidation, local coordination,
  replay, and stale-data policies must be implemented and tested.
- Missed NOTIFY signals are tolerable only because caches are disposable
  and `event_log` is durable; recovery rules are fixed in ADR 0067.
- Open conflict: the memo rejects cache clusters and relies on per-node
  caches, while ADR 0048 makes a shared GlifiStore L2 mandatory in staging
  and production. GlifiStore stays disposable and fail-open, so correctness
  is unaffected, but the required shared cache process departs from the
  "coordinated local caches only" direction.

## Alignment

- ADR 0067 (binding cache, coordination, and Redis decision), ADR 0050
  (infrastructure), ADR 0055 (event-driven realtime), ADR 0056 (workers),
  ADR 0090 (PostgreSQL-native search).
- ADR 0006 (LISTEN/NOTIFY realtime transport), ADR 0009 (outbox retry),
  ADR 0048 (GlifiStore L2).
- `lib/GPForum/Service/Realtime/PgListener.pm`,
  `lib/GPForum/Service/Realtime/PgNotifier.pm`,
  `lib/GPForum/Service/Operations/LocalCache.pm`
- `docs/realtime.md`, `t/40-local-cache.t`
