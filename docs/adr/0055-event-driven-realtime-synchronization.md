# ADR 0055: Event-Driven, Realtime and Distributed Synchronization

## Status

Accepted. Converted on 2026-09-19 from `prompt/7.txt` ("GPForum —
Event-Driven, Realtime & Distributed Synchronization Constitution"); this ADR
replaces the prompt as the binding source.

## Context

GPForum runs on many application, websocket and worker processes that fail
independently and see each other's writes with delay. Without shared rules,
realtime and asynchronous propagation drift into hidden authority,
non-replayable side effects and single-node bottlenecks.

This ADR fixes the event-driven architecture, distributed synchronization
model, websocket strategy, asynchronous propagation rules, consistency
philosophy, realtime workflows, pub/sub topology and distributed
coordination principles. It governs domain events and the event log, the
outbox, realtime and websocket nodes, presence, pub/sub, read projections,
search synchronization and notification propagation. The rules are
foundational and mandatory; all future realtime and synchronization
development MUST comply with them.

## Decision

### Accessibility Alignment

Per ADR 0094, realtime behavior MUST remain accessibility-safe:

- Websocket updates MUST preserve focus and reading position, avoid
  live-region spam, provide understandable status, and degrade to polling or
  refresh without blocking core forum usage.
- Realtime is enhancement only and MUST NOT become a JavaScript-only
  accessibility dependency.

### Distributed Systems Philosophy

- GPForum MUST operate as distributed, event-driven, horizontally scalable
  and asynchronously coordinated.
- The platform MUST assume multiple application nodes, multiple websocket
  nodes, distributed workers, partial failures, network latency and eventual
  consistency.
- The architecture MUST prioritize decoupling, resilience, replayability,
  operational predictability and graceful degradation.

### Event-Driven Philosophy

- Events are foundational. All significant actions MUST emit events.
- Examples: `thread.created`, `thread.locked`, `post.created`,
  `post.edited`, `notification.sent`, `user.banned`, `session.revoked`,
  `attachment.uploaded`.
- Events MUST become synchronization primitives, audit primitives, workflow
  triggers and realtime propagation sources.

### Event Characteristics

- Events MUST remain immutable, timestamped, attributable, append-oriented
  and traceable.
- Events SHOULD support replayability, asynchronous propagation and
  observability.

### Event Ownership

- Business workflows MUST remain event-originating and MUST NOT be
  event-dependent for core persistence.
- Canonical writes MUST succeed before asynchronous propagation, websocket
  fanout, search indexing and notifications.
- The relational database remains authoritative.

### Event Log

- The system MUST implement an append-only `event_log`.
- The event log MUST support partitioning, replay, auditing, asynchronous
  consumption and distributed processing.
- Events MUST NEVER be silently mutated.

### Event Payload Philosophy

- Events SHOULD contain identifiers, timestamps, minimal authoritative
  metadata and traceability metadata.
- Events SHOULD avoid excessive duplication, giant payloads and embedded
  business authority.
- Payloads MAY use JSONB.

### Event Categories

- Recommended categories: domain, system, moderation, security, realtime and
  analytics events.
- Events SHOULD remain semantically explicit.

### Realtime Philosophy

- Realtime systems MUST remain eventually consistent, tolerate propagation
  delays, tolerate temporary disconnects and avoid centralized bottlenecks.
- Realtime functionality MUST enhance the platform but MUST NOT become the
  canonical persistence layer.

### Websocket Architecture

- Websocket nodes MUST remain stateless where possible, horizontally
  scalable, event-subscribed and lightweight.
- Websocket nodes MUST NOT own authoritative business state, execute heavy
  workflows or perform direct persistence orchestration.

### Realtime Node Separation

- The architecture SHOULD support dedicated websocket nodes.
- HTTP and websocket workloads MAY be separated operationally.
- The system MUST support distributed websocket clusters, multiple Perl
  realtime processes per realtime node, rolling node replacement and graceful
  disconnect recovery.

### Pub/Sub Philosophy

- Distributed synchronization SHOULD use Redis pub/sub, PostgreSQL
  LISTEN/NOTIFY, event propagation queues and worker-dispatched
  synchronization (see the Redis open conflict below).
- Pub/sub MUST remain transient, replay-tolerant and non-authoritative.

### Distributed Fanout

- Realtime fanout MUST support multi-node propagation, selective
  subscription delivery, channel isolation and scalable dissemination.
- The architecture MUST avoid single-node websocket ownership and
  centralized realtime bottlenecks.

### Presence System

- Presence data (online users, typing indicators, active sessions, websocket
  subscriptions) MUST remain ephemeral, disposable and reconstructable.
- Presence MUST NOT become authoritative business data.

### Realtime Consistency

- The realtime layer MUST tolerate eventual consistency, delayed
  propagation, duplicate delivery and reconnect replay.
- Strong consistency SHOULD NOT be required for notifications, presence,
  typing indicators and incremental UI updates.

### Idempotency Philosophy

- Asynchronous consumers MUST support idempotent processing.
- Duplicate event delivery MUST NOT corrupt state, create duplicated
  persistence or generate inconsistent side effects.

### Ordering Philosophy

- The architecture MUST NOT assume perfect global ordering across
  distributed nodes.
- Ordering guarantees SHOULD remain localized, bounded and
  workflow-specific.
- Event timestamps MUST remain authoritative.

### Distributed Failure Philosophy

- The architecture MUST assume websocket node crashes, delayed workers,
  temporary Redis outages, replica lag, dropped pub/sub messages and partial
  propagation failure.
- The system MUST degrade gracefully.

### Retry Philosophy

- Asynchronous workflows MUST support retries, exponential backoff, failure
  isolation and replay safety.
- Retries MUST remain observable, bounded and idempotent-aware.

### Distributed Locking

- Distributed locking SHOULD remain minimal, bounded and time-limited.
- Global locks SHOULD be avoided whenever possible.
- The architecture SHOULD prefer optimistic concurrency, append-oriented
  workflows and immutable event flows.

### CQRS-lite Philosophy

- The architecture SHOULD support lightweight CQRS patterns.
- Canonical writes go to PostgreSQL.
- Read projections MAY include cached aggregates, realtime projections,
  search indexes and websocket state.
- Read models MUST remain rebuildable.

### Search Synchronization

- Search indexing MUST occur asynchronously, event-driven and eventually
  consistent.
- Search indexing MUST tolerate delayed indexing, replay and partial
  rebuilds.

### Notification System

- Notifications MUST remain asynchronous, support distributed fanout and
  tolerate delayed delivery.
- Notification persistence MUST remain authoritative, replayable and
  audit-capable.

### Realtime UI Philosophy

- Realtime UI updates SHOULD incrementally update fragments, avoid full
  application hydration and remain server-authoritative.
- The frontend MUST tolerate websocket interruption, delayed updates and
  partial propagation.

### Replay Philosophy

- Critical event streams SHOULD support replay, reconstruction and recovery
  workflows.
- The architecture SHOULD support rebuilding projections, caches and
  indexes.

### Observability

- Distributed synchronization MUST expose propagation metrics, retry
  metrics, queue depth, websocket metrics, fanout metrics and delivery
  failures.
- Operational visibility is mandatory.

### Security of Realtime Systems

- Realtime systems MUST authenticate websocket connections, authorize
  subscriptions, validate payloads and rate limit abusive traffic.
- Pub/sub systems MUST assume hostile payload injection attempts.

### Scalability Philosophy

- Realtime scalability MUST prioritize horizontal scaling, event propagation
  efficiency, stateless nodes, bounded memory usage and incremental
  synchronization.
- The architecture MUST assume millions of concurrent connections,
  distributed websocket clusters and high-frequency event propagation.

### Long-Term Distributed Systems Goal

- Realtime and distributed architecture MUST remain resilient, replayable,
  horizontally scalable, operationally predictable, event-driven, eventually
  consistent where appropriate, and sustainable under extreme concurrency.
- The distributed layer is a synchronization system over authoritative
  persistence.

## Consequences

- A lost websocket node, dropped notification or stale projection is
  recoverable from PostgreSQL and the event log instead of losing product
  state.
- Every consumer must be idempotent and replay-safe, which costs extra
  bookkeeping (idempotency keys, offsets, generations) on each new consumer.
- Clients see eventual consistency for notifications, presence and fragment
  updates and must always have a polling or refresh fallback.
- Metrics for propagation, retries, queue depth, fanout and delivery failures
  become part of the definition of any new realtime path.
- Open conflict: the pub/sub list names Redis pub/sub first and the failure
  model assumes Redis outages, but ADR 0067 makes Redis/KeyDB optional
  ephemeral acceleration, ADR 0006 selects PostgreSQL LISTEN/NOTIFY with
  outbox polling and rejects Redis pub/sub as mandatory, and the repository
  has no Redis dependency. Redis pub/sub is therefore permitted only under
  ADR 0067, never required for correctness.

## Alignment

- ADR 0006, ADR 0007, ADR 0008, ADR 0009, ADR 0017, ADR 0025
- ADR 0051 (database), ADR 0053 (security), ADR 0054 (frontend),
  ADR 0056 (workers), ADR 0058 (observability), ADR 0062 and ADR 0090
  (search), ADR 0066 and ADR 0067 (Redis), ADR 0071 (event catalog),
  ADR 0078 (notification delivery), ADR 0094 (accessibility), ADR 0099
  (projection stability)
- `migrations/002_event_audit.sql` (`event_log`, `outbox_messages`,
  `event_idempotency_keys`), `migrations/023_realtime_outbox_polling.sql`
- `lib/GPForum/Infrastructure/EventRecorder.pm`,
  `lib/GPForum/Domain/EventEnvelope.pm`, `lib/GPForum/Service/Outbox/`,
  `lib/GPForum/Service/Projection/`, `lib/GPForum/Service/Realtime/`,
  `lib/GPForum/Controller/Realtime.pm`, `lib/GPForum/Web/RealtimeAccess.pm`
- `EVENTS.md`, `docs/realtime.md`, `docs/OUTBOX_LIFECYCLE.md`
- `t/13-outbox-dispatcher.t`, `t/14-projection-offset.t`,
  `t/15-projection-generation.t`, `t/20-realtime.t`,
  `t/81-realtime-operational.t`, `t/82-realtime-supervisor.t`,
  `t/84-outbox-concurrent-dispatcher.t`,
  `t/85-realtime-outbox-multiprocess.t`, `t/113-web-realtime-access.t`,
  `t/121-outbox-boundaries.t`, `t/139-event-recorder-id.t`
