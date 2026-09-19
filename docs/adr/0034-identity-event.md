# ADR 0034: Identity Event And Audit Hashes

## Status

Accepted.

## Context

`Identity::Audit` still mixed `user.registered` EventLog envelopes, registration
AuditLog hashes, and generic identity audit arguments with recorder writes.
Those contracts needed unit coverage without schema or `Crypt::URandom`.
Longevity review item 5 asked remaining write paths to own event/audit hashes
outside persistence.

## Decision

Introduce `GPForum::Service::Identity::Event` behind the existing audit
facade. It owns:

- registration EventLog envelopes and idempotency keys;
- registration AuditLog hashes;
- typed identity `record_action` argument hashes.

`Identity::Audit` still persists EventLog, OutboxMessage, and AuditLog through
`EventRecorder`. Public `record_registration` and `record_action` stay
unchanged. `id_service` is required lazily unless injected.

## Consequences

Registration envelopes and identity audit arguments are unit-testable with
plain hashes. `RegistrationStore` and `AccountStore` keep calling the audit
facade.

## Alternatives Rejected

- Fold hashes into `Identity::Support`: rejected because Support is a row
  accessor, not EventLog shape.
- Keep hashes in `Identity::Audit`: rejected because Audit is persistence.
- Move HTTP login/logout persistence here: rejected because those remain on
  `Identity::SecurityAudit`. Login/logout AuditLog hashes later moved here in
  `docs/adr/0039-identity-login-logout-event.md`.

## Alignment

- `docs/adr/0014-identity-workflow-boundary.md`
- `docs/architecture/identity-workflow.md`
- `EVENTS.md`
- `t/08-identity-store.t`
- `t/129-identity-event.t`
- `docs/adr/0039-identity-login-logout-event.md`
