# ADR 0037: Moderation Suspension Event And Audit Hashes

## Status

Accepted.

## Context

`Moderation::SuspensionStore` still mixed suspend and revoke EventLog
envelopes and AuditLog hashes with Suspension row writes after ADR 0036
extracted report hashes. Those contracts needed unit coverage without schema
or `Crypt::URandom`.

## Decision

Extend `GPForum::Service::Moderation::Event` with:

- `suspension_envelope`;
- `suspension_audit`.

`SuspensionStore` still opens the transaction, updates user status, inserts
or revokes Suspension rows, and persists through `EventRecorder`. Public
signatures stay unchanged, including four-argument `revoke_suspension`.
Missing `correlation_id` is still allocated in the store.

## Consequences

Suspend and revoke EventLog/AuditLog hashes are unit-testable with plain
hashes. `Moderation::Workflow` keeps calling the store. Moderation EventLog
shape now lives in one module.

## Alternatives Rejected

- A separate `Moderation::SuspensionEvent` module: rejected because
  suspension events are the same moderation EventLog/AuditLog context.
- Allocate correlation ids inside Event: rejected because uuid allocation
  stays on the store.

## Alignment

- `docs/adr/0036-moderation-report-event.md`
- `docs/architecture/moderation-workflow.md`
- `EVENTS.md`
- `t/130-moderation-event.t`
