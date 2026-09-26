# ADR 0061: Domain Model, Core Entities and Business Architecture

## Status

Accepted. Converted on 2026-09-19 from `prompt/13.txt` ("GPForum — Domain
Model, Core Entities & Business Architecture Constitution"); this ADR replaces
the prompt as the binding source.

## Context

GPForum is a distributed community platform, an event-driven social system
and a long-lived collaborative environment. Without an explicit domain model,
business rules drift into controllers, stores and templates, entities grow
into god objects and cross-domain coupling becomes invisible.

This ADR is foundational and mandatory. It defines the domain architecture,
business entity philosophy, aggregate boundaries, lifecycle rules,
invariants, ownership semantics, revision strategies and long-term domain
consistency principles. It governs the Identity, Discussion, Moderation,
Authorization, Realtime, Notification, Search, Attachment, Governance and
Analytics domains. The domain model is the semantic foundation of the
platform.

## Decision

### Domain Integrity Alignment

- Per ADR 0100, domain entities MUST preserve canonical truth, explicit
  visibility state, explicit moderation state, revision history, event
  emission, audit traceability, projection safety, cache invalidation,
  anti-leak invariants and replay-safe reconstruction.

### Domain Philosophy

- GPForum is a distributed community platform, an event-driven social system
  and a long-lived collaborative environment.
- The domain model MUST prioritize explicit business meaning, bounded
  responsibility, auditability, scalability, operational sustainability and
  long-term coherence.
- The domain model MUST avoid accidental complexity, god entities, implicit
  relationships and uncontrolled cross-domain coupling.

### Domain Architecture Philosophy

- The domain layer MUST remain infrastructure-independent,
  persistence-independent and transport-independent.
- Business rules MUST live inside domain services, application workflows and
  domain invariants.
- The domain model MUST remain authoritative for business semantics,
  ownership rules, moderation constraints and lifecycle rules.

### Aggregate Philosophy

- Aggregates MUST remain bounded, explicit and consistency-aware.
- Aggregates SHOULD minimize locking scope, minimize transactional complexity
  and support distributed workflows.
- The architecture MUST avoid giant transactional aggregates and hidden
  cross-domain mutation.

### Core Domain Areas

- Recommended domain boundaries: Identity, Discussion, Moderation,
  Authorization, Realtime, Notification, Search, Attachment, Governance,
  Analytics.
- Each domain MUST remain explicit, bounded and independently understandable.

### Identity Domain

- Core entities: User, Session, Credential, MFADevice, TrustProfile.
- The identity system MUST support revocation, auditability, distributed
  sessions and security-first workflows.
- Identity state MUST remain authoritative.

### User Entity Philosophy

- Users are security principals, ownership anchors, moderation subjects and
  authorization actors.
- User entities MUST support lifecycle tracking, trust evolution, moderation
  state and permission relationships.
- The system MUST avoid implicit authority assumptions.

### Discussion Domain

- Core entities: Thread, Post, PostRevision, Category, Tag, Subscription.
- Discussion entities MUST support scalability, revision history, moderation
  workflows and distributed rendering.

### Thread Philosophy

- Threads are conversation containers, moderation scopes and realtime
  synchronization targets.
- Threads MUST support locking, archival, visibility control, category
  scoping and moderation state.
- Thread lifecycle MUST remain explicit.

### Post Philosophy

- Posts are immutable historical artifacts, user-owned content entities and
  moderation targets.
- Posts SHOULD prefer append-oriented revision history.
- Post editing SHOULD generate revision records, audit trails and
  synchronization events.

### Revision Philosophy

- Mutable content SHOULD support immutable revisions (for example
  `post_revisions`, `moderation_revisions`, `policy_revisions`).
- Historical reconstruction SHOULD remain possible.

### Category Philosophy

- Categories are organizational boundaries, moderation scopes and
  authorization boundaries.
- Categories MUST support scoped moderation, scoped permissions, visibility
  policies and lifecycle governance.

### Tag Philosophy

- Tags SHOULD remain lightweight, queryable, searchable and moderation-aware.
- Tags MUST support permission-aware visibility, moderation workflows and
  scalable indexing.

### Subscription Philosophy

- Subscriptions represent notification intent, follow state and
  personalization metadata.
- Subscriptions MUST remain revocable, queryable and asynchronous-friendly.

### Notification Domain

- Core entities: Notification, NotificationPreference, DeliveryAttempt.
- Notifications MUST support asynchronous delivery, distributed fanout,
  replayability and eventual consistency.
- Notifications MUST remain permission-aware and user-scoped.

### Moderation Domain

- Core entities: ModerationAction, Report, Suspension, TrustRestriction,
  QuarantineEntry.
- Moderation workflows MUST remain auditable, attributable and reversible
  where possible.
- Moderation entities MUST support escalation, review and lifecycle tracking.

### Authorization Domain

- Core entities: Role, Permission, RoleBinding, ResourcePolicy.
- Authorization entities MUST support contextual evaluation, scoped authority
  and explicit revocation.
- The authorization model MUST avoid hidden privilege inheritance.

### Attachment Domain

- Core entities: Attachment, AttachmentVariant, MediaProcessingTask.
- Attachments MUST support asynchronous processing, scanning workflows,
  immutable storage references and lifecycle management.
- Attachments MUST NOT execute server-side or bypass moderation.

### Search Domain

- Core entities: SearchDocument, SearchProjection, IndexingTask.
- Search MUST remain projection-oriented, asynchronously synchronized and
  rebuildable.
- Search state MUST remain reconstructable from authoritative persistence.

### Realtime Domain

- Core entities: PresenceSession, WebsocketConnection, SubscriptionChannel.
- Realtime entities SHOULD remain ephemeral, reconstructable and eventually
  consistent.
- Realtime state MUST NOT become authoritative business persistence.

### Analytics Domain

- Analytics SHOULD remain append-oriented, partition-aware and asynchronous.
- Analytics MUST NOT block operational workflows or become transactional
  dependencies.

### Ownership Philosophy

- Ownership MUST remain explicit (for example post, attachment, moderation
  and thread ownership).
- Ownership MUST support transfer rules, revocation and moderation override.

### Lifecycle Philosophy

- All major entities SHOULD support creation, moderation, archival and
  expiration where applicable.
- Lifecycle state MUST remain explicit, queryable and auditable.

### Visibility Philosophy

- Visibility MUST support public, restricted, moderated, quarantined and
  deleted visibility.
- Visibility rules MUST remain authorization-aware and moderation-aware.

### Soft Deletion Philosophy

- Destructive deletion SHOULD be minimized.
- Preferred approach: soft deletion, archival, reversible moderation.
- Hard deletion SHOULD remain exceptional, restricted and auditable.

### Event Integration

- All major domain workflows SHOULD emit domain events, moderation events,
  synchronization events and audit events.
- The domain model MUST remain event-aware and replay-friendly.

### Invariant Philosophy

- Critical invariants MUST remain explicit, testable and centralized.
- Examples: locked threads reject replies; suspended users cannot post;
  quarantined content cannot render publicly.
- Invariant enforcement MUST remain server-authoritative.

### CQRS-lite Philosophy

- The domain model SHOULD support canonical write persistence, asynchronous
  projections and denormalized read models.
- Read models MUST remain rebuildable and eventually consistent where
  appropriate.

### Domain Service Philosophy

- Complex workflows SHOULD use domain services and application workflows.
- Entities SHOULD avoid infrastructure coupling and orchestration complexity.

### Long-Term Domain Goal

- The domain architecture MUST remain coherent, scalable, auditable,
  distributed-safe, operationally sustainable and understandable by future
  maintainers.
- The domain model is the semantic foundation of the platform.
- All future business logic and entities MUST comply with this ADR.

## Consequences

- Each bounded context has named entities, explicit ownership, lifecycle and
  visibility states, so moderation, authorization and search can reason about
  the same vocabulary.
- Append-oriented revisions, soft deletion and event emission increase
  storage and write volume in exchange for auditability and replay-safe
  reconstruction.
- Search, realtime, analytics and other read models stay disposable and must
  be rebuildable from canonical PostgreSQL state.
- Open conflicts:
  - `GPForum::Domain::*` holds only `EventEnvelope`; `ARCHITECTURE.md`
    introduces the Domain/Application layer incrementally, and business
    rules live in `GPForum::Service::*` workflows and DBIx::Class stores.
    The infrastructure- and persistence-independent domain layer is not yet
    realized.
  - The example invariants are not centralized: "locked threads reject
    replies" is enforced in `GPForum::Service::Forum::PostingWorkflow`, while
    "suspended users cannot post" is enforced in
    `GPForum::Controller::Forum::Base` (`_reject_suspended`).
  - `t/09-prompt-alignment.t` reads `prompt/13.txt` to check the domain
    integrity alignment marker and will fail once the prompt is deleted.

## Alignment

- ADR 0100 (domain integrity, authorization and moderation execution).
- ADR 0069 (initial schema), ADR 0070 (permission matrix), ADR 0071 (event
  catalog and workflow contracts), ADR 0057 (authorization and moderation),
  ADR 0055 (event-driven realtime), ADR 0062 (search), ADR 0074 (privacy).
- ADR 0005 (posting workflow), ADR 0010 (moderation workflow), ADR 0014
  (identity workflow), ADR 0015 and ADR 0027 (attachment and notification
  workflows, attachment lifecycle), ADR 0035, ADR 0036 and ADR 0037
  (moderation events).
- `ARCHITECTURE.md`, `EVENTS.md`, `lib/GPForum/Domain/EventEnvelope.pm`,
  `lib/GPForum/Service/Forum/PostingWorkflow.pm`.
- `migrations/001_core_identity.sql`, `migrations/003_forum_projection.sql`
  (`post_revisions`), `migrations/005_notifications_subscriptions.sql`,
  `migrations/006_attachments.sql`, `migrations/008_moderation_review.sql`.
- `t/11-forum-thread.t`, `t/12-forum-post.t`, `t/25-moderation-review.t`,
  `t/95-moderation-workflow.t`, `t/09-prompt-alignment.t`.
