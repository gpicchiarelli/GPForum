# ADR 0033: Retention Hold Event And Audit Hashes

## Status

Accepted.

## Context

`Privacy::RetentionHoldStore` still mixed `privacy.retention_hold_created`
EventLog envelopes and AuditLog argument hashes with RetentionHold inserts
after ADR 0032 extracted deletion-workflow event hashes. Those contracts
needed unit coverage without schema or `Crypt::URandom`.

## Decision

Extend `GPForum::Service::Privacy::Event` with:

- `hold_payload`;
- `hold_envelope`;
- `hold_audit`.

`RetentionHoldStore` still opens the transaction, inserts the hold, and
persists through `EventRecorder`. Public signatures stay unchanged, including
four-argument `active_holds_for`. `id_service` is required lazily unless
injected. Row listing uses `Privacy::Record`.

## Consequences

Created-hold envelopes and audit metadata are unit-testable with plain hashes.
`Privacy::Workflow` keeps calling the hold store.

## Alternatives Rejected

- A separate `Privacy::HoldEvent` module: rejected because hold events are
  the same privacy EventLog/AuditLog context as deletion events.
- Fold hold envelopes into deletion `envelope`: rejected because hold rows
  are not deletion requests.

## Alignment

- `docs/adr/0032-privacy-event.md`
- `docs/architecture/privacy-workflow.md`
- `EVENTS.md`
- `t/128-privacy-event.t`
- `t/29-privacy-rights.t`
