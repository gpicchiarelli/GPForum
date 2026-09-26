# ADR 0039: Identity Login And Logout Audit Hashes

## Status

Accepted.

## Context

ADR 0034 extracted registration envelopes and typed identity audit arguments
onto `Identity::Event`, but left HTTP login/logout AuditLog hashes on
`Identity::SecurityAudit`. Those hashes still mixed SHA-256 identifier and
request-address metadata with `EventRecorder` writes, so the hashing contract
needed unit coverage without schema or `Crypt::URandom`.

## Decision

Extend `GPForum::Service::Identity::Event` with:

- `identity.login.requested` AuditLog hashes, including hashed identifier and
  request address plus default `accepted` outcome;
- `identity.logout.requested` AuditLog hashes, including hashed request
  address.

`Identity::SecurityAudit` still timestamps the request and persists AuditLog
through `EventRecorder`. Public `record_login_request` and
`record_logout_request` stay unchanged. Raw identifiers and addresses never
enter audit metadata.

## Consequences

Login and logout audit metadata is unit-testable with plain hashes. HTTP
controllers and bootstrap identity keep calling `SecurityAudit`.

## Alternatives Rejected

- Keep hashing inside `SecurityAudit`: rejected because that object is
  persistence, not AuditLog shape.
- Fold login/logout hashes into `Identity::Audit`: rejected because Audit owns
  registration and typed identity actions, not HTTP request audits.
- Store raw identifiers or addresses: rejected by the security baseline.

## Alignment

- `docs/adr/0034-identity-event.md`
- `docs/adr/0014-identity-workflow-boundary.md`
- `docs/architecture/identity-workflow.md`
- `docs/SECURITY_BASELINE.md`
- `EVENTS.md`
- `t/129-identity-event.t`
- `t/50-security-hardening.t`
