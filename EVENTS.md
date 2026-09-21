# Event Contracts

GPForum stores durable domain events in `event_log` and delivery work in
`outbox_messages`.

## Standard Envelope

`GPForum::Domain::EventEnvelope` defines the canonical event shape.

Required event record fields:

- `event_id`
- `event_type`
- `schema_version`
- `aggregate_type`
- `aggregate_id` when the event has a concrete aggregate
- `aggregate_version`
- `actor_id`
- `correlation_id`
- `causation_id`
- `idempotency_key`
- `payload`
- `metadata`
- `created_at`

Transport payloads keep legacy worker compatibility:

- top-level `event_type`, `aggregate_type`, `aggregate_id`, `actor_id`;
- top-level `domain_payload`;
- structured `aggregate`, `actor`, `metadata`, and `transport`;
- `contract => gpforum.domain_event`;
- `contract_version => 1`.

## Transport Readiness

The envelope includes transport metadata for:

- Minion: `domain_event.dispatch`;
- PostgreSQL LISTEN/NOTIFY: `gpforum_domain_events`;
- future stream topics: `gpforum.domain_events`;
- future NATS/Kafka partitioning by aggregate id.

Realtime transport now uses a separate public websocket envelope through
`GPForum::Service::Realtime::EventEnvelope`. Domain transport payloads remain
the worker contract; realtime payloads are derived, bounded JSON messages for
fanout only.

## Recording Boundary

`GPForum::Infrastructure::EventRecorder` records:

- the event log row;
- the corresponding outbox message;
- related audit rows when requested.

Canonical audit hashing and verification live in
`GPForum::Infrastructure::AuditRecord`. The recorder still looks up
`previous_hash` and persists the AuditLog row.

Adopted write paths:

- forum thread creation;
- forum post creation;
- forum post revision (`post.updated`);
- forum post author delete (`post.deleted`);
- forum post author restore (`post.undeleted`);
- forum thread title revision (`thread.updated`);
- forum thread author delete (`thread.deleted`);
- forum thread author restore (`thread.undeleted`);
- forum thread category move (`thread.moved`);
- moderation report lifecycle (`Moderation::Event` owns created, duplicate,
  and transition hashes; `ReportStore` persists them);
- moderation action lifecycle (`Moderation::Event` owns created-action and
  reversal hashes; `ActionStore` persists them);
- moderation suspension lifecycle (`Moderation::Event` owns suspend and revoke
  hashes; `SuspensionStore` persists them);
- privacy deletion workflow (`Privacy::Event` owns request, approval, hold,
  block, and completion hashes; the deletion workflow persists them);
- privacy retention holds (`Privacy::Event` owns created-hold envelopes and
  audit hashes; `RetentionHoldStore` persists them);
- privacy export request lifecycle;
- attachment upload, scan, quarantine, and deletion lifecycle
  (`Attachment::Event` owns envelopes and audit hashes; the store persists
  them);
- admin role catalog and role binding audit lifecycle (`Admin::Event` owns
  audit hashes; `RoleCatalog` and `RoleBindingStore` persist them);
- identity registration events and identity security audits
  (`Identity::Event` owns `user.registered` envelopes, typed identity audit
  hashes, and login/logout request hashes; `Identity::Audit` and
  `Identity::SecurityAudit` persist them);
- rate-limit block audits;
- mention fanout-limit audits.

The service layer no longer writes `EventLog`, `OutboxMessage`, or `AuditLog`
rows directly; those writes route through the infrastructure recorder.

## Cataloged Domain Events (emitted)

Payload fields below match the emitting store/`*::Event` modules. Envelope
fields follow `GPForum::Domain::EventEnvelope` (`schema_version` 1 unless
noted). The formal ADR catalog also lives in
[ADR 0091](docs/adr/0091-executable-architecture-contract.md) and
[ADR 0071](docs/adr/0071-event-catalog-workflow-contracts.md).

### Attachment

- `attachment.uploaded`
  - producer: `GPForum::Service::Attachment::Store` via
    `Attachment::Event`
  - aggregate_type: `attachment`; aggregate_id: `attachment_id`
  - idempotency_key: `attachment.uploaded:{attachment_id}`
  - payload: `attachment_id`, `byte_size`, `media_type`, `object_key`,
    `owner_user_id`
- `attachment.deleted`
  - producer: `GPForum::Service::Attachment::Store` via
    `Attachment::Event`
  - aggregate_type: `attachment`; aggregate_id: `attachment_id`
  - idempotency_key: `attachment.deleted:{attachment_id}`
  - payload: `attachment_id`, `reason`
- `attachment.scanned` / `attachment.quarantined`
  - producer: scan path in `Attachment::Store` via
    `Attachment::Event::scan_event_type`
  - payload: `attachment_id`, `reason`, `scan_status`

### Moderation reports

- `report.created`
  - producer: `GPForum::Service::Moderation::ReportStore` via
    `Moderation::Event::report_created_envelope`
  - aggregate_type: `report`; aggregate_id: `report_id`
  - idempotency_key: `report.created:{report_id}`
  - payload: `reason`, `report_id`, `target_id`, `target_type`
- `report.assigned`
  - producer: `ReportStore::assign_report` via
    `Moderation::Event::report_transition_envelope`
  - aggregate_type: `report`; aggregate_id: `report_id`
  - idempotency_key: `report.assigned:{report_id}:{event_id}`
  - payload: `report_id`, `target_id`, `target_type`,
    `assigned_moderator_user_id`
- `report.released`
  - producer: `ReportStore::release_report` via
    `report_transition_envelope`
  - aggregate_type: `report`; aggregate_id: `report_id`
  - idempotency_key: `report.released:{report_id}:{event_id}`
  - payload: `report_id`, `target_id`, `target_type`,
    `assigned_moderator_user_id` (set to undef / null on release)
- `report.resolved`
  - producer: `ReportStore::resolve_report` via
    `report_transition_envelope`
  - aggregate_type: `report`; aggregate_id: `report_id`
  - idempotency_key: `report.resolved:{report_id}:{event_id}`
  - payload: `report_id`, `target_id`, `target_type`, `resolution`,
    `resolved_at`

## Realtime Propagation

`GPForum::Service::Outbox::DomainEventTransport` can map domain events to
realtime events and publish them through PostgreSQL `NOTIFY`.

Current mappings:

- `post.created` -> `thread.update`;
- `post.updated` -> `thread.update`;
- `post.deleted` -> `thread.update`;
- `post.undeleted` -> `thread.update`;
- `thread.created` -> `thread.update`;
- `thread.updated` -> `thread.update`;
- `thread.deleted` -> `thread.update`;
- `thread.undeleted` -> `thread.update`;
- `thread.moved` -> `thread.update`;
- `thread.hidden` -> `thread.update`;
- `thread.restored` -> `thread.update`;
- `moderation.*` -> `moderation.queue.invalidate`.

Notification badge updates still use the notification dispatcher and local hub
path, with the same versioned realtime envelope shape.
