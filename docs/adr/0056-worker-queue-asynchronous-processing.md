# ADR 0056: Worker, Queue and Asynchronous Processing

## Status

Accepted. Converted on 2026-09-19 from `prompt/8.txt` ("GPForum — Worker,
Queue & Asynchronous Processing Constitution"); this ADR replaces the prompt
as the binding source.

## Context

Slow work (email, indexing, fanout, media, scanning, maintenance) must not
run inside HTTP requests, and background execution must not become a hidden
source of truth or a failure amplifier. Workers run as many Perl processes on
many nodes and see crashes, retries, duplicates and delays.

This ADR fixes the asynchronous processing architecture, worker
orchestration, queue discipline, retry model, job lifecycle, distributed
execution behavior, scheduling principles and workload isolation. It governs
Minion jobs, outbox and projection workers, dead-letter handling, scheduled
maintenance, and the HTTP-to-worker hand-off. The rules are foundational and
mandatory; all future asynchronous processing MUST comply with them. Workers
are not background utilities; they are a foundational distributed systems
layer.

## Decision

### Projection and Invariant Alignment

- Per ADR 0099, projection and outbox workers MUST remain idempotent,
  retry-tolerant, restart-safe, replay-tolerant,
  duplicate-delivery-tolerant, observable, and safe for projection lag
  reconciliation.
- Per ADR 0099, worker failure MUST NOT corrupt canonical state or make
  derived state authoritative.
- Per ADR 0093, workers MUST preserve idempotent, observable, replay-safe
  contracts.
- Per ADR 0093, queue payloads MUST be versioned where long-lived, failures
  MUST be classified, retries MUST be bounded, and asynchronous state MUST
  NOT become authoritative.

### Asynchronous Processing Philosophy

- GPForum MUST operate as asynchronous-first, event-driven, distributed and
  latency-aware.
- The platform MUST avoid blocking request workflows, synchronous heavy
  processing, request-bound orchestration and long-lived HTTP operations.
- Asynchronous execution is foundational to scalability, responsiveness,
  operational resilience and workload isolation.

### Worker Philosophy

- Workers are distributed execution units, asynchronous orchestration
  processors and non-interactive execution systems.
- Workers MUST remain stateless, horizontally scalable, multi-process
  scalable, restart-safe and replay-tolerant.
- Workers MUST tolerate crashes, retries, duplicate delivery and delayed
  execution.

### Mandatory Queue System

- Preferred queue system: Minion. Minion is the canonical asynchronous
  orchestration layer.
- All slow or high-latency operations SHOULD execute through queued jobs,
  asynchronous workflows, distributed workers and dynamically sized Perl
  worker pools.

### Queue Ownership Philosophy

- HTTP requests MUST validate, persist authoritative state, emit events and
  enqueue asynchronous work.
- HTTP requests MUST NOT block on slow workflows, execute heavy
  orchestration or wait for distributed side effects.

### Mandatory Asynchronous Workloads

Examples of workloads that MUST be asynchronous: email delivery, search
indexing, moderation analysis, notification fanout, media processing,
antivirus scanning, analytics aggregation, audit shipping, cache
invalidation, federation propagation, digest generation, websocket
propagation assistance.

### Job Design Philosophy

- Jobs MUST remain deterministic, bounded, idempotent, observable and
  replay-safe.
- Jobs SHOULD perform one responsibility, remain composable and remain
  retry-safe.

### Idempotency

- All distributed jobs MUST support idempotent execution. Idempotency is
  mandatory.
- Repeated execution MUST NOT corrupt state, duplicate authoritative
  records, generate duplicate side effects or bypass authorization.

### Retry Philosophy

- Jobs MUST support retry, bounded retry policies, exponential backoff and
  dead-letter handling.
- Retries MUST remain observable, auditable and failure-aware.
- The system MUST tolerate transient failure.

### Failure Isolation

- Worker failure MUST NOT crash application nodes, block HTTP traffic,
  corrupt persistence or halt unrelated workloads.
- Worker queues SHOULD remain isolated by responsibility and operationally
  separable.

### Queue Categories

- Recommended queue separation: `notifications`, `search`, `media`,
  `analytics`, `moderation`, `federation`, `maintenance`, `cleanup`.
- Queue isolation SHOULD minimize noisy neighbor effects, workload
  starvation and latency amplification.

### Job Payload Philosophy

- Job payloads SHOULD contain identifiers, timestamps and minimal
  replay-safe metadata.
- Jobs SHOULD avoid giant embedded payloads, mutable embedded state and
  hidden authority assumptions.
- Workers SHOULD retrieve authoritative state from PostgreSQL when required.

### Distributed Worker Execution

- Workers MUST support distributed execution, multi-node processing,
  rolling deployment, crash recovery and replay safety.
- Workers MUST NOT depend on local filesystem state, local memory
  persistence or node affinity.

### Scheduling Philosophy

- The system SHOULD support scheduled jobs, delayed execution and recurring
  maintenance tasks.
- Scheduled execution MUST remain observable, replay-safe and
  idempotent-aware.

### Long-Running Workloads

- Long-running workloads MUST remain isolated, support cancellation, support
  timeout policies, scale by process count first, and avoid blocking worker
  pools indefinitely.
- The architecture MUST avoid infinite jobs, unbounded execution and
  resource exhaustion.

### Worker Resource Discipline

- Workers MUST maintain bounded memory usage, avoid uncontrolled buffering,
  avoid unbounded concurrency and support graceful shutdown.
- Worker nodes SHOULD support autoscaling, queue-aware scaling and
  workload-specific scaling.

### Distributed Coordination

- Worker coordination MUST avoid global locks where possible, tolerate
  retries, tolerate delayed execution and support partial failure.
- The architecture SHOULD prefer optimistic workflows, append-oriented
  workflows and replay-safe orchestration.

### Queue Persistence Philosophy

- Queue persistence MUST remain durable, observable and recoverable.
- Critical workflows MUST survive node crashes, worker restarts and
  temporary infrastructure outages.

### Dead Letter Philosophy

- Failed jobs SHOULD support dead-letter queues, quarantine workflows,
  operator review and replay mechanisms.
- Permanent failure MUST remain visible.

### Security of Worker Systems

- Workers MUST validate all payloads, authenticate infrastructure access,
  avoid unsafe shell execution and avoid unsafe deserialization.
- Workers MUST assume hostile payload injection attempts, replay attempts
  and malformed jobs.

### Event-Driven Integration

- Workers SHOULD consume domain, synchronization, indexing and moderation
  events.
- Workers are foundational to event-driven orchestration, distributed
  synchronization and asynchronous scalability.

### Search Indexing

- Search indexing MUST execute asynchronously, tolerate replay, tolerate
  delayed propagation and support rebuild workflows.
- Indexing MUST NOT block user-facing persistence.

### Notification Fanout

- Notification delivery MUST remain asynchronous, support retry, tolerate
  delayed propagation and support distributed fanout.
- Realtime delivery MUST remain eventually consistent.

### Media Processing

- Media workflows MUST execute asynchronously (examples: image resizing,
  thumbnail generation, transcoding, metadata extraction, virus scanning).
- Media processing MUST remain isolated from request latency.

### Maintenance Workloads

- Background maintenance MAY include partition cleanup, retention
  enforcement, cache pruning, analytics compaction, audit archival and stale
  session cleanup.
- Maintenance MUST remain bounded, partition-aware and low-impact.

### Observability

- Worker infrastructure MUST expose queue depth, retry metrics, failure
  rates, execution latency, worker throughput and dead-letter counts.
- Operational visibility is mandatory.

### Logging Philosophy

- Worker logs MUST remain structured, support correlation IDs, support
  distributed tracing and avoid secret leakage.
- All failures MUST remain traceable.

### Replay Philosophy

- Critical asynchronous workflows SHOULD support replay, reconstruction,
  partial reprocessing and recovery after outage.
- Replay MUST remain idempotent-aware and audit-safe.

### Operational Philosophy

- Worker systems MUST prioritize operational simplicity, deterministic
  scaling, failure isolation, graceful degradation and recoverability.
- The queueing system MUST remain understandable and maintainable.

### Long-Term Asynchronous Goal

- The asynchronous architecture MUST remain scalable, replayable, resilient,
  distributed-safe, operationally predictable and sustainable under extreme
  concurrency.

## Consequences

- Request latency stays independent of email, indexing, media and fanout
  work, and a worker outage degrades freshness rather than correctness.
- Every job needs an idempotency story, a bounded retry policy with backoff,
  failure classification and a visible terminal state (dead letter), which
  adds schema and code per workload.
- Payloads carry identifiers rather than state, so workers pay a PostgreSQL
  read per job in exchange for replay safety.
- Operators must watch queue depth, retry, failure, latency, throughput and
  dead-letter metrics and must be able to review and replay dead letters.
- Scaling is by process count first, which ties worker sizing to ADR 0088.

## Alignment

- ADR 0009, ADR 0025, ADR 0040
- ADR 0053 (security), ADR 0055 (events and realtime), ADR 0058
  (observability), ADR 0062 and ADR 0090 (search), ADR 0067 (coordination),
  ADR 0078 (notification delivery), ADR 0086 (runtime processes), ADR 0088
  (multi-process runtime), ADR 0093 (engineering invariants), ADR 0099
  (projection stability)
- `lib/GPForum/Worker/MinionRegistrar.pm`,
  `lib/GPForum/Worker/IdempotentJobRunner.pm`, `lib/GPForum/Worker/Handler/`,
  `lib/GPForum/Bootstrap/Workers.pm`, `lib/GPForum/Jobs/EventPayload.pm`,
  `lib/GPForum/Service/Outbox/` (`Retry.pm`, `FailureType.pm`,
  `DeadLetterRecorder.pm`), `lib/GPForum/Command/OutboxDispatch.pm`
- `bin/gpforum-outbox-dispatch`, `script/outbox-dispatch`,
  `script/bench-outbox-dispatcher`
- `migrations/004_platform_governance.sql` (`dead_letters`,
  `projection_offsets`, `projection_generations`),
  `migrations/021_outbox_delivery_reliability.sql`,
  `migrations/022_outbox_concurrent_claim.sql`,
  `migrations/024_privacy_erasure_job_idempotency.sql`
- `docs/OUTBOX_LIFECYCLE.md`, `docs/audit/failure-modes.md`
- `t/13-outbox-dispatcher.t`, `t/16-workers-phase.t`,
  `t/83-outbox-worker-wiring.t`, `t/84-outbox-concurrent-dispatcher.t`,
  `t/87-command-idempotency.t`, `t/99-partition-lifecycle.t`,
  `t/121-outbox-boundaries.t`
