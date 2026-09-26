# ADR 0027: Attachment Upload, Scan, and Delete Lifecycle

## Status

Accepted.

## Context

`Attachment::Store` still mixed upload replay, scan state transitions, and
delete replay hashes with resultset writes and event/audit persistence after
ADR 0022 extracted row accessors and download authorization. Those state
decisions needed unit coverage without schema or `Crypt::URandom`.

## Decision

Introduce `GPForum::Service::Attachment::Lifecycle` behind the existing store
facade. It owns:

- intent-versus-uploaded replay;
- clean-versus-quarantined scan columns;
- deleted replay hashes.

`Attachment::Store` still finds rows, updates them, and cleans orphans.
Orphan search, actor/reason fallbacks, and the cleanup result hash later
moved onto this module in `docs/adr/0040-attachment-orphan-cleanup.md`.
Event and audit hashes live in `Attachment::Event`. The store still writes
EventLog, OutboxMessage, and AuditLog.

## Consequences

Scan and delete idempotency are unit-testable with plain hashes and a fixed
clock. Public store methods stay unchanged.

## Alternatives Rejected

- Fold scan state into `DownloadAccess`: rejected because downloadability is a
  read grant, not a lifecycle transition.
- Keep replay hashes in `Attachment::Record`: rejected because Record is an
  accessor, not a state machine.

## Alignment

- `docs/adr/0022-attachment-download-access.md`
- `docs/architecture/attachment-workflow.md`
- `t/22-attachments.t`
- `t/123-attachment-lifecycle.t`
- `docs/adr/0031-attachment-event.md`
- `docs/adr/0040-attachment-orphan-cleanup.md`
