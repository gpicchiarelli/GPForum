# ADR 0051: Database Architecture Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/3.txt` ("GPForum — Database
Architecture Constitution"); this ADR replaces the prompt as the binding
source.

## Context

PostgreSQL is GPForum's canonical system of record (ADR 0049, ADR 0050). This
ADR defines the mandatory database architecture, persistence model,
partitioning strategy, event storage philosophy, migration discipline,
indexing rules, query standards, and long-term storage sustainability model.
It is foundational and mandatory for every schema, migration, repository,
projection, and query in all bounded contexts.

## Decision

### Operational Scalability Alignment (ADR 0099)

- Database work MUST preserve operational scalability and projection
  stability.
- Hot queries MUST have explainable topology, bounded ordering, matching
  indexes, and projection-aware access paths.
- Projection offsets, blue/green rebuilds, hot-row avoidance, additive
  migrations, and online backfill discipline are mandatory design concerns.

### Verifiable Invariants Alignment (ADR 0093)

- Database design MUST preserve verifiable invariants.
- Canonical tables, event/audit logs, outbox tables, migration metadata, and
  projection lineage MUST remain mechanically testable.
- Migrations MUST document: purpose; lock risk; rollback stance; online
  safety; backfill expectations; projection impact; replay impact.

### Database Philosophy

- The database architecture MUST prioritize: long-term operational
  sustainability; append-oriented persistence; deterministic query behavior;
  auditability; horizontal scalability support; partition-aware growth;
  low-maintenance operation.
- The database is not merely storage. It is: the canonical system of record;
  the event backbone; the audit substrate; the synchronization foundation.

### Canonical Database

- Mandatory database: PostgreSQL.
- PostgreSQL is the authoritative source of truth.
- No other system may become authoritative over business-critical data.

### Core Persistence Principles

- The persistence layer MUST: avoid giant mutable tables; minimize
  destructive UPDATE and DELETE operations; prefer append-only workflows;
  separate hot and cold data; support replayability; support partition-aware
  retention.
- The architecture MUST be designed for: billions of records; multi-year
  retention; distributed deployments; operational predictability.

### Database Naming Standards

- Tables: snake_case; pluralized. Examples: `users`, `posts`, `event_log`,
  `notification_queue`.
- Columns: snake_case. Examples: `user_id`, `thread_id`, `created_at`,
  `updated_at`.
- Foreign keys: explicit naming.
- Indexes: prefixed and descriptive.
- Constraints: explicitly named.

### Identifier Strategy

- The platform MUST use UUIDv7 or equivalent sortable distributed
  identifiers.
- Sequential integers SHOULD NOT be used as public identifiers.
- UUID requirements: distributed-safe; sortable; collision-resistant;
  replication-friendly.

### Timestamp Standards

- All timestamps MUST: use UTC; include timezone awareness; use
  `timestamptz`.
- Mandatory fields where applicable: `created_at`, `updated_at`.
- Append-only entities SHOULD avoid `updated_at` unless necessary.

### Core Relational Tables

- Mandatory relational entities include: `users`, `threads`, `posts`,
  `categories`, `tags`, `permissions`, `role_bindings`, `attachments`,
  `notifications`.
- Additional domain entities MUST remain normalized unless denormalization is
  explicitly justified.

### Event Log Architecture

- The platform MUST implement an append-only `event_log`. The event log is
  foundational.
- Events MUST be: immutable; timestamped; traceable; replayable when
  possible.
- Example event categories: `thread.created`, `post.created`, `post.edited`,
  `user.banned`, `role.assigned`, `attachment.uploaded`.

### Event Storage Structure

- The `event_log` MUST minimally include: `event_id`, `event_type`,
  `schema_version`, `aggregate_type`, `aggregate_id`, `actor_id`,
  `correlation_id`, `causation_id`, `idempotency_key`, `payload`,
  `metadata`, `created_at`.
- Payloads MAY use JSONB.
- Events MUST remain immutable after insertion.

### Audit Architecture

- The platform MUST maintain append-only audit records.
- Audit records MUST: never be modified; never be silently deleted; remain
  queryable historically.
- Security-critical operations MUST generate audit events. Examples: login;
  failed login; role change; moderation action; permission modification;
  session revocation.

### Revision Strategy

- Mutable user content SHOULD use immutable revision tables (example:
  `posts` with `post_revisions`).
- The architecture SHOULD prefer: historical preservation; reversible
  moderation; forensic traceability.

### Partitioning Philosophy

- The database MUST use native PostgreSQL partitioning.
- Partitioning is mandatory from day zero.
- The architecture MUST assume: long-term growth; large datasets; retention
  management.

### Mandatory Partition Candidates

- Strong partition candidates include: `event_log`, `audit_log`,
  `notifications`.
- Users, threads, categories, and sessions MUST NOT be partitioned by
  default.
- Other high-volume append-oriented tables SHOULD be partitioned only after
  an ADR documents the concrete retention, archival, and query-pruning
  benefit.

### Partitioning Strategy

- Preferred partitioning: RANGE partitioning by `created_at`.
- Recommended intervals: daily for ephemeral data; weekly for high-volume
  events; monthly for long-term entities.
- Partitioning MUST support: retention expiration; archival workflows; rapid
  partition dropping; minimized vacuum pressure.

### Retention Philosophy

- The architecture MUST support automated retention policies.
- The platform MUST avoid: giant DELETE operations; long-running cleanup
  transactions.
- Preferred lifecycle: partition expiration, detach, archive, drop.

### Query Philosophy

- Queries MUST prioritize: deterministic execution; bounded result sets;
  index-aware access; partition pruning.
- Unbounded queries are prohibited.
- All high-volume queries MUST: paginate; use explicit ordering; use
  selective columns.
- Queries over partitioned append-only tables MUST include the partitioning
  key where possible. `event_log`, `audit_log`, `notifications`, and
  rebuild/search maintenance queries SHOULD include `created_at` bounds to
  preserve partition pruning.
- Hot user paths MUST prefer partial and covering indexes. Visible-content
  paths SHOULD use partial indexes that exclude deleted or hidden rows.
  Append-only logs SHOULD use BRIN indexes on `created_at` when scale makes
  B-tree indexes too large.
- Endpoint query budgets are part of the database contract. Home, thread
  view, post create, and search endpoints MUST declare maximum query counts
  and transaction counts before implementation.
- Write coalescing MUST be used for view counts, read markers, and
  presence-like signals. Anti-hot-row counters SHOULD use sharded delta
  tables for viral threads.

### ORM Discipline

- Mandatory ORM: DBIx::Class. ORM usage MUST remain disciplined.
- Forbidden patterns: uncontrolled eager loading; ORM logic inside
  controllers; unbounded resultset materialization.
- Business logic MUST NOT reside inside ORM entities.

### Read/Write Separation

- The architecture SHOULD support CQRS-lite patterns.
- Write model: canonical PostgreSQL.
- Read models MAY include: cached aggregates; search indexes; materialized
  views; denormalized projections.
- Canonical tables and projection tables MUST be separated. Ordinary UI
  screens MUST read query-specific projections such as `thread_counters`,
  `category_stats`, `notification_inbox`, `user_feed_items`, and
  `search_documents` instead of scanning `event_log`.
- Materialized views MUST be reserved for admin, moderation, reporting,
  trend, or daily statistics workloads. They MUST NOT be placed on a hot user
  path if they require heavy refresh.
- Projection lag and rebuild generations MUST be first-class operational
  data, not implicit worker behavior.

### Search Separation

- Search projection workloads MUST remain separated from canonical
  transactional tables.
- PostgreSQL MAY provide the primary search engine through full-text search
  and dedicated projection tables.
- Canonical business tables MUST NOT be abused as ad hoc search indexes.
- Search indexing MUST occur asynchronously.

### Transactions

- Transactions MUST remain: short-lived; deterministic; bounded.
- Long-running transactions are prohibited.
- Distributed locking MUST be minimized.

### Concurrency Philosophy

- The architecture MUST assume: concurrent writes; distributed readers;
  replica lag; asynchronous propagation.
- The persistence layer MUST tolerate eventual consistency where
  appropriate.

### Session Persistence

- Sessions MUST: remain revocable; support distributed deployments; support
  expiration; avoid filesystem persistence.
- Session persistence MAY use: Redis; PostgreSQL; hybrid strategies.

### Cache Philosophy

- Caches MUST remain: disposable; reconstructable; non-authoritative.
- Critical business state MUST remain recoverable from PostgreSQL.

### Migration Discipline

- All schema changes MUST: use migrations; remain versioned; support
  rollback where possible; remain reproducible.
- Direct manual production schema editing is prohibited.

### Backup Philosophy

- The database architecture MUST support: WAL archiving; point-in-time
  recovery; replica restoration; automated backups; disaster recovery
  workflows.
- Recovery procedures MUST be tested.

### Performance Philosophy

- Performance MUST prioritize: predictable latency; partition-aware access;
  index efficiency; append-oriented writes; bounded reads.
- Premature denormalization SHOULD be avoided.

### Long-Term Sustainability Goal

- The database architecture MUST remain: maintainable for decades;
  operationally predictable; partition-aware; audit-friendly; scalable under
  extreme growth; resilient under distributed workloads.
- All future schema and persistence decisions MUST comply with this
  constitution.

## Consequences

- Append-only event and audit storage, revision tables, and partition
  lifecycles give replay, forensic traceability, and cheap retention (drop
  partitions instead of large DELETEs).
- Every hot endpoint carries a declared query and transaction budget, and
  UI reads go through projections, so projection lag and rebuild
  generations become operational data that must be monitored.
- Migrations carry more documentation (lock risk, rollback, backfill,
  projection and replay impact) and must stay additive and online-safe.
- `t/09-prompt-alignment.t` currently reads `prompt/3.txt` to assert the
  scalability alignment text; it must be retargeted to this ADR before the
  prompt is deleted.
- Open conflicts:
  - `tags` is listed as a mandatory relational entity, but no `tags` table
    exists in `migrations/`.
  - The rule "tables: pluralized" disagrees with the mandated or example
    names `event_log`, `audit_log`, and `notification_queue`; existing
    tables follow the singular log names.

## Alignment

- ADR 0049 (foundation), ADR 0050 (infrastructure), ADR 0052 (Perl
  engineering, ORM discipline), ADR 0062 and ADR 0090 (search), ADR 0063
  (performance), ADR 0067 (cache), ADR 0069 (initial schema), ADR 0071
  (event catalog), ADR 0093 (verifiable invariants), ADR 0099 (operational
  scalability and projection stability).
- ADR 0012 (operational profiles and partition lifecycle), ADR 0020 (audit
  record hashing), ADR 0048 (GlifiStore L2).
- `migrations/`, `lib/GPForum/Migration/`, `lib/GPForum/Schema/`,
  `lib/GPForum/Infrastructure/Id.pm`, `lib/GPForum/Infrastructure/EventRecorder.pm`,
  `lib/GPForum/Infrastructure/AuditRecord.pm`,
  `lib/GPForum/Service/Operations/`.
- `script/query-budget`, `script/query-plan-check`,
  `script/query-plan-evidence`, `bin/gpforum-migrate`.
- `t/05-database.t`, `t/10-migrate-command.t`, `t/14-projection-offset.t`,
  `t/15-projection-generation.t`, `t/38-query-budget-command.t`,
  `t/47-query-plan-check.t`, `t/99-partition-lifecycle.t`,
  `t/116-infrastructure-audit-record.t`, `t/143-service-id.t`,
  `t/09-prompt-alignment.t`.
- `docs/DB_PERFORMANCE.md`, `docs/QUERY_BUDGET_POLICY.md`,
  `docs/architecture/partition-lifecycle.md`,
  `docs/audit/transactional-correctness.md`.
