# ADR 0100: Domain Integrity, Authorization And Moderation Execution Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/52.txt` ("GPForum - Domain
Integrity, Authorization And Moderation Execution Constitution"); this ADR
replaces the prompt as the binding source.

## Context

A forum is only useful if members can trust that private, hidden, deleted,
or moderated content stays where policy puts it, that staff actions are
traceable, and that derived surfaces cannot drift into hidden authority.

This ADR defines the mandatory execution discipline for domain integrity,
authorization correctness, moderation safety, visibility enforcement, audit
traceability, governance workflows, anti-leak guarantees, and policy-safe
projections in the existing GPForum repository.

It extends ADR 0098 (the general execution checklist) and ADR 0099
(operational scalability and projection stability), and specializes both for
permission-safe, moderation-safe, audit-safe, replay-safe,
governance-capable implementation. It governs identity, forum, moderation,
admin, privacy, notification, search and discovery, realtime, and plugin
workflows.

## Decision

### Relationship To Other Constitutions

- This constitution preserves all GPForum constitutions, including
  PostgreSQL authority, Perl-first implementation, Mojolicious delivery,
  DBIx::Class persistence, Minion workers, SSR-first rendering,
  append-oriented persistence, event/audit/outbox discipline, projection
  rebuildability, explicit governance, accessibility, privacy boundaries, and
  optional Redis acceleration only.
- Prompt 53 alignment (ADR 0101): all search, feed, syndication,
  autocomplete, metadata, ranking, and recommendation surfaces are derived
  retrieval systems. They MUST enforce permission safety, moderation safety,
  deletion safety, anti-leak rules, cache invalidation, and
  replay-preserving projection rebuilds.

### 1. Primary Objective

- GPForum MUST evolve into a permission-safe system, moderation-safe system,
  audit-safe system, replay-safe system, and governance-capable platform.
- Every domain workflow MUST preserve: deterministic moderation; explainable
  authorization; reconstructable audit history; projection safety;
  visibility correctness; anti-leak behavior; replay safety; low
  architectural entropy.
- A feature that works functionally but weakens permission safety,
  moderation safety, auditability, visibility correctness, or replayability
  is incomplete.

### 2. Canonical Domain Rule

- Canonical truth MUST remain in:
  - PostgreSQL;
  - canonical relational entities;
  - append-only event_log;
  - immutable audit_log.
- Projection tables remain derived. Caches remain disposable. Search remains
  derived. External integrations remain optional and non-authoritative.
- No projection, cache, search document, notification row, feed item,
  websocket state, or external integration may become hidden domain
  authority.

### 3. Authorization Model

- GPForum uses RBAC, ABAC, visibility state, moderation state, ownership
  checks, and scope-aware permissions.
- Authorization MUST remain explicit.
- Every sensitive workflow MUST evaluate actor, action, resource, scope,
  visibility state, moderation state, ownership, and applicable policy
  conditions.
- Implementations MUST NOT rely on:
  - implicit UI hiding;
  - cache-only filtering;
  - search-only filtering;
  - frontend trust;
  - unreviewed default allow behavior;
  - route naming as authorization;
  - template omission as protection.
- Authorization failures MUST be classified separately from validation
  failures, not-found failures, rate-limit failures, and infrastructure
  failures.

### 4. Mandatory Authorization Questions

Every workflow MUST explicitly answer:

- who can read?
- who can write?
- who can moderate?
- who can delete?
- who can restore?
- who can move?
- who can search?
- who can subscribe?
- who can export?

If any answer is ambiguous, the implementation is invalid. These answers MUST
be visible in service contracts, policy engines, tests, or route/workflow
documentation. They MUST NOT live only in a controller comment, template
branch, or README promise.

### 5. Visibility Discipline

- Visibility MUST remain explicit.
- Recognized visibility and policy states MAY include: public; members;
  private; quarantined; hidden; deleted.
- Visibility MUST propagate consistently through:
  - thread views;
  - post views;
  - search;
  - RSS and Atom feeds;
  - notifications;
  - previews;
  - projections;
  - counters;
  - metadata;
  - OpenGraph;
  - sitemap generation;
  - autocomplete;
  - profile activity;
  - exports;
  - plugin hooks.
- No restricted content may leak through any derived or public surface.
- Visibility rules MUST be conservative under failure. If a projection,
  cache, search document, feed builder, or metadata builder cannot prove that
  content is renderable to the actor, it MUST omit that content.

### 6. Moderation Discipline

- Moderation MUST remain server-authoritative.
- Moderation actions MUST: enforce authorization; emit events; create audit
  records; update visibility_version or permission_version when relevant;
  invalidate projections; invalidate caches where necessary; preserve
  replayability; preserve evidence chains where policy permits.
- Moderation MUST remain deterministic, reversible where feasible,
  explainable, and reconstructable from canonical records.
- Moderation tools MUST NOT rely on client-side hiding, plugin-only
  enforcement, search filtering alone, or process-local state.

### 7. Soft Delete Discipline

- User content MUST prefer soft deletion, moderation state changes, and
  visibility transitions.
- Hard deletion MUST remain exceptional.
- Deletion MUST preserve auditability, referential safety, projection
  correctness, replay integrity, privacy-policy compatibility, and legal-hold
  compatibility.
- Hard deletion, anonymization, and erasure jobs MUST be governed by explicit
  privacy and retention workflows. They MUST NOT be ad hoc controller
  behavior.

### 8. Revision Discipline

- User-generated content SHOULD remain revision-based.
- Edits MUST:
  - preserve historical revisions;
  - preserve edit attribution;
  - preserve timestamps;
  - preserve moderation traceability;
  - preserve event lineage;
  - update render/search projections through explicit derived workflows.
- The current visible revision is a projection of immutable history.
- Revision rendering MUST respect visibility, moderation state, permission
  scope, and privacy rules. Old revisions MUST NOT leak through previews,
  search, metadata, feeds, exports, or plugin callbacks.

### 9. Audit Discipline

- All security-sensitive actions MUST create immutable audit records.
- Examples: login; failed login; role assignment; permission change;
  moderation action; deletion; restoration; session revocation; visibility
  change; administrative override; export approval; privacy workflow action;
  plugin capability change.
- Audit records MUST remain immutable, queryable, timestamped,
  correlation-aware, actor-aware, and safe for incident reconstruction.
- Audit logs MUST avoid secret leakage. Audit logs MUST preserve enough
  context to reconstruct what happened without exposing passwords, session
  tokens, API keys, private message bodies, or restricted content beyond
  approved forensic scope.

### 10. Event Discipline

- All domain-significant workflows MUST emit events.
- Events MUST: remain immutable; remain append-only; support replay; support
  projection rebuild; support correlation tracing; support causation
  tracing; support idempotency; preserve aggregate lineage.
- Event payloads MUST be versioned where evolution is expected.
- Events are facts. They MUST NOT be mutated to repair projections.
  Projection repair MUST happen through replay, compensating events, rebuild
  generations, or explicit repair workflows.

### 11. Permission Versioning

- Permission-sensitive entities SHOULD expose `visibility_version` and
  `permission_version`.
- Projection rebuilds, search indexing, cache keys, metadata builders, feed
  builders, notification rendering, and plugin callbacks MUST use these
  versions conservatively when content visibility can change.
- A stale permission-sensitive projection MUST fail closed.

### 12. Anti-Leak Discipline

- Private or moderated content MUST NEVER leak through:
  - search;
  - RSS;
  - Atom;
  - feeds;
  - autocomplete;
  - counters;
  - metadata;
  - previews;
  - notifications;
  - projection tables;
  - caches;
  - OpenGraph;
  - sitemap generation;
  - profile summaries;
  - exports;
  - plugin hooks;
  - realtime events.
- Permission safety is more important than convenience, speed, SEO,
  engagement, or cache hit rate.
- If an implementation cannot prove visibility safety, it MUST omit the
  content and expose an observable degraded state where appropriate.

### 13. Search Safety

- Search results MUST remain permission-aware, moderation-aware,
  visibility-aware, deletion-aware, rebuildable, and derived.
- Search snippets MUST NOT expose restricted content.
- Autocomplete MUST remain bounded and conservative.
- Search ranking MUST NOT override visibility, moderation, or authorization.
- Search documents MUST be invalidated or rebuilt when visibility_version,
  permission_version, moderation_state, deletion state, or current revision
  changes.

### 14. Notification Discipline

- Notifications MUST: respect permissions at creation; respect permissions at
  render; tolerate visibility changes; tolerate moderation changes; tolerate
  deletion; tolerate replay; avoid restricted snippets unless explicitly
  safe.
- Notification projections MUST remain derived.
- Notification inboxes MUST NOT become evidence of restricted content to an
  actor who can no longer see the source resource.
- Notification rendering MUST re-check visibility or use a conservative
  permission snapshot with version validation.

### 15. Governance Discipline

- The architecture SHOULD support moderator actions, administrative actions,
  suspension workflows, escalation workflows, policy enforcement, audit
  investigation, historical reconstruction, appeal workflows, emergency
  access recovery, and role review.
- Governance actions MUST remain explainable.
- Governance workflows MUST be audit-backed, permission-scoped, reversible
  where feasible, and protected from silent privilege escalation.

### 16. Domain Invariants

Mandatory invariants include:

- deleted content is not publicly visible;
- hidden posts do not appear in search;
- suspended users cannot create content;
- revoked sessions cannot authenticate;
- restricted threads do not appear in RSS;
- private metadata does not appear in OpenGraph;
- quarantined content does not appear in public feeds;
- audit records are immutable;
- event history remains append-only;
- projections remain rebuildable;
- caches remain disposable;
- search remains derived;
- moderation actions remain traceable;
- permission changes are observable;
- authorization failures do not reveal restricted content.

Invariant violations are production-critical failures. Every new workflow
MUST preserve these invariants or document a stricter replacement invariant
through ADR review.

### 17. Policy-Safe Projections

- Projection tables MUST remain policy-safe.
- Projection writers MUST:
  - consume canonical events or canonical rows;
  - apply visibility rules;
  - apply moderation rules;
  - preserve permission_version and visibility_version where relevant;
  - tolerate duplicate delivery;
  - tolerate retry;
  - tolerate replay;
  - fail closed under ambiguous authorization;
  - expose lag and rebuild state where operationally relevant.
- Projection readers MUST NOT assume projection presence proves permission.
- Policy-sensitive projections SHOULD include enough version metadata to
  detect stale permission or visibility decisions.

### 18. Cache Invalidation

- Caches are disposable acceleration only.
- Any cache containing visibility-sensitive derived content MUST have: actor
  or scope-safe keys; TTL; bounded size; event-driven invalidation where
  feasible; version-aware invalidation where feasible; conservative fallback
  behavior.
- Caches MUST NOT bypass authorization.
- Caches MUST NOT be used as the only source of moderation state.

### 19. HTTP Workflow Discipline

- HTTP controllers MUST remain thin.
- Controllers MAY: parse request input; invoke CSRF checks; call rate
  limiters; identify the actor; dispatch to services; map classified errors
  to responses; render service-provided view models.
- Controllers MUST NOT:
  - manipulate DBIx::Class resultsets directly;
  - implement authorization policy inline;
  - implement moderation workflows inline;
  - update canonical state outside service/store contracts;
  - bypass event, audit, or outbox generation.
- SSR rendering MUST remain permission-safe. Templates MUST receive view
  models that are already authorized and visibility-filtered.

### 20. Required Implementation Review

Before merging a workflow change, implementation MUST answer:

1. What is canonical truth?
2. What permissions apply?
3. What visibility applies?
4. What moderation state applies?
5. What event is emitted?
6. What audit record is created?
7. What projection changes?
8. What cache invalidates?
9. What could leak?
10. How is replay preserved?

If these answers are missing, the implementation is incomplete. These
questions are mandatory for code review, prompt alignment, tests, migration
planning, plugin integration, and AI-assisted implementation.

### 21. Testing Requirements

- Domain integrity changes MUST include tests for:
  - allowed access;
  - denied access;
  - missing resource;
  - hidden resource;
  - deleted resource;
  - suspended actor where relevant;
  - audit emission;
  - event emission;
  - projection behavior;
  - search/feed/metadata no-leak behavior where relevant;
  - replay or idempotency where relevant.
- Authorization tests MUST include negative cases.
- Moderation tests MUST verify event, audit, version, and projection effects.
- Search and discovery tests MUST verify that hidden, deleted, private, and
  quarantined content does not leak.

### 22. ADR Requirements

- ADR approval is required for:
  - hard deletion of user content;
  - introducing a new visibility state;
  - introducing a new moderation state;
  - changing permission semantics;
  - making a derived table influence canonical writes;
  - exposing new public metadata surfaces;
  - plugin capabilities that can observe or alter restricted content;
  - search ranking changes that affect governance or visibility;
  - cache strategies for permission-sensitive content;
  - external integrations that receive content payloads.
- ADR records MUST include anti-leak analysis and replay impact.

### 23. Final Rule

- GPForum must be useful because it is safe to trust.
- Domain integrity, authorization correctness, moderation safety, audit
  traceability, and anti-leak behavior are not optional quality attributes.
  They are part of the executable architecture.
- No feature is complete until it is safe to authorize, safe to moderate,
  safe to audit, safe to rebuild, safe to replay, and safe to expose.

## Consequences

- Authorization, visibility, and moderation decisions stay explicit and
  server-side; UI hiding, cache filtering, or template omission never count
  as protection.
- Every derived surface (search, feeds, metadata, notifications, counters,
  caches, exports, plugin hooks, realtime) must fail closed when it cannot
  prove visibility, trading some discoverability and cache hit rate for
  safety.
- Moderation and governance actions always carry events, audit records, and
  version bumps, which makes incidents reconstructable but adds write-path
  and test work.
- Hard deletion becomes an exceptional, privacy-workflow-driven operation;
  soft deletion and revision history are the default.
- Workflow changes carry the ten-question review and negative authorization
  and no-leak tests; the listed high-risk changes additionally need an ADR
  with anti-leak analysis and replay impact.

## Alignment

- ADR 0098, ADR 0099 (extended constitutions), ADR 0101 (retrieval
  specialization)
- ADR 0053, ADR 0057, ADR 0061, ADR 0070, ADR 0071, ADR 0072, ADR 0074,
  ADR 0079, ADR 0080, ADR 0082 (constitutions aligned with this one);
  ADR 0091, ADR 0093
- `docs/adr/0007-websocket-authorization-policy.md`
- `docs/adr/0010-moderation-workflow-boundary.md`
- `docs/adr/0011-admin-workflow-boundary.md`
- `docs/adr/0013-privacy-workflow-boundary.md`
- `docs/adr/0020-audit-record-hashing.md`
- `docs/adr/0023-privacy-erasure-record.md`
- `docs/adr/0044-moderation-access.md`, `docs/adr/0046-admin-access.md`
- `lib/GPForum/Service/Moderation/` (`Workflow`, `ActionStore`,
  `ReportStore`, `SuspensionStore`, `ReviewReader`)
- `lib/GPForum/Service/Admin/` (`PermissionGate`, `RoleCatalog`,
  `RoleBindingStore`, `PermissionReview`, `AuditReview`)
- `lib/GPForum/Service/Search/PermissionEngine.pm`,
  `lib/GPForum/Service/Discovery/VisibilityPolicy.pm`
- `lib/GPForum/Infrastructure/AuditRecord.pm`,
  `lib/GPForum/Infrastructure/EventRecorder.pm`
- `docs/architecture/moderation-workflow.md`,
  `docs/architecture/admin-workflow.md`,
  `docs/architecture/privacy-workflow.md`
- `t/25-moderation-review.t`, `t/26-admin-authorization.t`,
  `t/29-privacy-rights.t`, `t/30-public-discovery.t`,
  `t/43-moderation-web.t`, `t/95-moderation-workflow.t`,
  `t/97-admin-workflow.t`, `t/116-infrastructure-audit-record.t`
- `t/09-prompt-alignment.t`
