# ADR 0098: Execution Constitution For Operational Integrity

## Status

Accepted. Converted on 2026-09-19 from `prompt/50.txt` ("GPForum - Execution
Constitution For Operational Integrity"); this ADR replaces the prompt as the
binding source.

## Context

GPForum is moving from "constitution plus structural MVP" into a complete,
navigable, durable forum platform. The risk in that move is architectural
drift: features added in ways that bypass events, audit, projections, or
permission boundaries already present in the repository.

Current phase: core operational architecture stabilization.

This ADR defines the mandatory execution discipline for evolving the existing
repository during that phase. It does not replace the other constitutions; it
binds implementation work to the concrete repository reality that already
exists. It governs every bounded context and every workflow change.
ADR 0099, ADR 0100, and ADR 0101 specialize its checklist.

## Decision

### Specialized Checklists

- Prompt 51 alignment (ADR 0099): the execution checklist is specialized for
  operational scalability and projection stability. Hot paths, query
  topology, projection offsets, blue/green rebuilds, hot-row avoidance,
  outbox retries, PostgreSQL-native search, disposable caches, online
  migrations, and observability must be considered for every scalable
  workflow.
- Prompt 52 alignment (ADR 0100): the execution checklist is specialized for
  domain integrity, authorization correctness, moderation safety, visibility
  enforcement, audit traceability, governance workflows, anti-leak
  guarantees, policy-safe projections, cache invalidation, and replay
  preservation.
- Prompt 53 alignment (ADR 0101): the execution checklist is specialized for
  retrieval. Search, feed, syndication, autocomplete, ranking, metadata, and
  discovery changes MUST answer canonical truth, projection shape, indexing
  trigger, rebuild strategy, permission safety, moderation safety, leak risk,
  replay, cache invalidation, and indexing failure behavior.

### 1. Primary Objective

- The goal of implementation work is not to generate random features.
- Every change MUST preserve and strengthen: deterministic architecture;
  append-oriented persistence; event discipline; auditability; projection
  correctness; permission safety; operational sustainability; low
  architectural entropy; long-term maintainability.
- A change that adds behavior but weakens these properties is
  architecturally incomplete.

### 2. Repository Reality Is Authoritative

- The existing GPForum repository is authoritative reality.
- Implementation MUST build on the current architecture, naming, module
  boundaries, persistence conventions, event semantics, tests, migrations,
  and operational scripts.
- The repository already contains: Mojolicious application root; DBIx::Class
  schema and result graph; identity registration workflow; Argon2id password
  service; session token service; event_log; audit_log; thread, post, body,
  and revision architecture; projection models; migration runner; CQRS-lite
  concepts; versioned visibility and permission tracking; aggregate
  versioning; correlation and idempotency semantics.
- New work MUST evolve this architecture incrementally.
- New work MUST NOT redesign the project from scratch.

### 3. Non-Negotiable Rules

- Controllers MUST remain thin.
- Services MUST remain explicit.
- Transactions MUST remain short and deterministic.
- GPForum implementation MUST NEVER:
  - place business logic in controllers;
  - place workflow logic in DBIx::Class result classes;
  - bypass event generation;
  - bypass audit generation;
  - create hidden side effects;
  - introduce implicit mutable globals;
  - introduce synchronous external dependencies in canonical write paths;
  - introduce microservice architecture;
  - make Redis authoritative;
  - make search authoritative;
  - introduce fragile ORM magic;
  - introduce uncontrolled background workflows.
- No convenience shortcut may override these rules.

### 4. Canonical State Discipline

- PostgreSQL remains authoritative. Canonical entities remain authoritative.
- Projection tables remain derived. Search indexes remain derived.
- Caches remain disposable. Realtime state remains disposable.
- Notifications remain derived from canonical state and events.
- Every workflow change MUST identify its canonical state before code is
  written.
- If a new row, cache entry, projection, worker output, or UI state cannot be
  classified as canonical, derived, or disposable, the design is incomplete.

### 5. Database Discipline

- The database architecture MUST preserve: append-oriented event storage;
  immutable audit history; rebuildable projections; partition-aware growth;
  online-safe migrations; explicit constraints; partial indexes where useful;
  covering indexes where useful; BRIN indexes for append-only logs where
  useful; projection lag visibility; outbox separation from canonical event
  persistence.
- Projection tables MUST remain rebuildable read models.
- Canonical tables MUST NOT become accidental projections.
- Derived tables MUST NOT become accidental sources of truth.

### 6. Event Discipline

- All significant workflows MUST emit durable events.
- Events MUST remain immutable, replayable, traceable, correlation-aware,
  idempotency-aware, and schema-versioned where appropriate.
- Outbox delivery MUST remain separated from canonical persistence.
- Worker failure MUST NOT invalidate committed canonical state.
- Event semantics MUST remain coherent across services.
- A workflow that changes canonical state without a corresponding event and
  audit decision is incomplete.

### 7. Audit Discipline

- Every security, moderation, authorization, administrative, privacy,
  identity, and governance-significant workflow MUST produce an audit record
  or explicitly document why no audit record is required.
- Audit records MUST remain immutable.
- Audit records MUST preserve actor, target, action, timestamp, metadata, and
  correlation context where available.
- Audit logs MUST NOT expose secrets.
- Audit absence for a privileged workflow is an operational defect.

### 8. Permission Discipline

- Visibility and authorization MUST never leak.
- Private, moderated, hidden, suspended, deleted, quarantined, or otherwise
  restricted content MUST NOT leak through:
  - search;
  - feeds;
  - projections;
  - autocomplete;
  - metadata;
  - RSS or Atom;
  - previews;
  - counters;
  - caches;
  - public profile surfaces;
  - sitemap output;
  - notification payloads.
- Permission-sensitive projections MUST be conservative.
- Permission checks MUST live in explicit policy, gate, or service
  boundaries.
- Controllers may request authorization checks, but MUST NOT become
  permission engines.

### 9. Projection Discipline

- Projection tables are rebuildable read models.
- Projection lag MUST be observable.
- Projection rebuild MUST be safe.
- Projection correctness MUST be verifiable.
- Projection generations SHOULD support safe rebuild and activation when the
  projection is user-visible or operationally critical.
- Stale projections MUST be detectable.
- No projection may become authoritative without an ADR that changes the
  data contract.

### 10. Transaction Discipline

- Canonical write workflows MUST use explicit transaction boundaries.
- Transactions MUST be short.
- Transactions MUST NOT include: HTML rendering; email delivery; external
  HTTP calls; search indexing; notification fanout; digest generation; heavy
  file processing; projection rebuilds; long-running analytics; template
  work.
- Correct write flow:

```text
validate -> authorize -> write canonical state/event/audit/outbox -> commit -> respond -> async work
```

- Rollback behavior MUST be deterministic.

### 11. Performance Discipline

- Performance work MUST prioritize: query topology; index correctness;
  hot-row avoidance; projection efficiency; transaction predictability;
  bounded reads; rebuildability; operational measurement.
- Implementation MUST avoid: N+1 queries; unnecessary joins; giant
  transactions; excessive object hydration; ORM-heavy bulk operations;
  synchronous integration calls; accidental OFFSET pagination on hot paths.
- DBIx::Class SHOULD be used for domain workflows.
- Raw SQL MAY be used for rebuilds, analytics, bulk ingestion, partition
  maintenance, and operational tooling when tested and documented.

### 12. Service Boundary Discipline

- Services MUST own workflow orchestration.
- Stores MUST own persistence writes for their bounded context.
- Readers MUST own query shape and view-model construction for read paths.
- Controllers MUST validate request shape, authorize, dispatch, and render.
- DBIx::Class result classes MUST map persistence and relationships only.
- Templates MUST render prepared view models and MUST NOT perform domain
  logic, query construction, heavy permission checks, or business rules.

### 13. Failure Mode Discipline

- Every new workflow MUST define the expected failure mode for: validation
  failure; authorization failure; not found; conflict; rate limit; database
  failure; outbox failure; worker failure; projection lag; search
  unavailability; cache invalidation failure.
- User-facing failures MUST be separated from system failures.
- Security-sensitive failures MUST NOT leak internals.
- Retry behavior MUST be explicit.

### 14. Rebuild And Replay Discipline

- GPForum MUST preserve replay and rebuild capability.
- A workflow is not complete until it answers:
  - can the projection be rebuilt;
  - can the event lineage be inspected;
  - can the audit path be reconstructed;
  - can failed async work be retried or dead-lettered;
  - can stale derived state be detected;
  - can permission-sensitive output be regenerated safely.
- Replay and rebuild failures are architectural failures.

### 15. Workflow Completion Checklist

Every workflow change MUST answer these questions before it is accepted:

1. What is canonical state?
2. What event is emitted?
3. What projection changes?
4. What audit record exists?
5. What indexes are affected?
6. What permissions are enforced?
7. What failure mode exists?
8. Can this be rebuilt?
9. Can this be replayed?
10. Can this scale operationally?

If the implementation cannot answer these questions, it is incomplete.

### 16. Code Generation Rules

- Before generating code, the implementer MUST inspect the existing modules,
  naming, event semantics, transaction boundaries, projection patterns, audit
  conventions, tests, migrations, and documentation.
- Generated code MUST: integrate coherently; compile; respect Perl::Critic
  discipline; preserve invariants; preserve event discipline; preserve
  auditability; preserve projection rebuildability; preserve operational
  sustainability; include tests appropriate to risk.
- Hypothetical architecture disconnected from repository reality is
  forbidden.

### 17. Drift Detection

- Architectural drift is expected pressure.
- GPForum MUST resist drift through: prompt alignment tests; architecture
  checks; Perl::Critic; coverage gates; migration review; contract tests;
  workflow tests; ADR discipline; README and MVP documentation updates.
- When the implementation diverges from a constitution, the change MUST
  either fix the implementation or update the constitution through explicit
  governance.
- Silent divergence is forbidden.

### 18. Final Rule

- GPForum grows by making existing guarantees executable, not by
  accumulating unbounded features.
- The correct next change is the one that makes the platform more usable
  while reducing entropy.
- The execution constitution is successful only when future development
  remains boring, traceable, testable, and operationally survivable.

## Consequences

- Every workflow change carries a fixed review cost: the Workflow Completion
  Checklist, a canonical/derived/disposable classification, an event and
  audit decision, and a declared failure mode.
- Features that add behavior while weakening events, audit, projections, or
  permission boundaries are rejected as incomplete, which slows raw feature
  throughput but keeps entropy low.
- Existing repository structure (thin controllers, services, stores,
  readers, outbox, projections) becomes the binding baseline; rewrites from
  scratch are excluded.
- Divergence between code and a constitution must be resolved in the same
  change, either by fixing code or by amending the governing ADR.
- With the prompt files removed, "prompt alignment tests" in section 17 are
  the ADR alignment checks in `t/09-prompt-alignment.t`, and "update the
  constitution" means amending the governing ADR (ADR 0087).

## Alignment

- ADR 0099, ADR 0100, ADR 0101 (specializations of this checklist)
- ADR 0064, ADR 0084, ADR 0087, ADR 0091, ADR 0093, ADR 0096 (constitutions
  aligned with this one)
- `docs/adr/0002-bootstrap-boundaries.md`
- `docs/adr/0005-posting-workflow-boundary.md`
- `docs/adr/0009-outbox-retry-semantics.md`
- `docs/adr/0020-audit-record-hashing.md`
- `script/architecture-check`, `script/perlcritic`, `script/coverage`,
  `bin/gpforum-migrate`
- `docs/ENGINEERING_CORRECTNESS.md`, `docs/MVP.md`,
  `docs/audit/transactional-correctness.md`, `docs/audit/failure-modes.md`
- `t/09-prompt-alignment.t`, `t/34-architecture-discipline.t`,
  `t/75-architecture-foundation.t`, `t/86-engineering-correctness.t`,
  `t/121-outbox-boundaries.t`
