# ADR 0071: Event Catalog And Workflow Contracts

## Status

Accepted. Converted on 2026-09-19 from `prompt/23.txt` ("GPForum - Event
Catalog & Workflow Contracts Constitution"); this ADR replaces the prompt
as the binding source.

## Context

Durable domain events in PostgreSQL drive projections, search indexing,
notifications, realtime, cache invalidation, and audit (ADR 0055,
ADR 0067). This ADR defines the canonical domain event catalog, event
payload expectations, producers, consumers, idempotency rules, and workflow
contracts. It is mandatory for event-driven implementation and governs the
identity, forum, moderation, notification, and attachment bounded contexts
plus every asynchronous consumer.

## Decision

### Cross-ADR Alignment

- ADR 0093: event and workflow contracts MUST be verifiable. Event
  payloads, command semantics, idempotency keys, aggregate lineage, outbox
  effects, and replay expectations MUST have tests or explicit
  verification plans.
- ADR 0100: domain-significant workflows MUST emit immutable, replayable
  events and preserve authorization, visibility, moderation, audit,
  projection, cache invalidation, anti-leak, and governance semantics.

### Event Philosophy

- Events describe facts that already happened.
- Events MUST be immutable, timestamped, attributable where applicable,
  correlation-aware, replay-friendly, and safe for asynchronous consumers.
- Events MUST NOT contain unnecessary sensitive data.

### Event Envelope

- Every domain event MUST include: `event_id`; `event_name`;
  `aggregate_type`; `aggregate_id`; `actor_user_id` when applicable;
  `occurred_at`; `correlation_id`; `idempotency_key` where applicable;
  `schema_version`; `payload`.
- Consumers MUST ignore unknown payload fields.
- Breaking changes MUST use a new schema version.

### Identity Events

- `user.registered`
  - producer: registration workflow
  - consumers: audit, notification, analytics
  - payload: `user_id`, `username`
- `user.logged_in`
  - producer: login workflow
  - consumers: audit, security analytics
  - payload: `user_id`, `session_id`
- `session.revoked`
  - producer: logout, security workflow, admin workflow
  - consumers: realtime, audit
  - payload: `user_id`, `session_id`, `reason`
- `user.suspended`
  - producer: moderation workflow
  - consumers: auth cache invalidation, notification, audit
  - payload: `user_id`, `suspension_id`, `starts_at`, `ends_at`
- `user.banned`
  - producer: moderation workflow
  - consumers: auth cache invalidation, session revocation, audit
  - payload: `user_id`, `reason_code`

### Forum Events

- `space.created`
  - producer: admin workflow
  - consumers: navigation projection, audit
  - payload: `space_id`
- `category.created`
  - producer: admin workflow
  - consumers: navigation projection, search projection, audit
  - payload: `category_id`, `space_id`
- `thread.created`
  - producer: thread creation workflow
  - consumers: feed projection, search indexing, notification fanout,
    realtime
  - payload: `thread_id`, `category_id`, `author_user_id`
- `thread.locked`
  - producer: moderation workflow
  - consumers: auth/cache invalidation, realtime, audit
  - payload: `thread_id`, `actor_user_id`, `reason`
- `thread.moved`
  - producer: moderation workflow
  - consumers: feed projection, search indexing, cache invalidation, audit
  - payload: `thread_id`, `from_category_id`, `to_category_id`
- `post.created`
  - producer: reply workflow
  - consumers: thread counters, feed projection, search indexing,
    notification fanout, realtime
  - payload: `post_id`, `thread_id`, `author_user_id`
- `post.edited`
  - producer: edit workflow
  - consumers: search indexing, cache invalidation, audit
  - payload: `post_id`, `revision_id`, `editor_user_id`
- `post.hidden`
  - producer: moderation workflow
  - consumers: search deindex/update, cache invalidation, realtime, audit
  - payload: `post_id`, `actor_user_id`, `reason`
- `post.restored`
  - producer: moderation workflow
  - consumers: search reindex, cache invalidation, realtime, audit
  - payload: `post_id`, `actor_user_id`

### Moderation Events

- `report.created`
  - producer: reporting workflow (`Moderation::ReportStore` /
    `Moderation::Event`)
  - consumers: moderation queue, notification, audit
  - payload: `reason`, `report_id`, `target_id`, `target_type`
- `report.assigned`
  - producer: moderation workflow (`ReportStore::assign_report`)
  - consumers: moderation queue, notification, audit
  - payload: `report_id`, `target_id`, `target_type`,
    `assigned_moderator_user_id`
- `report.released`
  - producer: moderation workflow (`ReportStore::release_report`)
  - consumers: moderation queue, notification, audit
  - payload: `report_id`, `target_id`, `target_type`,
    `assigned_moderator_user_id` (null)
- `report.resolved`
  - producer: moderation workflow (`ReportStore::resolve_report`)
  - consumers: notification, audit, analytics
  - payload: `report_id`, `target_id`, `target_type`, `resolution`,
    `resolved_at`
- `moderation.action.created`
  - producer: moderation workflow
  - consumers: audit, notification, projections
  - payload: `moderation_action_id`, `action_type`, `target_type`,
    `target_id`
- `moderation.action.reversed`
  - producer: moderation workflow
  - consumers: audit, cache invalidation, projections
  - payload: `moderation_action_id`, `reversed_by_user_id`

### Notification Events

- `notification.created`
  - producer: notification workflow
  - consumers: realtime, delivery workers
  - payload: `notification_id`, `user_id`, `type`
- `notification.read`
  - producer: user workflow
  - consumers: realtime, analytics
  - payload: `notification_id`, `user_id`
- `digest.generated`
  - producer: digest worker
  - consumers: email worker, audit
  - payload: `digest_id`, `user_id`

### Attachment Events

- `attachment.uploaded`
  - producer: upload workflow (`Attachment::Store` /
    `Attachment::Event`)
  - consumers: scanning worker, media processing worker, audit
  - payload: `attachment_id`, `byte_size`, `media_type`, `object_key`,
    `owner_user_id`
- `attachment.deleted`
  - producer: attachment lifecycle (`Attachment::Store` /
    `Attachment::Event`)
  - consumers: audit, cache invalidation, storage cleanup workers
  - payload: `attachment_id`, `reason`
- `attachment.scanned`
  - producer: scanning worker
  - consumers: moderation, attachment projection
  - payload: `attachment_id`, `reason`, `scan_status`
- `attachment.quarantined`
  - producer: scanning or moderation workflow
  - consumers: notification, audit, cache invalidation
  - payload: `attachment_id`, `reason`, `scan_status`

### Idempotency

- Consumers MUST be idempotent.
- Each consumer SHOULD record: `event_id`; `consumer_name`;
  `processed_at`; `result`; error if failed.
- Retries MUST NOT duplicate user-visible side effects.

### Replay

- Events MUST support replay for: search rebuild; feed projection rebuild;
  notification diagnostics; audit investigation; cache warming.
- Replay MUST NOT resend external notifications unless explicitly
  requested.

## Consequences

- Producers and consumers share one catalog, so adding a consumer does not
  change the producer, and projections can be rebuilt by replay.
- Idempotent consumers and per-consumer processing records make retries
  and replays safe but add storage and bookkeeping per consumer.
- Payloads carry identifiers, not content; consumers re-read authoritative
  state from PostgreSQL (ADR 0067), which keeps sensitive data out of the
  event stream.
- Open conflict: the envelope names here (`event_name`, `actor_user_id`,
  `occurred_at`) differ from the `event_log` blueprint in ADR 0069 and from
  `GPForum::Domain::EventEnvelope` and `EVENTS.md` (`event_type`,
  `actor_id`, `created_at`, plus `causation_id`, `aggregate_version`, and
  `metadata`). One naming must be declared canonical.
- Open conflict: several emitted names differ from the catalog, for example
  `moderation_action.reversed` instead of `moderation.action.reversed`,
  `identity.login.requested` instead of `user.logged_in`, and moderation
  actions recorded under their action type (such as `post.hidden`) without
  a `moderation.action.created` event.
- Open conflict: there is no per-consumer processing record with
  `consumer_name` and `processed_at`; idempotency is currently carried by
  `event_idempotency_keys`, `outbox_messages.idempotency_key`,
  `projection_offsets`, and `dead_letters`.
- Open conflict: `t/09-prompt-alignment.t` slurps `prompt/23.txt` to check
  the ADR 0100 alignment clause; it must be repointed to this ADR before
  the prompt files are deleted.

## Alignment

- ADR 0055 (event-driven realtime), ADR 0056 (workers and queues),
  ADR 0065 (community operations), ADR 0067 (cache and coordination),
  ADR 0069 (schema), ADR 0070 (permission matrix), ADR 0078 (notification
  delivery), ADR 0085 (API and websocket schemas), ADR 0093 (verifiable
  invariants), ADR 0099 (projection stability), ADR 0100 (domain
  integrity).
- ADR 0008 (versioned realtime event contracts), ADR 0009 and ADR 0025
  (outbox retry and claim), ADR 0031 to ADR 0039 (event and audit hashes
  per context).
- `EVENTS.md`, `docs/OUTBOX_LIFECYCLE.md`
- `lib/GPForum/Domain/EventEnvelope.pm`,
  `lib/GPForum/Infrastructure/EventRecorder.pm`,
  `lib/GPForum/Service/Moderation/Event.pm`,
  `lib/GPForum/Service/Identity/Event.pm`,
  `lib/GPForum/Service/Admin/Event.pm`
- `migrations/002_event_audit.sql`,
  `migrations/004_platform_governance.sql`
- `t/13-outbox-dispatcher.t`, `t/121-outbox-boundaries.t`,
  `t/127-attachment-event.t`, `t/128-privacy-event.t`,
  `t/129-identity-event.t`, `t/130-moderation-event.t`,
  `t/131-admin-event.t`, `t/87-command-idempotency.t`,
  `t/09-prompt-alignment.t`
