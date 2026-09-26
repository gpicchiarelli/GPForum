# ADR 0038: Admin Catalog And Binding Audit Hashes

## Status

Accepted.

## Context

`Admin::RoleBindingStore` and `Admin::RoleCatalog` still mixed AuditLog
argument hashes with RoleBinding, Role, Permission, and RolePermission writes
after ADR 0011 extracted the HTTP write workflow. Those contracts needed unit
coverage without schema or `Crypt::URandom`. Longevity review item 5 asked
remaining write paths to own event/audit hashes outside persistence.

## Decision

Introduce `GPForum::Service::Admin::Event` behind the existing admin stores.
It owns:

- created and revoked role-binding AuditLog hashes;
- role, permission, and attachment catalog AuditLog hashes.

The stores still insert and update rows and persist through `EventRecorder`.
Public signatures stay unchanged. Admin writes still emit AuditLog only.

## Consequences

Admin audit metadata is unit-testable with plain hashes. `Admin::Workflow`
keeps calling the stores.

## Alternatives Rejected

- Fold hashes into `Admin::Workflow`: rejected because that object is the HTTP
  write boundary, not AuditLog shape.
- Emit EventLog envelopes in this change: rejected because the current admin
  contract is audit-only.

## Alignment

- `docs/adr/0011-admin-workflow-boundary.md`
- `docs/architecture/admin-workflow.md`
- `EVENTS.md`
- `t/131-admin-event.t`
