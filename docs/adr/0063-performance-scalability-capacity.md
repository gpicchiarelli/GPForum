# ADR 0063: Performance, Scalability and Capacity Engineering

## Status

Accepted. Converted on 2026-09-19 from `prompt/15.txt` ("GPForum —
Performance, Scalability & Capacity Engineering Constitution"); this ADR
replaces the prompt as the binding source.

## Context

GPForum must serve large communities with heavy read concurrency, realtime
traffic and long-term data growth while staying operable by a small team.
Performance cannot be an afterthought or "optimization theater"; it is
disciplined distributed systems engineering and must be measurable.

This ADR is foundational and mandatory. It defines the performance
philosophy, scalability architecture, latency discipline, throughput
strategy, resource management model, cache hierarchy, backpressure behavior,
load-shedding principles and long-term capacity engineering standards. It
governs web and worker processes, PostgreSQL query and partition design,
caches, realtime connections, queues, search, asset delivery, frontend
rendering and benchmarking across all bounded contexts.

## Decision

### Measurability

- Per ADR 0093, every performance claim MUST be measurable.
- Hot paths MUST have bounded query-cost expectations, profiling capability,
  and tests or benchmarks where feasible.
- OFFSET pagination on hot forum paths is prohibited.
- Performance regressions that break documented budgets are release-blocking
  engineering failures.

### OS Awareness

- Per ADR 0097, performance MUST also be OS-aware.
- macOS, FreeBSD and Linux behavior MUST be detected through `GPForum::OS`,
  not scattered `$^O` checks.
- Hot paths MUST avoid fork-per-request, blocking I/O, unbounded caches, long
  transactions, repeated parsing and unnecessary synchronous filesystem work.
- OS-specific optimizations require fallback, feature flags, documentation
  and profiling evidence.

### Scalability Invariants

- Per ADR 0099, performance work MUST preserve hot-path query topology,
  projection stability, hot-row avoidance, outbox separation, cache
  disposability, search derivation, migration online safety and graceful
  degradation under worker or projection failure.

### Performance Philosophy

- Performance is an architectural property, an operational discipline and a
  scalability constraint system.
- Performance MUST prioritize predictability, bounded latency, graceful
  degradation, operational sustainability and distributed scalability.
- The platform MUST avoid uncontrolled resource amplification, latency
  spikes, unbounded memory growth and hidden scalability cliffs.

### Scalability Philosophy

- GPForum MUST scale horizontally, incrementally, through multi-process Perl
  capacity and operationally predictably.
- The architecture MUST assume millions of users, massive read concurrency,
  distributed websocket traffic, asynchronous event propagation and
  long-term data growth.
- The platform MUST prioritize stateless application nodes, multiple Perl
  processes per node, dynamic worker and web process counts, asynchronous
  processing, partition-aware persistence and cache efficiency.

### Capacity Engineering Philosophy

- Capacity planning MUST remain measurable, observable, proactive and
  continuously validated.
- The platform MUST support node replacement, rolling scaling, workload
  isolation and capacity forecasting.

### Latency Philosophy

- Latency MUST remain bounded, measurable and operationally observable.
- Critical user-facing workflows SHOULD prioritize low p95 latency, low p99
  latency and graceful degradation under load.
- Latency spikes MUST remain diagnosable, attributable and operationally
  visible.

### Throughput Philosophy

- The architecture MUST optimize for high concurrent reads, bounded write
  amplification, asynchronous fanout and distributed workload handling.
- The platform MUST avoid synchronous bottlenecks, centralized coordination
  hotspots and global serialization points.

### Resource Management

- All workloads MUST maintain bounded memory usage, bounded concurrency,
  bounded process counts, bounded thread counts where threads are used,
  bounded queue growth and bounded connection usage.
- The system MUST avoid uncontrolled buffering, unbounded websocket fanout
  and unbounded worker accumulation.

### Stateless Scaling

- Application nodes MUST remain stateless, disposable, horizontally scalable
  and vertically scalable through process multiplicity.
- The architecture MUST support rolling deployment, autoscaling, node
  replacement and workload redistribution.
- No application node may become irreplaceable.

### Database Scaling Philosophy

- PostgreSQL scaling MUST prioritize partitioning, replica reads, bounded
  transactions, index efficiency and append-oriented persistence.
- The platform MUST avoid giant mutable tables, unbounded scans and
  destructive cleanup workloads.

### Query Discipline

- Queries MUST remain bounded, indexed, partition-aware and
  pagination-aware.
- Forbidden: unbounded ORM loads; `SELECT *` on large datasets; unrestricted
  joins; unbounded aggregation scans.
- All high-volume queries MUST support deterministic execution plans,
  selective indexes and explicit ordering.

### Partitioning Philosophy

- Partitioning is mandatory.
- Partitioning MUST reduce vacuum pressure, reduce index bloat, support
  retention and improve operational predictability.
- The architecture MUST support partition pruning, partition rotation and
  partition archival.

### Cache Philosophy

- Caching MUST remain explicit, observable, disposable and
  authorization-aware.
- Caches MUST NOT become canonical persistence or hidden business authority.
- Preferred cache targets: rendered fragments, expensive aggregates,
  anonymous content, search projections.

### Cache Hierarchy

- Recommended cache layers: CDN cache, edge cache, application cache,
  fragment cache, search cache.
- Each layer MUST remain independently invalidatable and operationally
  observable.

### Cache Invalidation

- Cache invalidation MUST remain explicit, event-driven where possible and
  bounded.
- The architecture MUST avoid uncontrolled cache staleness and hidden
  invalidation coupling.

### Realtime Scaling

- Realtime infrastructure MUST support distributed websocket nodes,
  incremental propagation, asynchronous fanout and connection recovery.
- Realtime systems MUST avoid centralized websocket ownership and
  synchronous broadcast bottlenecks.

### Connection Management

- The platform MUST support high websocket concurrency, connection lifecycle
  management, idle timeout policies and reconnect workflows.
- Connection handling MUST remain memory-aware, resource-bounded and
  operationally observable.

### Backpressure Philosophy

- The platform MUST support graceful degradation under load, queue
  backpressure, rate limiting and overload protection.
- The system MUST prefer controlled degradation over catastrophic collapse.

### Load Shedding

- The architecture SHOULD support selective workload shedding, degraded
  realtime behavior, delayed non-critical workflows and queue prioritization.
- Critical persistence workflows MUST remain prioritized.

### Queue Scalability

- Worker systems MUST support workload isolation, queue prioritization,
  distributed execution and autoscaling.
- Queue growth MUST remain observable, bounded and recoverable.

### Search Scalability

- Search infrastructure MUST support worker-distributed indexing,
  partition-aware PostgreSQL scaling, asynchronous ingestion and rebuild
  workflows.
- Search failures MUST NOT block persistence workflows or posting workflows.

### Asset Delivery

- Static assets MUST support CDN delivery, immutable caching, compression and
  fingerprinting.
- Asset delivery MUST remain horizontally scalable and cache-efficient.

### Frontend Performance

- Frontend rendering MUST prioritize server-side rendering, incremental
  updates, minimal JavaScript and cache-friendly delivery.
- The platform MUST avoid hydration-heavy architectures and giant frontend
  runtime costs.

### Observability of Performance

- Performance metrics MUST include request latency, websocket latency, queue
  latency, cache hit ratio, database latency, replication lag and event
  propagation delay.
- Performance visibility is mandatory.

### Capacity Limits

- The architecture MUST support configurable operational limits, queue
  limits, connection limits, upload limits, search limits and API rate
  limits.
- The system MUST remain bounded, controllable and abuse-resistant.

### Failure Philosophy

- The platform MUST assume traffic spikes, node crashes, queue backlog,
  replica lag, websocket storms and abusive clients.
- The architecture MUST degrade gracefully.

### Benchmarking Philosophy

- Performance testing SHOULD include concurrency testing, websocket testing,
  queue stress testing, indexing stress testing, partition scaling tests,
  profiling runs, memory growth checks and slow query analysis.
- Profiling MUST be part of performance engineering.
- The system SHOULD retain comparable profiling artifacts between releases.
- Performance assumptions MUST remain measurable and reproducible.

### Operational Sustainability

- The platform MUST remain operable by small teams, understandable under load
  and recoverable during incidents.
- Operational simplicity is a scalability feature.

### Long-Term Performance Goal

- GPForum performance architecture MUST remain horizontally scalable,
  latency-aware, operationally predictable, resilient under extreme
  concurrency and sustainable under long-term growth.
- Performance is not optimization theater; it is disciplined distributed
  systems engineering.
- All future scalability and performance decisions MUST comply with this
  ADR.

## Consequences

- Performance becomes a gated property: hot paths carry query budgets,
  profiling evidence and benchmarks and never use OFFSET pagination, and a
  broken budget blocks a release.
- Every workload has explicit limits (memory, processes, queues, connections,
  uploads, search, API rate), which operators must size and observe; the
  platform sheds or delays non-critical work before persistence suffers.
- Stateless multi-process nodes, disposable caches and derived projections
  keep scaling horizontal and node replacement routine, at the cost of
  maintaining invalidation, rebuild and partition-rotation machinery.
- Open conflicts:
  - "Partitioning is mandatory" names no tables. Today only `event_log`,
    `audit_log` and `notifications` are range-partitioned (ADR 0012);
    `posts`, `threads` and `search_documents` are not, so the required
    partitioning scope is undefined.
  - `t/09-prompt-alignment.t` reads `prompt/15.txt` to check the ADR 0097 and
    ADR 0099 alignment markers and will fail once the prompt is deleted.

## Alignment

- ADR 0093 (verifiable invariants), ADR 0097 (OS-level performance), ADR 0099
  (operational scalability and projection stability).
- ADR 0088 (multi-process runtime scalability), ADR 0089 (profiling and
  coverage), ADR 0067 (cache and coordination decision), ADR 0051
  (database), ADR 0050 (infrastructure), ADR 0056 (workers and queues), ADR
  0055 (realtime), ADR 0062 (search), ADR 0054 (frontend rendering).
- ADR 0006 (LISTEN/NOTIFY realtime transport), ADR 0012 (operational
  profiles and partition lifecycle), ADR 0019 (public HTTP cache), ADR 0048
  (GlifiStore L2 cache).
- `lib/GPForum/OS.pm`, `lib/GPForum/OS/`, `bin/gpforum-benchmark`,
  `bin/gpforum-query-budget`, `bin/gpforum-query-plan-evidence`.
- `script/query-budget`, `script/query-plan-check`,
  `script/query-plan-evidence`, `script/bench-hotpaths`, `script/bench-http`,
  `script/bench-hypnotoad`, `script/bench-hypnotoad-scaling`,
  `script/profile-nytprof`, `script/seed-benchmark`.
- `docs/PERFORMANCE.md`, `docs/PERFORMANCE_BASELINE.md`,
  `docs/PERFORMANCE_EVIDENCE.md`, `docs/PERFORMANCE_AUDIT.md`,
  `docs/DB_PERFORMANCE.md`, `docs/QUERY_BUDGET_POLICY.md`,
  `docs/PROFILING.md`, `docs/OS_OPTIMIZATION.md`,
  `docs/architecture/partition-lifecycle.md`.
- `t/21-forum-pagination.t`, `t/36-os-performance.t`,
  `t/38-query-budget-command.t`, `t/47-query-plan-check.t`,
  `t/49-performance-harness.t`, `t/89-tiered-cache.t`,
  `t/99-partition-lifecycle.t`, `t/09-prompt-alignment.t`.
