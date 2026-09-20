# ADR 0069: Initial Database Schema And Persistence Blueprint

## Status

Accepted. Converted on 2026-09-19 from `prompt/21.txt` ("GPForum - Initial
Database Schema & Persistence Blueprint Constitution"); this ADR replaces
the prompt as the binding source.

## Context

PostgreSQL is the authoritative store (ADR 0051, ADR 0067). This ADR gives
the initial database blueprint: core tables, relationships, indexing
expectations, partitioning direction, and persistence invariants. It is a
starting blueprint and MUST evolve through migrations and ADRs. It governs
the identity, forum, authorization, moderation, event/audit, notification,
and attachment bounded contexts.

## Decision

### Cross-ADR Alignment

- ADR 0093: schema evolution MUST be invariant-aware. New tables and
  columns MUST identify whether they are canonical, derived, disposable,
  rebuildable, or operational metadata. Persistence changes MUST preserve
  replay, authorization, audit, and projection rebuild guarantees.

### Schema Philosophy

- The database MUST start small but structurally correct.
- The initial schema MUST support: users; sessions; spaces; categories;
  threads; posts; revisions; roles and permissions; moderation; events;
  notifications; attachments; audit logs.
- The schema MUST avoid:
  - giant unbounded mutable tables without partition strategy;
  - implicit boolean privilege flags;
  - hidden destructive deletion;
  - business-critical JSON blobs without indexed canonical columns.

### Identity Tables

- `users`: `id`, `username`, `display_name`, `email_normalized`,
  `password_hash`, `status`, `trust_level`, `version`,
  `permission_version`, `created_at`, `updated_at`, `deleted_at`.
- `sessions`: `session_id`, `user_id`, `session_hash`, `created_at`,
  `last_seen_at`, `expires_at`, `revoked_at`, `ip_hash`,
  `user_agent_hash`.
- `credentials`: `id`, `user_id`, `type`, `secret_hash`, `created_at`,
  `revoked_at`.

### Forum Structure Tables

- `spaces`: `id`, `slug`, `title`, `description`, `visibility`,
  `sort_order`, `created_at`, `archived_at`.
- `categories`: `id`, `space_id`, `slug`, `title`, `description`,
  `visibility`, `posting_policy`, `sort_order`, `created_at`,
  `archived_at`.
- `threads`: `id`, `category_id`, `author_user_id`, `title`, `slug`,
  `visibility`, `moderation_state`, `version`, `visibility_version`,
  `permission_version`, `last_activity_at`, `created_at`, `updated_at`,
  `archived_at`, `deleted_at`.
- `posts`: `id`, `thread_id`, `author_user_id`, `current_body_id`,
  `current_revision_id`, `visibility`, `moderation_state`, `version`,
  `visibility_version`, `permission_version`, `position`, `created_at`,
  `updated_at`, `hidden_at`, `locked_at`, `deleted_at`.
- `post_bodies`: `id`, `post_id`, `body_format`, `body_source`,
  `body_rendered_safe`, `source_hash`, `created_at`.
- `post_revisions`: `id`, `post_id`, `author_user_id`, `body_format`,
  `body_source`, `body_rendered_safe`, `edit_reason`, `created_at`.
- Thread lists MUST NOT load post body text. Lists read heads and
  projections; detail pages load bodies explicitly.
- Derived counters MUST live in `thread_counters` and `category_stats`
  projections unless an ADR accepts a transactional projection column.

### Authorization Tables

- `roles`: `id`, `name`, `description`, `created_at`.
- `permissions`: `id`, `name`, `description`.
- `role_permissions`: `role_id`, `permission_id`.
- `role_bindings`: `id`, `user_id`, `role_id`, `scope_type`, `scope_id`,
  `created_by_user_id`, `created_at`, `revoked_at`.
- `resource_policies`: `id`, `resource_type`, `resource_id`,
  `policy_key`, `policy_value`, `created_at`, `updated_at`.

### Moderation Tables

- `reports`: `id`, `reporter_user_id`, `target_type`, `target_id`,
  `reason`, `details`, `status`, `assigned_moderator_user_id`,
  `created_at`, `resolved_at`.
- `moderation_actions`: `id`, `actor_user_id`, `action_type`,
  `target_type`, `target_id`, `reason`, `metadata`, `created_at`,
  `reversed_at`, `reversed_by_user_id`.
- `suspensions`: `id`, `user_id`, `actor_user_id`, `reason`,
  `starts_at`, `ends_at`, `created_at`, `revoked_at`.

### Event And Audit Tables

- `event_log`: `event_id`, `event_type`, `schema_version`,
  `aggregate_type`, `aggregate_id`, `actor_id`, `correlation_id`,
  `causation_id`, `idempotency_key`, `payload`, `metadata`, `created_at`.
- `audit_log`: `id`, `actor_user_id`, `action`, `target_type`,
  `target_id`, `ip_hash`, `user_agent_hash`, `metadata`, `created_at`.
- `event_log` SHOULD be append-only.
- `audit_log` SHOULD be append-only.

### Notification Tables

- `subscriptions`: `id`, `user_id`, `target_type`, `target_id`,
  `preference`, `created_at`, `muted_at`, `revoked_at`.
- `notifications`: `id`, `user_id`, `type`, `source_type`, `source_id`,
  `payload`, `read_at`, `created_at`.
- `notification_delivery_attempts`: `id`, `notification_id`, `channel`,
  `status`, `attempted_at`, `error_code`.

### Attachment Tables

- `attachments`: `id`, `owner_user_id`, `object_key`,
  `original_filename`, `media_type`, `byte_size`, `checksum`, `state`,
  `created_at`, `deleted_at`.
- `attachment_links`: `id`, `attachment_id`, `target_type`, `target_id`,
  `created_at`.
- `attachment_variants`: `id`, `attachment_id`, `variant_type`,
  `object_key`, `media_type`, `byte_size`, `created_at`.

### Indexing Expectations

The schema MUST include indexes for:

- username lookup;
- email lookup;
- active sessions by user;
- categories by space;
- threads by category and last activity;
- posts by thread and creation time;
- reports by status;
- role bindings by user and scope;
- events by aggregate and creation time;
- notifications by user and read state.

### Partitioning Direction

- These tables SHOULD be evaluated for partitioning: `event_log`,
  `audit_log`, `notifications`.
- `users`, `threads`, `categories`, and `sessions` MUST NOT be partitioned
  without an ADR and measured operational need.
- Partitioning strategy MUST be decided before any high-volume append
  table reaches operational scale.

### Migration Rule

Every schema change MUST be:

- migration-driven;
- reviewable;
- rollback-aware where possible;
- compatible with running application nodes during deployment when
  feasible.

## Consequences

- Canonical content is split into heads (`posts`), bodies (`post_bodies`),
  and history (`post_revisions`), so list pages stay cheap and edits keep
  full history.
- Explicit `version`, `visibility_version`, and `permission_version`
  columns give caches and projections a cheap invalidation key
  (ADR 0067).
- Counters live in projections, so hot writes avoid row contention on
  `threads` and `categories`, at the cost of eventual consistency.
- Append-only event and audit logs grow without bound; partitioning and
  retention must be operated (`docs/architecture/partition-lifecycle.md`).
  `event_log`, `audit_log`, and `notifications` are already range
  partitioned by `created_at` with default partitions.
- Open conflict: the migrations have evolved away from the blueprint
  without an ADR recording each deviation. Notable differences:
  - primary keys are mostly `<entity>_id` (`space_id`, `thread_id`,
    `post_id`, `role_id`, `binding_id`, `audit_id`, ...) instead of `id`;
  - `spaces` and `categories` use `position` instead of `sort_order` and
    `deleted_at` instead of `archived_at`; `categories.posting_policy` and
    `threads.archived_at` do not exist;
  - `permissions` has `resource_type` and `action` instead of
    `description`; `role_bindings` scopes with `resource_type`,
    `resource_id`, and `space_id` instead of `scope_type` and `scope_id`;
  - `resource_policies` does not exist; `resource_acl` is the closest
    equivalent;
  - `suspensions` uses `valid_from` and `valid_to` instead of `starts_at`
    and `ends_at` and has no `created_at`;
  - `post_revisions` references `body_id` with `editor_user_id` and
    `revision_number` instead of copying the body columns under
    `author_user_id`;
  - `audit_log` uses `actor_id`, adds `previous_hash` and `record_hash`
    (ADR 0020), and has no `ip_hash` or `user_agent_hash`;
  - `notifications` uses `recipient_user_id` and `notification_type`,
    keeps read state in `notification_reads` instead of `read_at`, and
    `notification_delivery_attempts` does not exist.

## Alignment

- ADR 0051 (database architecture), ADR 0061 (domain model), ADR 0065
  (community operations), ADR 0067 (cache and coordination), ADR 0070
  (permission matrix), ADR 0071 (event catalog), ADR 0074 (privacy and
  data protection), ADR 0093 (verifiable invariants), ADR 0099
  (projection stability).
- ADR 0012 (operational profiles and partition lifecycle), ADR 0020 (audit
  record hashing).
- `migrations/001_core_identity.sql`, `migrations/002_event_audit.sql`,
  `migrations/003_forum_projection.sql`,
  `migrations/005_notifications_subscriptions.sql`,
  `migrations/006_attachments.sql`, `migrations/008_moderation_review.sql`,
  `migrations/009_admin_authorization.sql`
- `lib/GPForum/Schema.pm`, `lib/GPForum/Schema`, `bin/gpforum-migrate`
- `docs/architecture/partition-lifecycle.md`, `docs/DB_PERFORMANCE.md`,
  `docs/QUERY_BUDGET_POLICY.md`
- `t/05-database.t`, `t/10-migrate-command.t`, `t/99-partition-lifecycle.t`,
  `t/integration/postgres.t`
