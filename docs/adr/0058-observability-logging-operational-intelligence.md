# ADR 0058: Observability, Logging and Operational Intelligence

## Status

Accepted. Converted on 2026-09-19 from `prompt/10.txt` ("GPForum —
Observability, Logging & Operational Intelligence Constitution"); this ADR
replaces the prompt as the binding source.

## Context

GPForum is distributed, asynchronous and eventually consistent, with node
churn and realtime propagation delays. A distributed system that cannot be
observed cannot be reliably operated: reliability, debugging, abuse
investigation, performance diagnosis and incident response all depend on
telemetry designed in from the start.

This ADR fixes the observability architecture, structured logging model,
metrics strategy, distributed tracing, profiling, monitoring requirements,
operational visibility standards, alerting rules and incident analysis
framework. It applies to every bounded context and runtime role (web,
realtime, workers, database, search, feeds). The rules are foundational and
mandatory; all future observability and operational tooling MUST comply
with them.

## Decision

### Scalability and Retrieval Alignment

- Per ADR 0099, observability MUST expose operational scalability state:
  hot-path latency, retry counts, projection lag, rebuild progress, dead
  letters, queue depth, slow query visibility, worker progress, cache
  posture and active projection generation where relevant.
- Per ADR 0101, search, feed, syndication, autocomplete, metadata and
  retrieval workflows MUST expose operational visibility for search latency,
  projection lag, rebuild progress, indexing throughput, failed indexing
  jobs, dead letters, feed generation latency, cache invalidation lag,
  active generation and degraded no-leak states.

### Observability Philosophy

- Observability is mandatory.
- GPForum MUST remain measurable, traceable, inspectable, debuggable and
  operationally transparent.
- The platform MUST assume distributed failures, asynchronous workflows,
  eventual consistency, node churn, realtime propagation delays and
  operational anomalies.
- Observability is required to maintain reliability, debug distributed
  systems, investigate abuse, diagnose performance, support incident
  response and sustain long-term operations.

### Foundational Principles

- The observability architecture MUST provide structured logs, metrics,
  tracing, correlation, health visibility and auditability.
- Operational state MUST remain externally inspectable, centralized where
  possible and machine-readable.

### Structured Logging

- All logs MUST be structured, machine-readable, timestamped and
  correlation-aware.
- Preferred log format: JSON structured logs.
- Logs MUST avoid multiline ambiguity, ad hoc formatting and unstructured
  text dumps.

### Mandatory Log Metadata

- Recommended log metadata: `timestamp`, `correlation_id`, `request_id`,
  `node_id`, `actor_id`, `session_id`, `event_type`, `severity`,
  `subsystem`, `workflow`.
- The logging architecture MUST support distributed debugging, replay
  investigation and abuse investigation.

### Correlation IDs

- Every request and asynchronous workflow MUST support correlation
  identifiers.
- Correlation IDs MUST propagate through HTTP requests, websocket flows,
  worker jobs, event propagation, search indexing and notifications.
- Distributed workflows MUST remain traceable end-to-end.

### Logging Philosophy

- Logs SHOULD capture operational state, workflow transitions, failures,
  retries, authorization decisions, moderation actions and infrastructure
  anomalies.
- Logs MUST avoid secrets, credentials, raw tokens and unsafe personal data
  exposure.

### Severity Discipline

- Recommended severities: `debug`, `info`, `warning`, `error`, `critical`.
- Severity usage MUST remain consistent, operationally meaningful and
  queryable.

### Metrics Philosophy

- The platform MUST expose infrastructure, application, queue, websocket,
  database, moderation and security metrics.
- Metrics MUST remain low-overhead, machine-readable and historically
  queryable.

### Mandatory Metrics Categories

Examples: request latency, queue depth, websocket connections, retry rates,
database latency, cache hit ratio, authorization failures, login failures,
moderation throughput, replication lag, event propagation latency.

### Distributed Tracing

- The platform SHOULD support distributed tracing.
- Tracing SHOULD cover HTTP requests, websocket workflows, asynchronous
  jobs, event propagation, search indexing and notification workflows.
- Tracing MUST support latency analysis, bottleneck detection and dependency
  mapping.

### Profiling

- The platform MUST support profiling.
- Profiling SHOULD cover HTTP request handlers, template rendering,
  authorization checks, database query paths, worker execution, event
  consumers and websocket fanout paths.
- Preferred Perl profiler: `Devel::NYTProf`.
- Profiling artifacts MUST be safe to collect, archive and compare across
  releases.
- Profiling MUST NOT expose secrets or private user data.

### Realtime Observability

- Realtime systems MUST expose active websocket counts, reconnect rates,
  fanout latency, pub/sub propagation metrics and dropped message metrics.
- Realtime observability is mandatory for distributed websocket systems.

### Queue Observability

- Worker systems MUST expose queue depth, retry count, dead-letter count,
  execution latency, worker saturation and scheduling delay.
- Operational queue visibility is mandatory.

### Database Observability

- Database monitoring MUST include query latency, replication lag, partition
  growth, vacuum pressure, index bloat, connection pool metrics and WAL
  growth.
- The platform MUST remain partition-aware, replication-aware and
  storage-aware.

### Security Observability

- Security-sensitive events MUST remain observable (examples: login
  failures, MFA failures, rate-limit triggers, permission escalation
  attempts, moderation abuse, suspicious websocket activity, abuse
  heuristics).
- Security visibility is mandatory.

### Auditability

- Critical operations MUST generate immutable audit records, attributable
  metadata and operational traceability.
- Auditability MUST support incident investigation, moderation review,
  security analysis and governance oversight.

### Alerting Philosophy

- Alerts MUST remain actionable, low-noise and operationally meaningful.
- The platform MUST avoid alert storms, non-actionable alerts and excessive
  operator fatigue.
- Critical alerts SHOULD include queue backlog, database degradation,
  replication failure, websocket cluster instability, authentication
  anomalies and infrastructure outage.

### Health Check Philosophy

- The platform MUST expose liveness checks, readiness checks, dependency
  health, queue health and replication status.
- Health endpoints MUST support orchestration systems, load balancers and
  operational automation.

### Incident Philosophy

- The architecture MUST assume outages, degraded nodes, propagation failure,
  partial data inconsistency, replay requirements and infrastructure
  instability.
- The observability system MUST support rapid diagnosis, forensic
  investigation, replay analysis and recovery workflows.

### Retention Philosophy

- Operational telemetry SHOULD support retention policies, tiered storage
  and archival workflows.
- The platform MUST balance observability value, storage cost and
  operational sustainability.

### Privacy & Compliance

- Observability systems MUST minimize sensitive exposure, support data
  minimization and avoid unsafe logging.
- Sensitive data SHOULD remain masked; redacted; excluded where possible.

### Tooling Philosophy

- Preferred tooling MAY include Prometheus, Grafana, Loki and OpenTelemetry.
- Tooling choices MUST remain replaceable, standards-oriented and
  operationally sustainable.

### Dashboard Philosophy

- Operational dashboards SHOULD expose realtime system state, queue health,
  replication status, profiling summaries, slow path reports, moderation
  throughput, security anomalies and websocket metrics.
- Dashboards MUST prioritize operational clarity and actionable visibility.

### Replay & Forensics

- The observability system SHOULD support replay investigation, workflow
  reconstruction, distributed tracing reconstruction, abuse analysis and
  moderation reconstruction.
- Distributed systems MUST remain explainable after failure.

### Long-Term Operational Goal

- The observability architecture MUST remain distributed-safe, scalable,
  audit-friendly, operationally sustainable, incident-ready and transparent
  under extreme concurrency.

### Engineering Invariants Amendment

Observability is an engineering invariant under ADR 0093.

- Every critical workflow MUST expose enough correlation data to
  reconstruct: request entry; actor where safe; command/service boundary;
  event/audit/outbox effects; worker execution where applicable; projection
  generation or lag where applicable; classified failure behavior.
- Silent workflow failure is prohibited.
- Metrics and logs MUST verify operational guarantees without leaking
  secrets.

## Consequences

- Incidents, abuse and performance regressions can be reconstructed from
  correlated logs, metrics, traces and audit records instead of guesswork.
- Every new workflow, queue, consumer and projection must ship with its
  metrics, correlation propagation and classified failure logging, which
  adds work to each change and to review.
- Telemetry must be scrubbed of secrets and personal data at the source,
  and retention must be budgeted against storage cost.
- Health endpoints become an operational contract with load balancers and
  orchestration, so their semantics must stay stable.
- Tooling (Prometheus, Grafana, Loki, OpenTelemetry) stays optional and
  replaceable; the contract is the data, not the vendor.
- Open conflict: logs MUST be structured and correlation-aware with JSON
  preferred, but `GPForum::Log` only sets the Mojolicious log level and
  controllers log free-text messages such as
  `"admin dashboard failed: $EVAL_ERROR"`. Structured request data exists
  today only as DB query observations keyed by `X-Request-ID` /
  `correlation_id` (`docs/OBSERVABILITY.md`).

## Alignment

- ADR 0012, ADR 0020, ADR 0047, ADR 0048
- ADR 0055 (events and realtime), ADR 0056 (workers), ADR 0057
  (governance), ADR 0063 (performance), ADR 0074 (privacy), ADR 0075
  (runbooks), ADR 0089 (profiling and coverage), ADR 0093 (engineering
  invariants), ADR 0099 (projection stability), ADR 0101 (search and feed
  execution)
- `lib/GPForum/Log.pm`, `lib/GPForum/Controller/Health.pm`,
  `lib/GPForum/Controller/Operations.pm`, `lib/GPForum/Web/HealthPayload.pm`,
  `lib/GPForum/Web/OperationsAccess.pm`,
  `lib/GPForum/Service/Operations/` (`Readiness.pm`, `MetricsSnapshot.pm`,
  `SecurityTelemetry.pm`, `DbQueryStats.pm`, `QueryBudget.pm`),
  `lib/GPForum/Infrastructure/AuditRecord.pm`
- `script/profile`, `script/profile-nytprof`, `script/profile-route`
- `docs/OBSERVABILITY.md`, `docs/PROFILING.md`,
  `docs/OPERATIONAL_BASELINE.md`, `docs/PRODUCTION_READINESS.md`
- `t/02-health.t`, `t/23-operations-hardening.t`,
  `t/33-health-readiness.t`, `t/56-db-query-stats.t`,
  `t/81-realtime-operational.t`, `t/116-infrastructure-audit-record.t`,
  `t/138-web-operations-access.t`
