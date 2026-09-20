# ADR 0067: Cache, Coordination And Redis Decision

## Status

Accepted. Converted on 2026-09-19 from `prompt/19.txt` ("GPForum - Cache,
Coordination & Redis Decision Constitution"); this ADR replaces the prompt
as the binding source.

## Context

The Redis/KeyDB versus PostgreSQL-centric design discussion (ADR 0066) left
open whether a shared in-memory store is required for correctness. This ADR
resolves the cache and distributed coordination philosophy. It is
foundational and mandatory and governs persistence, events, workers,
realtime, search, and every cache in every bounded context.

## Decision

### Cross-ADR Alignment

- ADR 0101: search caches, feed caches, autocomplete caches, and metadata
  caches are optional acceleration only. They MUST be disposable, bounded,
  scope-safe, permission-safe, moderation-safe, and event-invalidation
  aware; cache loss MUST NOT change retrieval correctness.

### Decision

- GPForum MUST be PostgreSQL-authoritative and Perl-orchestrated.
- Redis or KeyDB is OPTIONAL infrastructure, not mandatory business
  infrastructure.
- The canonical coordination model is:
  - PostgreSQL for durable state;
  - event tables for replayable workflows;
  - PostgreSQL LISTEN/NOTIFY for lightweight signaling;
  - Minion for durable asynchronous jobs;
  - local in-memory caches for per-node acceleration;
  - PostgreSQL-native search projections orchestrated by Perl.
- Redis or KeyDB MAY be introduced only as ephemeral acceleration when the
  operational value justifies the additional moving part.

### Non-Negotiable Rule

- No business-critical state may exist only in Redis, KeyDB, process
  memory, websocket memory, or optional external search systems.
- All critical state MUST be recoverable from PostgreSQL.

### PostgreSQL Role

- PostgreSQL is responsible for: authoritative persistence;
  append-oriented event history; transactional integrity; audit trails;
  durable read-model rebuild sources; retention and partitioning.
- PostgreSQL MUST NOT be abused as: a high-volume message broker; a
  websocket fanout engine; an unbounded transient queue; a dumping ground
  for ephemeral presence noise.

### LISTEN/NOTIFY Role

- LISTEN/NOTIFY is a signaling mechanism.
- It MAY be used for: cache invalidation hints; lightweight node wakeups;
  projection refresh hints; realtime dispatch hints; operational
  coordination signals.
- It MUST NOT be used as: durable event storage; a guaranteed message
  queue; a replacement for event tables; a replacement for Minion jobs; a
  bulk data transport.
- Every NOTIFY payload SHOULD contain only: event identifier; entity type;
  entity id; version or timestamp; correlation id where available.
- Consumers MUST fetch authoritative data from PostgreSQL when needed.

### Event Table Role

- Durable domain events MUST be stored in PostgreSQL event tables.
- Event tables MUST support: replay; idempotency; ordering by aggregate
  where required; correlation; projection rebuild; audit investigation.
- NOTIFY may announce an event, but the event table is the durable source.

### Local Cache Role

- Application nodes MAY maintain local in-memory caches.
- Local caches MUST be disposable, bounded, TTL-controlled,
  invalidation-aware, and safe to lose at any time.
- Local caches MAY store: rendered fragments; permission-safe lookup data;
  short-lived configuration snapshots; hot category/thread metadata;
  rate-limit hints when backed by authoritative checks.
- Local caches MUST NOT store: unrecoverable user content; authoritative
  sessions; final authorization decisions without context; unique counters
  requiring exactness; moderation state as the only source.

### Redis/KeyDB Optional Use

- Redis or KeyDB MAY be used for: high-volume ephemeral rate limiting;
  websocket fanout acceleration; short-lived presence; cross-node cache
  acceleration; operationally isolated pub/sub.
- Redis or KeyDB MUST remain disposable, reconstructable,
  non-authoritative, and removable without data loss.
- If Redis becomes required for correctness, the design is invalid.

### Cache Invalidation

- Cache invalidation MUST be event-driven where possible.
- Invalidation inputs MAY include: PostgreSQL events; LISTEN/NOTIFY
  signals; Minion job completion; explicit administrative invalidation;
  TTL expiry.
- Permission-sensitive fragments MUST use conservative cache keys.
- Cache keys SHOULD include: entity type; entity id; visibility version;
  permission scope where needed; language or locale where needed; theme
  variant where needed.

### Failure Behavior

- If all local caches are lost, GPForum MUST continue operating.
- If LISTEN/NOTIFY messages are missed, nodes MUST recover through: TTL
  expiry; version checks; event table polling; projection reconciliation.
- If Redis exists and fails, GPForum MUST degrade gracefully.

### Final Architecture

- The preferred architecture is PostgreSQL-centric, Perl-native,
  event-table durable, LISTEN/NOTIFY signaled, local-cache accelerated,
  Minion-orchestrated, and Redis-optional.
- This decision supersedes any interpretation that makes Redis/KeyDB
  mandatory for correctness.

## Alternatives Considered

- Redis/KeyDB as mandatory shared cache and message layer: rejected; it
  adds a required moving part and risks hidden authority outside
  PostgreSQL.
- No Redis/KeyDB under any circumstances (the ADR 0066 memo position):
  softened; Redis/KeyDB remains allowed as disposable acceleration for
  ephemeral workloads.
- LISTEN/NOTIFY as the durable event channel: rejected; it is transient
  signaling, so event tables and Minion jobs carry durability.

## Consequences

- Correctness depends only on PostgreSQL; any cache, Redis/KeyDB instance,
  or websocket node can be lost without data loss.
- Missed signals are repaired by TTLs, version checks, event table polling,
  and projection reconciliation, so every consumer needs a polling or
  reconciliation path, not only a NOTIFY listener.
- Versioned cache keys (visibility, permission scope, locale, theme) raise
  key cardinality but prevent permission and moderation leaks.
- PostgreSQL must be protected from broker-like load: fanout, presence, and
  bulk transient traffic stay out of it.
- Open conflict: ADR 0048 makes the GlifiStore shared L2 mandatory in
  staging and production (fail closed when `GPFORUM_GLIFISTORE_URL` is
  missing), while the canonical model here lists only local in-memory
  caches plus optional Redis/KeyDB. ADR 0048 keeps GlifiStore disposable,
  fail-open, and non-authoritative, so the non-negotiable rule holds, but
  the canonical model should either name the shared L2 or ADR 0048 should
  be revisited.
- Open conflict: `t/09-prompt-alignment.t` slurps `prompt/19.txt` to check
  the ADR 0101 alignment clause; it must be repointed to this ADR before
  the prompt files are deleted.

## Alignment

- ADR 0066 (Redis-free exploration), ADR 0050 (infrastructure), ADR 0051
  (database), ADR 0055 (event-driven realtime), ADR 0056 (workers and
  queues), ADR 0063 (performance and scalability), ADR 0090
  (PostgreSQL-native search, co-authoritative final decision), ADR 0099
  (projection stability), ADR 0101 (retrieval execution).
- ADR 0006 (LISTEN/NOTIFY realtime transport), ADR 0009 and ADR 0025
  (outbox retry and claim), ADR 0012 (operational profiles), ADR 0019
  (public HTTP cache), ADR 0048 (GlifiStore L2).
- `lib/GPForum/Service/Operations/LocalCache.pm`,
  `lib/GPForum/Service/Operations/TieredCache.pm`,
  `lib/GPForum/Service/Operations/SharedCache.pm`,
  `lib/GPForum/Service/Operations/CacheFactory.pm`,
  `lib/GPForum/Service/Realtime/PgListener.pm`,
  `lib/GPForum/Service/Realtime/PgNotifier.pm`
- `t/40-local-cache.t`, `t/89-tiered-cache.t`, `t/142-cache-factory.t`,
  `t/09-prompt-alignment.t`
- `docs/realtime.md`, `docs/architecture/operational-profiles.md`,
  `EVENTS.md`
