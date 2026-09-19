# ADR 0031: Attachment Event And Audit Hashes

## Status

Accepted.

## Context

`Attachment::Store` still mixed EventLog envelopes, scan event-type
selection, payload hashes, and AuditLog argument hashes with resultset writes
after ADR 0027 extracted lifecycle replay. Those hashes needed unit coverage
without schema or `Crypt::URandom`.

## Decision

Introduce `GPForum::Service::Attachment::Event` behind the existing store
facade. It owns:

- attachment EventLog envelopes and idempotency keys;
- scanned-versus-quarantined event types;
- uploaded, scan, and deleted payloads;
- AuditLog argument hashes.

`Attachment::Store` still creates rows and persists EventLog, OutboxMessage,
and AuditLog through `EventRecorder`. `id_service` is required lazily unless
injected.

## Consequences

Envelope and audit hashes are unit-testable with `Test::Id`. Public store
methods stay unchanged.

## Alternatives Rejected

- Fold envelopes into `Attachment::Lifecycle`: rejected because lifecycle
  owns state transitions, not EventLog shape.
- Build hashes inside `EventRecorder`: rejected because the recorder is
  persistence, not attachment payload ownership.

## Alignment

- `docs/adr/0027-attachment-lifecycle.md`
- `docs/architecture/attachment-workflow.md`
- `EVENTS.md`
- `t/22-attachments.t`
- `t/127-attachment-event.t`
