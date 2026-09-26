# ADR 0050: Infrastructure and Distributed Systems Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/2.txt` ("GPForum —
Infrastructure & Distributed Systems Constitution"); this ADR replaces the
prompt as the binding source.

## Context

ADR 0049 fixes GPForum as a stateless, horizontally scaled, Perl-native
modular monolith. This ADR defines the mandatory infrastructure, distributed
systems behavior, operational topology, scaling model, persistence strategy,
synchronization rules, deployment philosophy, and node responsibilities that
follow from it. It is foundational and mandatory for all future architectural
decisions and governs deployment, runtime nodes, PostgreSQL operations,
caching, search, object storage, realtime, and workers.

## Decision

### Global Infrastructure Philosophy

- GPForum MUST be designed as: horizontally scalable; distributed; stateless
  at the application layer; operationally predictable; failure-tolerant;
  append-oriented.
- The infrastructure MUST prioritize: operational simplicity; deterministic
  behavior; graceful degradation; recoverability; observability; low
  operational entropy.

### Global Topology

- Canonical topology:

  ```text
  CDN/WAF
    -> HAProxy or Nginx
    -> Application Nodes
    -> Shared Infrastructure
    -> Workers / Search / Realtime
  ```

- Shared infrastructure includes: PostgreSQL; object storage; Minion backend.
- Optional shared acceleration infrastructure includes: Redis or KeyDB.

### Edge Layer

- The edge layer MUST provide: TLS termination; HTTP/2 and HTTP/3 support
  when possible; DDoS mitigation; request buffering; compression; static
  asset caching; WAF integration; rate limiting.
- Preferred edge technologies: Nginx; HAProxy; CDN providers; external WAF
  systems.
- The application MUST NOT directly expose raw application nodes to the
  public internet.

### Application Node Philosophy

- Application nodes MUST be: stateless; disposable; horizontally scalable;
  multi-process capable; immutable when deployed.
- Application nodes MUST NOT: store persistent sessions locally; store
  authoritative state locally; depend on local filesystem persistence;
  maintain exclusive ownership of resources.
- Application nodes MUST support: rolling deployment; graceful restart; rapid
  autoscaling; dynamic Perl process pool resizing; distributed operation.
- Each application node SHOULD run multiple independent Perl worker
  processes.
- The process count MUST be configurable per workload class and per
  deployment environment.

### Node Types

- The architecture SHOULD support specialized node categories, for example:
  HTTP nodes; realtime websocket nodes; worker nodes; indexing nodes;
  administrative nodes.
- The system MUST allow separation of workloads across node classes.

### HTTP Nodes

- HTTP nodes MUST: remain lightweight; prioritize low request latency; avoid
  long-running operations; avoid blocking operations; offload asynchronous
  work to workers; scale through multiple Perl HTTP processes.
- HTTP nodes MUST: validate requests; enforce authentication; enforce
  authorization; emit domain events; enqueue background jobs.

### Realtime Nodes

- Realtime nodes MUST: manage websocket connections; support distributed
  synchronization; avoid direct business persistence logic; subscribe to
  distributed event streams.
- Realtime nodes MUST support: pub/sub synchronization; distributed fanout;
  connection recovery; graceful degradation.
- Realtime nodes MUST NOT become authoritative state owners.

### Worker Nodes

- Worker nodes MUST process: notifications; email; indexing; analytics;
  moderation; media processing; cleanup operations; asynchronous workflows.
- Worker execution MUST support: retries; idempotency; distributed
  scheduling; failure isolation.
- Worker workloads MUST remain decoupled from HTTP request latency.

### PostgreSQL Infrastructure

- PostgreSQL is the canonical system of record.
- The PostgreSQL architecture MUST support: streaming replication; WAL
  archiving; partitioning; online backup; read replicas; point-in-time
  recovery.
- The database MUST be designed for: multi-year growth; large event volumes;
  distributed deployments; operational stability.

### PostgreSQL Partitioning

- The system MUST use native PostgreSQL partitioning.
- Mandatory partition candidates: `event_log`; `notifications`; `audit_log`.
- Sessions, users, threads, and categories MUST NOT be partitioned
  prematurely.
- Any additional partitioned table requires a measurable volume, retention,
  or archival reason recorded in an ADR.
- Partitioning MUST: support retention policies; support archival
  strategies; minimize vacuum pressure; minimize index bloat.
- The architecture MUST avoid giant mutable tables.

### UUID Strategy

- Identifiers MUST use UUIDv7 or equivalent sortable distributed identifiers.
- Sequential integer identifiers SHOULD be avoided for distributed scaling.

### Redis / KeyDB Optional Acceleration Philosophy

- Redis or KeyDB MAY be used, but MUST be treated as ephemeral
  infrastructure.
- Redis MAY be used for: cache; distributed locks; pub/sub; rate limiting;
  session acceleration; online presence; short-lived transient state.
- Redis MUST NOT become the canonical persistence layer.
- Business-critical data MUST remain recoverable from PostgreSQL.
- Redis or KeyDB MUST NOT be required for correctness.

### Search Infrastructure

- Search MUST be PostgreSQL-native by default.
- Preferred technologies: PostgreSQL full-text search; `tsvector`; GIN
  indexes; `pg_trgm`; Perl indexing and ranking orchestration.
- Search indexing MUST operate asynchronously.
- The search subsystem MUST support: incremental indexing; eventual
  consistency; distributed indexing; relevance tuning; language-aware
  analysis; permission-aware filtering.

### Object Storage

- User-generated media MUST be stored in object storage.
- The application MUST avoid: local upload persistence; local attachment
  ownership.
- Object storage MUST support: redundancy; lifecycle management; antivirus
  scanning workflows; immutable asset delivery.

### Event Synchronization

- The system MUST support distributed event propagation.
- Synchronization mechanisms MAY include: Redis pub/sub; PostgreSQL
  LISTEN/NOTIFY; event tables; worker queues.
- All synchronization MUST tolerate: node failure; delayed propagation;
  temporary inconsistency; replay scenarios.

### Eventual Consistency

- The architecture MUST tolerate eventual consistency where appropriate.
- Strong consistency SHOULD be reserved for: authentication; authorization;
  financial operations; security-critical actions.
- Realtime UI updates MAY operate asynchronously.

### Queueing Philosophy

- Slow operations MUST execute asynchronously.
- Minion is the preferred orchestration layer.
- Queue-backed workflows MUST support: retry policies; idempotency; failure
  recovery; distributed execution; workload isolation.

### Deployment Philosophy

- The deployment architecture MUST support: zero-downtime deployment; rolling
  updates; blue/green deployment when possible; horizontal scaling; vertical
  process scaling inside each node; rapid node replacement.
- Containers MAY be used.
- Kubernetes is OPTIONAL and MUST NOT become mandatory for the platform
  architecture.

### Caching Philosophy

- Caching MUST remain: explicit; observable; invalidation-aware;
  non-authoritative.
- Preferred caching targets: rendered fragments; computed read models;
  anonymous page delivery; expensive aggregations.
- Caching MUST NOT compromise correctness or authorization.

### Observability Infrastructure

- The infrastructure MUST expose: metrics; tracing; structured logs; health
  endpoints; auditability.
- Mandatory observability characteristics: correlation IDs; distributed
  tracing; centralized logging; operational dashboards.

### Failure Philosophy

- The infrastructure MUST assume: node crashes; partial outages; delayed
  jobs; replication lag; cache loss; websocket interruptions.
- The system MUST degrade gracefully.
- No single application node may become critical infrastructure.

### Operational Philosophy

- The platform MUST prioritize: predictable operations; recoverability; low
  maintenance burden; deterministic scaling; infrastructure transparency.
- Operational complexity MUST remain controlled at all times.

### Long-Term Infrastructure Goal

- GPForum infrastructure MUST remain: scalable; comprehensible; auditable;
  maintainable for decades; resilient under high concurrency; adaptable to
  future distributed workloads.
- All future infrastructure decisions MUST comply with this constitution.

## Consequences

- Nodes can be replaced, scaled, and rolled without data loss because no
  node owns sessions, uploads, or authoritative state.
- Operators must run PostgreSQL with replication, WAL archiving, and PITR,
  plus object storage and a Minion backend; Redis/KeyDB and Kubernetes stay
  optional.
- Partitioning is limited to `event_log`, `notifications`, and `audit_log`
  until an ADR justifies more, which keeps schema complexity bounded.
- Eventual consistency is the default outside authentication,
  authorization, financial, and security-critical actions, so UI and
  realtime paths must tolerate lag and replay.
- Open conflicts:
  - ADR 0048 requires GlifiStore as a shared L2 cache in staging and
    production. It is not in the canonical shared infrastructure list, which
    names only PostgreSQL, object storage, and the Minion backend as required
    and Redis/KeyDB as optional acceleration.
  - Attachments are persisted by
    `GPForum::Service::Attachment::FilesystemStorage` under
    `var/attachments` on the node filesystem, contrary to the object storage
    rule and to "MUST NOT depend on local filesystem persistence".
  - The Redis use list here (including distributed locks and session
    acceleration) is broader than the optional-use list in ADR 0067, which
    is the later decision on cache and coordination.

## Alignment

- ADR 0049 (foundation), ADR 0051 (database), ADR 0055 (events and
  realtime), ADR 0056 (workers), ADR 0058 (observability), ADR 0062
  (search), ADR 0063 (performance), ADR 0066 and ADR 0067 (Redis and cache
  decision), ADR 0077 (configuration), ADR 0086 (packaging and deployment),
  ADR 0088 (multi-process runtime).
- ADR 0006 (LISTEN/NOTIFY realtime transport), ADR 0009 (outbox retry), ADR
  0012 (operational profiles and partition lifecycle), ADR 0048 (mandatory
  GlifiStore L2).
- `migrations/002_event_audit.sql`, `migrations/003_forum_projection.sql`,
  `lib/GPForum/Infrastructure/Id.pm`, `lib/GPForum/Worker/MinionRegistrar.pm`,
  `lib/GPForum/Service/Attachment/FilesystemStorage.pm`.
- `deploy/nginx/`, `deploy/systemd/`, `deploy/caddy/Caddyfile`.
- `t/99-partition-lifecycle.t`, `t/98-operational-profiles.t`,
  `t/33-health-readiness.t`, `t/85-realtime-outbox-multiprocess.t`.
- `docs/DEPLOYMENT.md`, `docs/architecture/partition-lifecycle.md`,
  `docs/architecture/operational-profiles.md`, `docs/OBSERVABILITY.md`.
