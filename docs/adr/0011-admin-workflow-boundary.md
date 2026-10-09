# ADR 0011: Admin Workflow Boundary

## Status

Accepted.

## Context

The admin HTTP controller previously coordinated role creation, permission
creation, permission attachment, role binding, and binding revocation
directly: it collected input, called catalog and binding stores, mapped
missing rows to HTTP 404, and duplicated required-field validation beside
CSRF and permission checks. Forum posting and moderation already use dedicated
write workflows. Longevity review item 5 asked remaining write paths to
converge on that shape without a generic framework.

## Decision

Introduce `GPForum::Service::Admin::Workflow` as the application boundary for
admin authorization writes, and split HTTP ownership:

- `Controller::Admin` keeps dashboard, catalog, user, audit, job, and status
  review pages;
- `Controller::Admin::Catalog` owns role/permission create and attach;
- `Controller::Admin::Bindings` owns bind and revoke.

The workflow validates required fields, delegates persistence to existing
stores, and returns a normalized result contract: `ok`, `status`, `error`,
`errors`, and `stored`.

Stores continue to own DBIx::Class writes and transaction boundaries.
Controllers continue to own CSRF, authentication, permission checks, HTTP
status, redirects, and content negotiation.

## Consequences

Admin HTTP files are smaller and no longer own persistence orchestration.
Failure handling is deterministic for invalid input, missing bindings, and
store exceptions. Existing store-level idempotency for duplicate role names
and active bindings is unchanged.

Tests cover controller/route ownership in `t/96-admin-controllers.t` and the
workflow contract in `t/97-admin-workflow.t`.

## Alternatives Rejected

- Keep orchestration in `Admin.pm`: rejected because the controller would keep
  growing around every new governance write.
- Move HTTP validation into stores: rejected because stores should own
  persistence, not request-field presence checks.
- Introduce a generic write-workflow framework: rejected by the longevity
  review. A dedicated admin workflow matching posting and moderation is enough.

## Alignment

- `docs/architecture/admin-workflow.md`
- `docs/architecture/posting-workflow.md`
- `docs/architecture/moderation-workflow.md`
- `t/96-admin-controllers.t`
- `t/97-admin-workflow.t`
- `t/44-admin-web.t`
- `docs/adr/0038-admin-event.md`
- `docs/adr/0046-admin-access.md`
