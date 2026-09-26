# ADR 0091: Executable Architecture Contract

## Status

Accepted. Converted on 2026-09-19 from `prompt/43.txt` ("GPForum -
Executable Architecture Contract"); this ADR replaces the prompt as the
binding source. Its Mandatory Interfaces are amended by ADR 0106 (`permits`)
and ADR 0110, which maps each to the module that implements it.

## Context

The architecture constitutions described intent, but implementation needed
executable contracts. This contract is mandatory for implementation, review,
testing, profiling, deployment, and future AI-assisted code generation. Every
module, migration, workflow, event, permission rule, and milestone MUST be
judged against it.

It governs the bounded contexts Identity, Forum, Authorization, Moderation,
Events, Search, Notifications, Admin, and Audit, and the portability, plugin,
privacy-rights, and public-discovery workflows.

The contract is extended and specialized by later ADRs:

- ADR 0093 (formerly `prompt/45.txt`) extends it: executable architecture
  also requires verifiable invariants, contract tests, classified errors,
  release gates, dependency governance, migration metadata, replay
  validation, and observable operational guarantees.
- ADR 0098 (formerly `prompt/50.txt`) further constrains it: every workflow
  change MUST answer the execution checklist for canonical state, events,
  projections, audit, indexes, permissions, failure modes, rebuildability,
  replayability, and operational scaling.
- ADR 0099 (formerly `prompt/51.txt`) specializes it: hot paths, projection
  consumers, search indexing, cache invalidation, outbox delivery, and
  migrations must preserve explainable query topology, projection stability,
  rebuild safety, and graceful degradation.
- ADR 0100 (formerly `prompt/52.txt`) further specializes it: domain
  workflows must preserve explicit authorization, visibility state,
  moderation state, event and audit traceability, projection safety, cache
  invalidation, anti-leak behavior, and replay-preserving governance
  semantics.
- ADR 0101 (formerly `prompt/53.txt`) further specializes it: retrieval
  workflows must preserve PostgreSQL-native search, derived indexes,
  rebuildable feeds, safe syndication, bounded query topology,
  permission-safe discovery, moderation-aware metadata, cache invalidation,
  and anti-leak behavior.

## Decision

### Contract Purpose

- GPForum MUST evolve from architecture constitution to executable
  contracts.
- Executable means: module boundaries are named; interfaces are explicit;
  database truth is concrete; events have schemas; permissions are testable;
  failure modes are specified; milestones have measurable completion gates;
  product invariants are regression-tested.
- No implementation may rely only on implied architecture.

### Bounded Contexts

- The mandatory bounded contexts are Identity, Forum, Authorization,
  Moderation, Events, Search, Notifications, Admin, and Audit.
- Each bounded context MUST own its domain vocabulary, its application
  services, its persistence access patterns, its events, its tests, and its
  failure behavior.
- Contexts MAY share infrastructure libraries.
- Contexts MUST NOT share hidden mutable workflow state.
- Contexts MUST NOT bypass another context's public service contract.

### Bounded Context Responsibilities

- Identity owns registration, login, logout, password credentials, MFA-ready
  credential records, user sessions, account status, and session revocation.
- Forum owns spaces, categories, threads, posts, post revisions, soft
  deletion, and archival states.
- Authorization owns RBAC, ABAC, permission evaluation, ownership rules, and
  scoped role bindings.
- Moderation owns reports, content hiding, thread locking, thread movement,
  user suspension enforcement, and moderation audit triggers.
- Events owns event append, event schema validation, idempotency keys,
  correlation IDs, and event replay contracts.
- Search owns PostgreSQL-native indexing, permission-aware search filtering,
  rebuild workflows, and search observability.
- Notifications owns notification creation, notification dispatch, read
  state, subscription fanout, and digest-ready records.
- Admin owns staff workflows, emergency controls, scoped operational views,
  and administrative action review.
- Audit owns immutable audit records, security-critical operation trails,
  audit query contracts, and retention coordination.

### Mandatory Interfaces

The following interfaces MUST exist as explicit Perl modules before their
workflows are considered complete. ADR 0110 records where each method lives,
under which name, and which methods left the contract:

- `EventStore`: `append($event)`, `append_once($event, $idempotency_key)`,
  `fetch_by_aggregate($aggregate_type, $aggregate_id)`,
  `fetch_after($cursor)`.
- `CommandHandler`: `validate($command)`, `authorize($command, $actor)`,
  `execute($command)`, `emit_events($result)`.
- `PermissionEngine`: `permits($actor, $action, $resource, $context)` (named
  `can` until ADR 0106, which renamed it because `sub can` overrides
  `UNIVERSAL::can`),
  `explain($actor, $action, $resource, $context)`,
  `roles_for($actor, $scope)`, `policies_for($resource)`.
- `SessionStore`: `create_session($user, $metadata)`,
  `find_active_session($raw_token)`, `revoke_session($raw_token, $reason)`,
  `revoke_all_for_user($user_id, $reason)`, `touch_session($raw_token)`.
- `SearchIndexer`: `index_thread($thread_id)`, `index_post($post_id)`,
  `remove_post($post_id)`, `rebuild($scope)`, `observe_lag()`.
- `NotificationDispatcher`: `create_notification($recipient_id, $type,
  $payload)`, `dispatch_pending($limit)`, `mark_read($notification_id,
  $user_id)`, `suppress_for_policy($notification, $policy)`.
- Implementations MAY add narrower methods.
- Implementations MUST NOT remove these contract methods without an ADR.

Forum commands and reads:

- Forum command workflows MUST be split into preparation and persistence
  boundaries.
- Thread creation MUST use explicit modules equivalent to `ThreadComposer`
  and `ThreadStore`: one validates/normalizes command input and one persists
  thread, first post, body, revision, projection seed, event records, and
  audit records in one transaction.
- Post reply creation MUST use explicit modules equivalent to `PostComposer`
  and `PostStore`: one validates/normalizes reply command input and one
  persists post, body, revision, `thread_counter_shards` delta,
  `post.created` event, and audit records in one transaction.
- Reply creation MUST NOT update canonical thread counters directly on the
  hot write path.
- Forum read workflows MUST use explicit pagination boundaries equivalent to
  `PageWindow`, `ThreadReader`, and `PostReader`.
- Category thread lists MUST use bounded keyset pagination ordered by pinned,
  `last_activity_at`, and `thread_id`.
- Thread post lists MUST use bounded keyset pagination ordered by position
  and `post_id`.
- Readers MUST fetch limit plus one row, return `has_next` and `next_cursor`
  metadata, and MUST NOT scan unbounded thread or post result sets.

Events, outbox, and workers:

- Domain event writes MUST create a matching `outbox_messages` row in the
  same transaction through a narrow builder equivalent to `MessageBuilder`,
  keeping delivery metadata outside `EventStore` and preventing store classes
  from becoming god-class dispatchers.
- Outbox delivery MUST use a narrow `OutboxDispatcher` contract: select ready
  pending/failed rows, claim them with worker and lock metadata, dispatch
  through an injectable transport, mark successful rows done, and mark
  failures failed with retry metadata.
- Outbox delivery MUST use a narrow `DeadLetterRecorder` after bounded
  retries are exhausted. Dead-letter creation MUST preserve failed payload,
  source id, technical error class/message, retry count, and first/last
  failure timestamps.
- Outbox workers MUST dispatch domain events through a narrow
  `DomainEventTransport` with explicit handlers for `SearchIndexing`,
  `NotificationDispatch`, and `CacheInvalidation` placeholders.
- Worker tasks MUST use an `IdempotentJobRunner` boundary and Minion
  registration MUST be isolated in a `MinionRegistrar` module.

Search:

- Search indexing MUST use narrow `DocumentBuilder`, `SearchIndexer`, and
  `Searcher` boundaries.
- `DocumentBuilder` MUST translate visible thread/post rows into rebuildable
  `search_documents` payloads without loading unrelated workflow state.
- `SearchIndexer` MUST upsert thread and post documents, remove
  hidden/deleted post documents, rebuild scoped indexes, and expose
  projection lag.
- `Searcher` MUST apply permission-aware visibility scopes before querying
  and MUST filter results again before rendering.

Notifications and realtime:

- Notification and subscription writes MUST use narrow `SubscriptionStore`,
  `PreferenceStore`, and `NotificationDispatcher` boundaries.
- `NotificationDispatcher` MUST create notifications and inbox projection
  rows together, respect an injectable permission engine at creation time,
  support fanout from active subscriptions, list inbox rows by recipient, and
  persist read state separately.
- Realtime websocket behavior MUST use narrow `ChannelAuthorizer`,
  `ConnectionRegistry`, and `RealtimeHub` boundaries.
- `ChannelAuthorizer` MUST parse and authorize channel subscription
  requests. `ConnectionRegistry` MUST track process-local authenticated
  connections and their channel subscriptions. `RealtimeHub` MUST broadcast
  thread updates and notification badge updates to authorized subscribers
  while exposing explicit polling fallback state.
- Realtime MUST remain optional and MUST NOT become authoritative for core
  forum behavior.

Attachments:

- Attachment workflows MUST use narrow `AttachmentValidator`,
  `AttachmentIntentBuilder`, and `AttachmentStore` boundaries.
- `AttachmentValidator` MUST reject executable uploads, unsupported media
  types, and oversized files.
- `AttachmentIntentBuilder` MUST create upload intents with object storage
  keys without persisting bytes in Perl application state.
- `AttachmentStore` MUST persist attachment lifecycle records,
  `attachment_links`, `attachment_variants`, `event_log`, `audit_log`, and
  `outbox_messages` for scanning and media processing.
- Attachment workers MUST use `AttachmentScanning` and `MediaProcessing`
  handlers.
- Uploads MUST remain non-executable, permission-aware, scan-gated, and
  lifecycle-driven.

Operations hardening:

- Operations hardening MUST use narrow `RateLimiter`, `MetricsSnapshot`,
  `RunbookValidator`, and `RuntimeSizing` boundaries.
- `RateLimiter` MUST provide bounded abuse throttling metadata without using
  canonical business tables as ephemeral counters.
- `MetricsSnapshot` MUST expose runtime, realtime, rate-limit, and
  projection-lag state without secrets.
- `RunbookValidator` MUST reject incomplete backup/restore and rollback
  contracts.
- `RuntimeSizing` MUST validate process pool settings before deployment.

Advanced community features:

- Advanced community features MUST use narrow `MentionExtractor`,
  `BookmarkStore`, `ReputationLedger`, and `FeedProjector` boundaries.
- Mentions MUST be parsed and deduplicated before notification fanout.
- Bookmarks MUST be soft-deletable user state, not content authority. The
  `bookmarks` and `mentions` tables MUST remain user/community state rather
  than canonical content authority.
- Reputation MUST be append-ledger driven through `reputation_events` and
  `trust_score_snapshots`.
- `FeedProjector` MUST write rebuildable `user_feed_items` projections and
  MUST NOT make feeds authoritative.

Moderation review:

- Moderation review MUST use narrow `ReportStore`, `ActionStore`, and
  `AuditReview` boundaries.
- `ReportStore` MUST create, assign, list, and resolve reports without
  embedding moderation action workflow.
- `ActionStore` MUST apply reversible moderation actions to posts and
  threads while creating `moderation_actions` and `audit_log` records.
- `AuditReview` MUST expose read-only admin audit browsing.
- `reports`, `moderation_actions`, and `suspensions` MUST remain explicit
  tables.

Admin authorization management:

- Admin authorization management MUST use narrow `RoleCatalog`,
  `RoleBindingStore`, and `PermissionReview` boundaries.
- `RoleCatalog` MUST manage `roles`, `permissions`, and `role_permissions`
  without evaluating runtime access.
- `RoleBindingStore` MUST create and revoke scoped `role_bindings` while
  writing `audit_log` records.
- `PermissionReview` MUST expose read-only role and permission review paths.
- `roles`, `permissions`, `role_permissions`, `role_bindings`,
  `resource_acl`, and `admin_role_audit_projection` MUST remain explicit
  tables/projections.

### Canonical Minimum Schema

- The canonical minimum database schema MUST include `users`, `sessions`,
  `credentials`, `spaces`, `categories`, `threads`, `posts`, `post_bodies`,
  `post_revisions`, `event_log`, `audit_log`, `roles`, `permissions`,
  `role_permissions`, and `role_bindings`.
- The canonical minimum schema SHOULD include `resource_policies`,
  `notifications`, `notification_preferences`, `attachments`, and `reports`.
- Canonical tables MUST NOT be optimized by reading `event_log` for ordinary
  UI screens.
- Projection tables MUST be separate from canonical tables.
- The minimum projection set SHOULD include `thread_counters`,
  `category_stats`, `search_documents`, `notification_inbox`,
  `user_feed_items`, and `attachment_links`.
- Forum content MUST use a head/body/revision split:
  - `posts` stores metadata, position, current body pointer, current
    revision pointer, visibility, moderation state, and version fields;
  - `post_bodies` stores heavy text and rendered safe body data;
  - `post_revisions` stores append-only revision history.
- Hot content and cold content MUST have an explicit lifecycle. The
  preferred initial implementation is a hot `posts` table plus
  `posts_archive` or equivalent time-based retention partitions.
- Ordinary thread lists MUST read post/thread metadata without loading large
  body text.
- Derived counters such as `reply_count`, `last_post_id`,
  `last_activity_at`, and `thread_count` MUST live in projection tables
  unless an ADR approves a transactional projection column on a canonical
  table.
- Searchable or cacheable resources MUST carry `version`,
  `visibility_version`, and `permission_version` where applicable so
  projections can be invalidated by explicit snapshots instead of fragile
  inference.
- Every canonical table MUST have an explicit primary key, explicit
  constraints, explicit indexes for expected lookup paths, migration
  coverage, and DBIx::Class mapping coverage.
- Destructive deletion MUST NOT be the default for product entities.
- Soft deletion, archival, or append-only state transitions MUST be
  preferred.

### Canonical Event Envelope

- Every durable event MUST include `event_id`, `event_type`,
  `schema_version`, `aggregate_type`, `aggregate_id`, `aggregate_version`,
  `actor_id`, `idempotency_key`, `correlation_id`, `causation_id`,
  `payload`, `metadata`, and `created_at`.
- Events MUST be immutable after insertion.
- Events MUST be versioned from the first version.
- Each aggregate stream MUST have a strong monotonic version guard. On
  PostgreSQL partitioned event tables this MAY be implemented with a
  companion `aggregate_stream_versions` table because global unique
  constraints on partitioned tables must include the partition key.
- Command log and event log MUST remain separate:
  - `command_log` records commands received, idempotency, actor,
    correlation, input payload, response hash, and handling status;
  - `event_log` records durable domain facts produced by accepted commands;
  - `audit_log` records security and governance observations.
- Knowing what was requested MUST NOT be confused with knowing what
  happened.
- Events MUST be safe to inspect without exposing secrets.
- Events MUST NOT contain raw passwords, raw session tokens, API secrets,
  private cryptographic material, or unsanitized user-generated HTML.

### Formal Event Catalog

Every catalog event has `schema_version` 1.

- `user.registered`: aggregate_type `user`; aggregate_id `user_id`;
  actor_id `user_id`; idempotency_key registration request key; payload
  `user_id`, `username`, `email_normalized`.
- `user.login_succeeded`: aggregate_type `user`; aggregate_id `user_id`;
  actor_id `user_id`; idempotency_key `session_id`; payload `user_id`,
  `session_id`.
- `user.login_failed`: aggregate_type `user`; aggregate_id nullable
  `user_id`; actor_id nullable `user_id`; idempotency_key login attempt key;
  payload `identifier_hash`, `reason`.
- `session.revoked`: aggregate_type `session`; aggregate_id `session_id`;
  actor_id `user_id` or `admin_user_id`; idempotency_key revocation key;
  payload `user_id`, `session_id`, `reason`.
- `space.created`: aggregate_type `space`; aggregate_id `space_id`; actor_id
  `user_id`; idempotency_key command id; payload `space_id`, `slug`,
  `title`, `visibility`.
- `category.created`: aggregate_type `category`; aggregate_id
  `category_id`; actor_id `user_id`; idempotency_key command id; payload
  `category_id`, `space_id`, `slug`, `title`, `visibility`.
- `thread.created`: aggregate_type `thread`; aggregate_id `thread_id`;
  actor_id `user_id`; idempotency_key command id; payload `thread_id`,
  `category_id`, `author_user_id`, `title`, `visibility`.
- `post.created`: aggregate_type `post`; aggregate_id `post_id`; actor_id
  `user_id`; idempotency_key command id; payload `post_id`, `thread_id`,
  `author_user_id`, `revision_id`.
- `post.edited`: aggregate_type `post`; aggregate_id `post_id`; actor_id
  `user_id`; idempotency_key command id; payload `post_id`, `revision_id`,
  `edit_reason`.
- `post.hidden`: aggregate_type `post`; aggregate_id `post_id`; actor_id
  `moderator_user_id`; idempotency_key moderation action id; payload
  `post_id`, `reason`, `previous_visibility`.
- `thread.locked`: aggregate_type `thread`; aggregate_id `thread_id`;
  actor_id `moderator_user_id`; idempotency_key moderation action id;
  payload `thread_id`, `reason`.
- `role.assigned`: aggregate_type `role_binding`; aggregate_id
  `role_binding_id`; actor_id `admin_user_id`; idempotency_key role
  assignment command id; payload `user_id`, `role_id`, `scope_type`,
  `scope_id`.
- `notification.created`: aggregate_type `notification`; aggregate_id
  `notification_id`; actor_id nullable `user_id`; idempotency_key
  notification source key; payload `recipient_user_id`, `type`,
  `source_type`, `source_id`.
- `search.index_requested`: aggregate_type `search_document`; aggregate_id
  source resource id; actor_id nullable `user_id`; idempotency_key source
  resource version key; payload `source_type`, `source_id`, `reason`.
- `attachment.uploaded`: aggregate_type `attachment`; aggregate_id
  `attachment_id`; actor_id `owner_user_id`; idempotency_key
  `attachment.uploaded:{attachment_id}`; payload `attachment_id`,
  `byte_size`, `media_type`, `object_key`, `owner_user_id`
  (`Attachment::Event::uploaded_payload` /
  `Attachment::Store`).
- `attachment.deleted`: aggregate_type `attachment`; aggregate_id
  `attachment_id`; actor_id owner or deleting actor; idempotency_key
  `attachment.deleted:{attachment_id}`; payload `attachment_id`,
  `reason` (`Attachment::Event::deleted_payload` /
  `Attachment::Store`).
- `report.assigned`: aggregate_type `report`; aggregate_id `report_id`;
  actor_id `moderator_user_id`; idempotency_key
  `report.assigned:{report_id}:{event_id}`; payload `report_id`,
  `target_id`, `target_type`, `assigned_moderator_user_id`
  (`Moderation::Event::report_transition_envelope` /
  `ReportStore::assign_report`).
- `report.released`: aggregate_type `report`; aggregate_id `report_id`;
  actor_id releasing actor; idempotency_key
  `report.released:{report_id}:{event_id}`; payload `report_id`,
  `target_id`, `target_type`, `assigned_moderator_user_id` (null)
  (`ReportStore::release_report`).
- `report.resolved`: aggregate_type `report`; aggregate_id `report_id`;
  actor_id resolving actor; idempotency_key
  `report.resolved:{report_id}:{event_id}`; payload `report_id`,
  `target_id`, `target_type`, `resolution`, `resolved_at`
  (`ReportStore::resolve_report`).

Catalog rules:

- Thread creation MUST emit `thread.created` and `post.created` with the
  same correlation id. `post.created` MUST be causally linked to
  `thread.created`.
- Reply creation MUST emit `post.created` without `thread.created` and MUST
  write an anti-hot-row `thread_counter_shards` delta instead of
  synchronously mutating a single reply counter row.
- Every new event MUST be added to this catalog before implementation.

### Concrete Permission Model

- Permission evaluation MUST consider actor, action, resource, resource
  state, ownership, scope, account status, and moderation status.
- Baseline roles: `anonymous`, `member`, `moderator`, `admin`, `owner`.
- Baseline actions: `user.register`, `user.login`, `user.logout`,
  `profile.view`, `thread.create`, `thread.view`, `thread.lock`,
  `post.create`, `post.edit`, `post.hide`, `category.view`,
  `category.manage`, `space.manage`, `report.create`, `moderation.review`,
  `admin.access`.
- `anonymous` MAY register, login, and view public spaces, categories,
  threads, posts, and profiles.
- `member` MAY logout, create threads in visible categories when posting
  policy allows, create posts in unlocked visible threads, edit own posts
  while edit policy allows, and report content.
- `member` MUST NOT create posts while suspended, view hidden posts unless
  explicitly authorized, or edit posts after lock/archive/delete conditions
  forbid it.
- `moderator` MAY hide posts, lock threads, move threads, and review reports
  within assigned scope.
- `moderator` MUST NOT act outside assigned scope or grant roles unless also
  admin.
- `admin` MAY manage roles, manage spaces, review global audit views, and
  revoke sessions.
- `owner` MAY perform all admin actions and emergency governance actions.
- Authorization MUST be deny-by-default.
- Every permission rule MUST have tests.

### ADR Requirements

- An ADR is mandatory for any deviation from:
  - PostgreSQL-native authoritative persistence;
  - PostgreSQL-native default search;
  - Perl-first implementation;
  - Redis/KeyDB optional-only acceleration;
  - SSR-first rendering;
  - DBIx::Class persistence mapping;
  - Minion worker model;
  - bounded modular monolith architecture.
- ADR files MUST include context, decision, options considered, operational
  impact, security impact, rollback strategy, test impact, owner, and date.
- No deviation may ship without an accepted ADR.

### Import, Export, And Portability Contract

- Import/export workflows MUST remain narrow service boundaries and MUST NOT
  become application god classes.
- Required portability modules:
  - `ImportManifestValidator` for source-system, adapter, dry-run, and
    record-count validation;
  - `ImportJobStore` for `import_jobs` lifecycle, progress snapshots, and
    `import_failures` recording;
  - `LegacyIdMapper` for `legacy_id_map` source-to-native identifier
    resolution;
  - `ExportBundleBuilder` for `export_requests`, user-data bundles, and safe
    export manifests.
- Required persistence tables: `import_jobs`, `import_failures`,
  `legacy_id_map`, `export_requests`.
- Imports MUST support dry-run execution, hostile input quarantine,
  deterministic failure reporting, legacy id mapping, and asynchronous
  worker execution.
- Exports MUST be privacy-aware, authorization-aware, and explicit about
  their manifest. User data exports MUST NOT include privileged audit log
  rows, moderation internals, credential secrets, or unrelated user data.
- Legacy identifiers MUST never collide with native identifiers. All source
  id resolution MUST pass through `legacy_id_map` or an equivalent reviewed
  mapping projection.

### Plugin Extension Contract

- Plugins are optional extension points and MUST NOT become required for
  core correctness unless promoted into core through ADR and tests.
- Plugin extension workflows MUST use narrow modules:
  - `PluginManifestValidator` for plugin metadata, compatibility,
    capability, permission, and hook contract validation;
  - `PluginRegistry` for `plugins` lifecycle, install/enable/disable state,
    and hook registration;
  - `HookDispatcher` for named `plugin_hooks` execution with explicit
    ordering and failure handling;
  - `PluginFailureRecorder` for `plugin_failures` observability.
- Required persistence tables: `plugins`, `plugin_hooks`,
  `plugin_failures`.
- Plugin hooks MUST define `hook_name`, `callback_name`, `execution_order`,
  `timeout_ms`, `side_effect_policy`, and enabled state.
- Hooks MUST NOT receive secrets unless an explicit permission and ADR allow
  it.
- Plugin failures MUST be visible through logs, metrics, admin review, or
  the `plugin_failures` table. Plugins MUST NOT hide operational errors.
- Plugin-provided HTML, templates, migrations, import adapters, notification
  channels, moderation classifiers, analytics sinks, and admin panels MUST
  obey the same authorization, sanitization, migration, and ADR alignment
  (formerly prompt alignment) gates as core code.

### Privacy Rights Operations Contract

- Privacy and legal workflows MUST remain explicit operational workflows,
  not implicit user-table mutations.
- Account deletion, anonymization, hard-purge, retention, and legal-hold
  workflows MUST use narrow modules:
  - `DeletionWorkflow` for `account_deletion` and `data_rights` requests,
    approval, `erasure_jobs` scheduling, and completion state;
  - `RetentionHoldStore` for `legal_hold` and `retention_holds` creation and
    active hold lookup;
  - `DataRightsReview` for staff review of `deletion_requests` and
    `erasure_jobs`.
- Required persistence tables: `deletion_requests`, `deletion_actions`,
  `erasure_jobs`, `retention_holds`.
- Deletion requests MUST distinguish soft delete, anonymization, and hard
  purge.
- Deletion actions MUST be append-only operational facts.
- Erasure jobs MUST be observable, retryable, and reviewable by status.
- Retention holds MUST prevent privacy automation from pretending that a
  legal or moderation hold does not exist. A held resource MUST require
  explicit staff review before purge or anonymization workflows continue.
- User data exports, `account_deletion`, `data_rights`, consent,
  `legal_hold`, and retention jobs MUST be authenticated, audited,
  rate-limited, and abuse-aware.

### Public Discovery And Syndication Contract

- Public discovery MUST improve discoverability only where policy allows.
  SEO MUST never override privacy, security, moderation state, deletion
  state, or authorization.
- Discovery workflows MUST use narrow `public_discovery` modules:
  - `CanonicalUrl` for `canonical_url` generation and safe legacy
    redirects;
  - `MetadataBuilder` for title, description, canonical link, `noindex`,
    and safe snippets;
  - `RobotsPolicy` for `robots_txt` output and explicit disallow rules;
  - `SitemapBuilder` for `sitemap` entries and XML rendering;
  - `FeedBuilder` for `public_feed` items with safe excerpts;
  - `VisibilityPolicy` for shared public discovery visibility checks.
- Private, hidden, deleted, quarantined, restricted, or moderated content
  MUST NOT appear in metadata descriptions, sitemap entries, public feeds,
  robots-driven discovery hints, snippets, counts, or autocomplete.
- Canonical thread URLs MUST include stable id plus human-readable slug.
  Slug changes MUST NOT break canonical access.
- Legacy redirects MUST preserve old URLs only when the target remains safe
  to expose.
- Search result pages SHOULD be noindex unless explicitly designed for
  public discovery.
- Feeds MUST expose safe excerpts by default and MUST NOT expose full body
  content unless a reviewed policy allows it.

### Milestone Definition Of Done

Every milestone MUST include:

- tests for every new workflow;
- migration files for schema changes;
- `migration_runner` coverage where schema changes are introduced;
- rollback or forward-fix strategy;
- health check impact review;
- audit event review;
- event catalog update where events are introduced;
- permission model update where actions are introduced;
- documentation update;
- profiling command execution;
- coverage command execution;
- Perl::Critic pass;
- migration safety review;
- failure mode review;
- ADR alignment review (formerly prompt alignment review).

Milestones are incomplete if they only add code. Milestones are complete only
when behavior, contracts, tests, documentation, and operations are aligned.

### Failure Model

- Database failure: writes MUST fail closed; state-changing requests MUST
  NOT pretend success; read-only degraded responses MAY be served only if
  correctness is preserved; audit/event writes MUST not be silently dropped.
- Minion failure: authoritative writes MUST remain committed only in
  PostgreSQL; async jobs MUST be retryable; job failure MUST be observable;
  derived projections MUST be rebuildable.
- Outbox failure:
  - canonical write, event append, command idempotency key insert, and
    `outbox_messages` insert MUST be in the same PostgreSQL transaction;
  - consumers MUST tolerate duplicate delivery;
  - pending outbox lag MUST be observable;
  - no workflow may accept "row written but event lost" as a valid state.
- Dead-letter handling MUST preserve failed payload, error class, retry
  count, and first/last failure timestamps.
- Projection failure:
  - `projection_offsets` MUST expose lag and status for search,
    notifications, feed, and counters;
  - projection offset writes MUST use a narrow `OffsetTracker` boundary
    that records last event id, event timestamp, lag seconds, status, and
    update timestamp;
  - `projection_generations` MUST allow blue/green read-model rebuilds;
  - projection generation writes MUST use a narrow `GenerationManager`
    boundary that starts, marks ready/failed, activates, and retires
    generations while keeping only one active generation per projection;
  - feed projections MUST be degradable to slower canonical queries and
    MUST never become authoritative truth.
- Audit integrity failure: `audit_log` SHOULD use a hash chain;
  `audit_checkpoints` SHOULD be exported externally on a fixed cadence;
  missing or invalid checkpoints MUST be treated as an operations incident.
- Platform governance failure:
  - `partition_registry` MUST describe managed partitions before lifecycle
    jobs detach, archive, or drop them;
  - `dead_letters` MUST preserve failed technical deliveries;
  - `endpoint_query_budgets` MUST define query and transaction ceilings for
    hot endpoints before implementation;
  - `database_role_contracts` MUST document least-privilege DB roles;
  - `migration_safety` MUST record lock, reversibility, checksum, and
    rollback hash expectations.
- Migration runner failure: failed migration execution MUST stop the
  deployment path; applied migrations MUST be recorded in `schema_versions`
  with checksums; `migration_safety` MUST be populated once available;
  re-running the migrator MUST skip already-applied versions.
- Email failure: registration MAY remain pending; verification resend MUST
  be safe and rate-limited; password reset MUST fail closed if email cannot
  be queued.
- Search indexing failure: canonical writes MUST succeed without requiring
  search; indexing lag MUST be observable; search results MAY be stale but
  MUST remain permission-filtered; rebuild MUST be possible from canonical
  data.
- Cache invalidation failure: caches MUST be disposable; stale cache MUST
  NOT grant permissions; cache loss MUST degrade performance, not
  correctness.
- Websocket failure: core forum usability MUST continue through SSR and
  ordinary HTTP; reconnect behavior MUST be safe; missed realtime
  notifications MUST be recoverable from canonical reads.
- Migration failure: failed migrations MUST leave a detectable state;
  partial schema mutation MUST have a recovery plan; destructive migration
  failure MUST require explicit operator intervention; zero-downtime
  compatibility MUST be reviewed before production deploys.

### Upgrade And Migration Discipline

- Schema changes MUST be compatible with rolling deployment where
  production requires it.
- Mandatory sequence for risky changes:
  1. expand schema;
  2. deploy code compatible with old and new schema;
  3. backfill;
  4. verify;
  5. switch reads/writes;
  6. contract old schema;
  7. document rollback or forward-fix.
- Backfills MUST be resumable, observable, bounded, and safe under
  concurrent writes.
- Partition changes MUST include growth estimate, retention behavior, index
  strategy, and maintenance procedure.
- Rollback MUST NOT rely on deleting authoritative user data.
- Forward-fix MUST be preferred when rollback would destroy valid writes.

### Product Invariants

The following invariants MUST be permanently tested:

- a hidden post never appears in ordinary thread rendering;
- a hidden post never appears in search results for unauthorized users;
- a suspended user cannot publish posts;
- a revoked session never authenticates again;
- an expired session never authenticates again;
- a deleted user profile exposes only public-safe tombstone data;
- an audit event is never modified after creation;
- a durable event is never modified after creation;
- raw passwords are never persisted;
- raw session tokens are never persisted;
- authorization failures do not emit successful workflow events;
- search indexing never becomes authoritative;
- notification creation respects permissions at creation and render time;
- moderator actions are scoped;
- admin actions are audited;
- CSRF-protected POST routes reject missing or invalid CSRF tokens.

Every invariant MUST have at least one automated regression test before the
related workflow is considered production-ready.

### Executable Review Checklist

Every pull request MUST answer:

- Which bounded context owns this change?
- Which contract interface is touched?
- Which canonical tables are touched?
- Which events are emitted?
- Which permissions are evaluated?
- Which product invariants are affected?
- Which failure modes are changed?
- Which migrations are required?
- Which rollback or forward-fix path exists?
- Which tests prove the behavior?
- Which profiling and coverage commands were run?

If these answers are unclear, the change is not ready.

### Final Rule

Architecture is not complete until it is executable. For GPForum, executable
means named bounded contexts, explicit interfaces, canonical schema, formal
event catalog, concrete permission rules, mandatory ADRs, milestone
Definition of Done, failure model, upgrade discipline, and tested product
invariants. This contract is mandatory.

## Consequences

- Reviews, tests, and AI-assisted generation share one concrete checklist:
  named modules, tables, events, permissions, and failure modes instead of
  implied architecture.
- Narrow boundaries (composer/store, reader/pagination, outbox builder,
  dispatcher, dead-letter recorder, projection trackers) keep workflows out
  of god-class services and make each boundary testable in isolation.
- The command log, event log, audit log, and outbox split costs extra writes
  per command but makes idempotent retry, replay, and forensic review
  possible.
- Every new event, action, or schema change carries catalog, permission
  model, migration, and documentation work; milestones that only add code
  are incomplete.
- Failure behavior is specified per dependency, so operators can predict
  degraded modes for database, Minion, outbox, projection, search, cache,
  websocket, email, and migration failures.
- Open conflicts:
  - The repository has no `EventStore` or `CommandHandler` module; events
    and audit rows are written through `GPForum::Infrastructure::EventRecorder`
    (`record_event`, `record_audit`) and per-context `*::Event` modules.
    Existing modules also diverge from the named contract methods:
    `Identity::SessionStore` has `create_session`, `revoke_session`,
    `validate_session`, and `revoke_user_sessions` but no
    `find_active_session`, `revoke_all_for_user`, or `touch_session`;
    `Search::PermissionEngine` has `can` but no `explain`, `roles_for`, or
    `policies_for`; `Notification::Dispatcher` has no `dispatch_pending` or
    `suppress_for_policy`. Either the code gains these contracts or an ADR
    records the removal, as this contract requires.
  - Formal Event Catalog catch-up (2026-09-20): `attachment.uploaded`,
    `attachment.deleted`, `report.assigned`, `report.released`, and
    `report.resolved` are now cataloged here and in `EVENTS.md` from the
    emitting store/`*::Event` payloads. Residual catalog drift elsewhere
    (for example naming differences called out in ADR 0071) is unchanged.
  - ADR files MUST include options considered, operational impact, security
    impact, rollback strategy, test impact, owner, and date, but
    `docs/adr/0000-template.md` and the existing ADRs (including the
    converted ones) only carry Status, Context, Decision, Consequences, and
    Alignment.

## Alignment

- Extended or specialized by ADR 0093, ADR 0098, ADR 0099, ADR 0100, and
  ADR 0101.
- Related converted ADRs: ADR 0051 (database), ADR 0055 (events and
  realtime), ADR 0056 (workers), ADR 0057 (authorization and moderation),
  ADR 0061 (domain model), ADR 0062 (search), ADR 0069 (initial schema),
  ADR 0070 (permission matrix), ADR 0071 (event catalog), ADR 0074
  (privacy), ADR 0081 (import/export), ADR 0082 (SEO and discovery),
  ADR 0083 (plugins), ADR 0087 (ADR governance), ADR 0092, ADR 0096.
- Existing ADRs: 0005, 0007, 0008, 0009, 0010, 0011, 0012, 0013, 0014,
  0015, 0020, 0025, 0027, 0030.
- Code:
  - `lib/GPForum/Service/Forum/` (`ThreadComposer`, `ThreadStore`,
    `PostComposer`, `PostStore`, `PageWindow`, `ThreadReader`,
    `PostReader`);
  - `lib/GPForum/Service/Outbox/` (`MessageBuilder`, `Dispatcher`,
    `DeadLetterRecorder`, `DomainEventTransport`);
  - `lib/GPForum/Worker/` (`IdempotentJobRunner`, `MinionRegistrar`,
    `Handler/SearchIndexing`, `Handler/NotificationDispatch`,
    `Handler/CacheInvalidation`, `Handler/AttachmentScanning`,
    `Handler/MediaProcessing`);
  - `lib/GPForum/Service/Projection/` (`OffsetTracker`,
    `GenerationManager`);
  - `lib/GPForum/Service/Search/` (`DocumentBuilder`, `Indexer`,
    `Searcher`, `PermissionEngine`);
  - `lib/GPForum/Service/Notification/` and
    `lib/GPForum/Service/Realtime/` (`ChannelAuthorizer`,
    `ConnectionRegistry`, `Hub`);
  - `lib/GPForum/Service/Attachment/`, `lib/GPForum/Service/Operations/`,
    `lib/GPForum/Service/Community/`, `lib/GPForum/Service/Moderation/`,
    `lib/GPForum/Service/Admin/`, `lib/GPForum/Service/Portability/`,
    `lib/GPForum/Service/Plugin/`, `lib/GPForum/Service/Privacy/`,
    `lib/GPForum/Service/Discovery/`;
  - `lib/GPForum/Service/Identity/SessionStore.pm`,
    `lib/GPForum/Infrastructure/EventRecorder.pm`,
    `lib/GPForum/Domain/EventEnvelope.pm`,
    `lib/GPForum/Migration/Runner.pm`, `migrations/`.
- Tests: `t/05-database.t`, `t/10-migrate-command.t`, `t/11-forum-thread.t`
  through `t/30-public-discovery.t`, `t/75-architecture-foundation.t`,
  `t/86-engineering-correctness.t`, `t/87-command-idempotency.t`,
  `t/integration/postgres.t`, `t/09-prompt-alignment.t`.
- Docs: `ARCHITECTURE.md`, `EVENTS.md`, `GOVERNANCE.md`, `ROADMAP.md`,
  `docs/OUTBOX_LIFECYCLE.md`, `docs/QUERY_BUDGET_POLICY.md`,
  `docs/audit/failure-modes.md`, `docs/architecture/partition-lifecycle.md`.
- Scripts: `script/test`, `script/coverage`, `script/perlcritic`,
  `script/profile`, `bin/gpforum-migrate`.
