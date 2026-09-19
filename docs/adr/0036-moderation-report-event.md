# ADR 0036: Moderation Report Event And Audit Hashes

## Status

Accepted.

## Context

`Moderation::ReportStore` still mixed created-report, duplicate-blocked, and
assign/release/resolve EventLog/AuditLog hashes with Report row writes after
ADR 0035 extracted action hashes. Those contracts needed unit coverage without
schema or `Crypt::URandom`.

## Decision

Extend `GPForum::Service::Moderation::Event` with:

- created-report payloads, envelopes, and audit hashes;
- duplicate-blocked audit hashes;
- transition envelopes and audit hashes, including allocated `event_id`.

`ReportStore` still opens the transaction, inserts and updates reports, and
persists through `EventRecorder`. Public signatures stay unchanged, including
four-argument `resolve_report`. Suspension hashes now live on
`Moderation::Event` (ADR 0037).

## Consequences

Report EventLog/AuditLog hashes are unit-testable with plain hashes.
`Moderation::Workflow` keeps calling the store.

## Alternatives Rejected

- A separate `Moderation::ReportEvent` module: rejected because report events
  are the same moderation EventLog/AuditLog context as actions.
- Fold transition `event_id` allocation into Event: rejected because uuid
  allocation stays on the store.

## Alignment

- `docs/adr/0035-moderation-action-event.md`
- `docs/architecture/moderation-workflow.md`
- `EVENTS.md`
- `t/130-moderation-event.t`
- `docs/adr/0037-moderation-suspension-event.md`
