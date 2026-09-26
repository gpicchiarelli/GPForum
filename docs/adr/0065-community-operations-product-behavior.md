# ADR 0065: Community Operations, Forum Structure And Product Behavior

## Status

Accepted. Converted on 2026-09-19 from `prompt/17.txt` ("GPForum - Community
Operations, Forum Structure & Product Behavior Constitution"); this ADR
replaces the prompt as the binding source.

## Context

GPForum is a living community system, not only a technical platform. Its
product behavior must stay predictable for users, governable by moderators,
and scalable for engineers.

This ADR defines the operational structure of the forum: community
hierarchy, discussion lifecycle, user-facing workflows, moderation
behavior, subscription model, feeds, trust signals, archival, and practical
product rules. It is foundational and mandatory and governs the forum,
posting, moderation, notification, subscription, feed, and community
bounded contexts.

## Decision

### Cross-ADR Alignment

- ADR 0094: community participation MUST be accessible. Category
  navigation, thread lists, posting flows, reporting flows, profile
  surfaces, bookmarks, mentions, and community operations MUST preserve
  semantic rendering, keyboard operation, assistive-technology
  compatibility, and low-bandwidth graceful degradation.
- ADR 0095: community operations MUST support human-centered lifecycle
  design: anonymous visitor, newcomer, participant, regular, trusted
  contributor, moderator, and long-term steward. Discovery, onboarding,
  continuity, recognition, moderation care, and retention systems MUST
  remain explainable, privacy-aware, permission-aware, and
  anti-dark-pattern.

### Operational Philosophy

- The product MUST prioritize: clear conversation structure; predictable
  moderation; user trust; readable information architecture; long-term
  content preservation; operational scalability; low social ambiguity.
- The platform MUST avoid: opaque content movement; hidden moderation;
  confusing hierarchy; irreversible routine actions; engagement mechanics
  that reward abuse; product behavior that conflicts with governance.

### Community Hierarchy

- Canonical hierarchy: site, space, category, thread, post, revision.
- A site MAY contain multiple spaces.
- A space represents a high-level community area.
- A category represents an operational discussion boundary inside a space.
- A thread is the primary conversation container.
- A post is the primary user-authored content unit.
- Hierarchy rules MUST remain explicit, permission-aware,
  moderation-aware, searchable, and stable under scale.

### Space Philosophy

- Spaces are community-level containers, navigation anchors, governance
  scopes, and optional permission boundaries.
- Spaces SHOULD support: title; slug; description; visibility state;
  display order; moderation policy reference; archival state.
- Spaces MUST NOT become unbounded policy dumping grounds.

### Category Philosophy

- Categories are topic boundaries, moderation scopes, permission scopes,
  feed groupings, and search filters.
- Categories MUST support:
  - `public`, `restricted`, `hidden`, `archived`, and `quarantined`
    visibility;
  - per-category posting rules;
  - moderator assignment;
  - thread ordering policy;
  - subscription eligibility.
- Category movement MUST be authorized, audited, event-emitting, and
  visible to moderators.

### Thread Lifecycle

- Thread states MUST be explicit.
- Canonical thread states: `draft`, `open`, `locked`, `hidden`,
  `quarantined`, `archived`, `deleted`.
- Open threads MAY accept replies.
- Locked threads MUST reject normal replies.
- Archived threads SHOULD remain readable when permitted.
- Quarantined threads MUST be hidden from public rendering until reviewed.
- Deleted threads SHOULD use soft deletion by default.
- Thread lifecycle changes MUST emit events.

### Post Lifecycle

- Post states MUST be explicit.
- Canonical post states: `draft`, `published`, `edited`, `hidden`,
  `quarantined`, `deleted`.
- Post creation MUST: validate input; check authorization; persist
  authoritative state; create an audit/event record; trigger asynchronous
  projections.
- Post editing MUST preserve revision history.
- Hard deletion MUST remain exceptional, authorized, audited, and usually
  reserved for legal or security requirements.

### Composer Behavior

- The post composer MUST support: server-side validation; preview where
  feasible; attachment intent; CSRF protection; rate-limit feedback;
  draft-safe failure behavior.
- The composer MUST NOT: trust client-side validation; render unsafe HTML;
  bypass moderation gates; lose user text silently on recoverable errors.

### Subscriptions

- Subscriptions represent user intent to follow activity.
- Supported targets SHOULD include: spaces; categories; threads; users
  where policy allows; search queries where policy allows.
- Subscriptions MUST support: creation; revocation; notification
  preferences; digest eligibility; mute controls.
- Subscriptions MUST remain user-scoped and permission-aware.

### Feeds

- GPForum SHOULD provide these feed views: recent discussions; unread
  subscriptions; category feed; space feed; user activity feed; moderation
  queue feed; search result feed.
- Feeds MUST be permission-aware, cache-safe, pagination-aware, and stable
  under concurrent writes.
- Feeds MUST NOT become authoritative persistence.

### Unread State

- Unread state SHOULD be derived from: user read markers; thread activity
  timestamps; subscription state; visibility permissions.
- Unread state MUST tolerate eventual consistency.
- Unread calculations MUST avoid expensive per-post scans during normal
  page rendering.

### Moderation Operations

- Moderation actions MUST be explicit.
- Canonical moderation actions: hide content; unhide content; lock thread;
  unlock thread; move thread; quarantine content; approve quarantined
  content; reject quarantined content; warn user; suspend user; ban user;
  restore content.
- Every moderation action MUST be authorized, scoped, attributable,
  timestamped, audited, and reversible where safe.

### Reporting

- Users SHOULD be able to report: posts; threads; profiles; attachments;
  private abuse surfaces if implemented.
- Reports MUST support: reason; optional details; target reference;
  reporter reference; status; review assignment; resolution record.
- Reports MUST NOT expose reporter identity to unauthorized users.

### Trust And Reputation

- Trust signals MAY influence: rate limits; moderation pre-review;
  attachment permissions; posting velocity; report weight.
- Trust MUST NOT become opaque authority.
- Trust-impacting changes MUST be explainable, bounded, and auditable.
- Reputation mechanics MUST avoid rewarding spam, harassment, brigading,
  or low-quality engagement loops.

### Notifications

- Notification triggers SHOULD include: reply to subscribed thread;
  mention; moderation action; report resolution; account security event;
  digest generation.
- Notifications MUST be permission-aware, asynchronous, deduplicated where
  appropriate, and revocable through user preferences.

### Archival

- Archival is a first-class lifecycle state.
- Archived content SHOULD: remain readable when authorized; stop accepting
  normal mutation; remain searchable where policy allows; remain
  reconstructable from canonical persistence.
- Archival MUST NOT be used as a hidden deletion mechanism.

### Operational UX

- User-facing behavior MUST be predictable.
- The interface SHOULD make these states clear: locked; archived; hidden;
  deleted; quarantined; unread; subscribed; rate-limited.
- The UI MUST NOT disclose sensitive moderation or security details to
  unauthorized users.

### Scalability Rules

- Community operations MUST scale through: append-oriented writes;
  asynchronous projections; permission-aware caching; denormalized read
  models; partition-aware persistence.
- Thread rendering MUST avoid unbounded queries.
- Large categories MUST support pagination, filtering, and archival.

### Long-Term Product Goal

- GPForum MUST remain understandable to users, governable by moderators,
  inspectable by operators, scalable by engineers, and durable over many
  years.
- The community structure is the product foundation of GPForum.

## Consequences

- Users and moderators get a stable vocabulary of hierarchy levels,
  lifecycle states, and moderation actions; every state change is audited
  and event-emitting, which feeds search, feeds, notifications, and
  realtime (ADR 0071).
- Soft deletion, revision history, and archival keep content reconstructable
  but grow storage; partitioning and archival (ADR 0069) carry that cost.
- Feeds, unread state, and trust signals are derived and must tolerate
  eventual consistency; they can never be used to decide authority.
- Open conflict: the current schema does not yet model the canonical
  states. `threads` and `posts` use `visibility IN ('public', 'members',
  'private')` and `moderation_state IN ('visible', 'hidden', 'locked',
  'deleted')`; there is no `draft`, `open`, `quarantined`, `archived`,
  `published`, or `edited` state for threads or posts, and spaces and
  categories have no `restricted`, `hidden`, `archived`, or `quarantined`
  visibility or archival column (`migrations/003_forum_projection.sql`).
- Open conflict: `reports.target_type` and `moderation_actions.target_type`
  accept only `thread`, `post`, and `user`
  (`migrations/008_moderation_review.sql`), so attachment reports and
  attachment moderation actions are not yet representable.

## Alignment

- ADR 0057 (authorization, moderation, governance), ADR 0061 (domain model),
  ADR 0069 (initial schema), ADR 0070 (permission matrix), ADR 0071 (event
  catalog), ADR 0073 (UX and interface behavior), ADR 0078 (notification
  delivery), ADR 0080 (content policy), ADR 0094 (accessibility), ADR 0095
  (human-centered community lifecycle), ADR 0100 (domain integrity and
  moderation execution).
- ADR 0005 (posting workflow), ADR 0010 (moderation workflow), ADR 0015
  (attachment and notification workflows), ADR 0041 (forum rate limits and
  input policy), ADR 0044 (moderation queue limits).
- `docs/PRODUCT_FLOWS.md`, `docs/UI_ACCESSIBILITY.md`,
  `docs/architecture/posting-workflow.md`,
  `docs/architecture/moderation-workflow.md`,
  `docs/architecture/notification-workflow.md`
- `migrations/003_forum_projection.sql`,
  `migrations/005_notifications_subscriptions.sql`,
  `migrations/007_advanced_community.sql`,
  `migrations/008_moderation_review.sql`
- `lib/GPForum/Service/Forum`, `lib/GPForum/Service/Moderation`,
  `lib/GPForum/Service/Notification`, `lib/GPForum/Service/Community`
