# ADR 0046: Admin Page Limits And HTTP Policy

## Status

Accepted.

## Context

`Controller::Admin::Base` still mixed catalog page limits, the
`admin_console`/`manage` permission hash, `failed` / `not_found` /
`invalid` mapping, the Guard invalid-request payload, and the default roles
redirect with CSRF, telemetry, and permission-gate calls. Longevity review
item 1 asked remaining HTTP helpers to live under `GPForum::Web::*`. Those
contracts needed unit coverage without Mojolicious controllers or the
permission gate.

## Decision

Introduce `GPForum::Web::AdminAccess` behind the existing admin HTTP base.
It owns:

- the default catalog page size;
- the dashboard summary/audit/role row cap;
- the staff `manage` action, catalog `view` action, and `admin_console`
  permission hash;
- catalog and binding write-success statuses (`role_created`,
  `permission_created`, `role_permission_attached`, `role_bound`,
  `role_binding_revoked`);
- `failed` versus `not_found` / `invalid` status mapping;
- the Guard payload for invalid admin commands;
- the default `admin_roles` redirect.

`Admin::Base` still checks CSRF, cookie-session identity, permission gates,
records telemetry, and renders through `Web::Guard`. Public `limit_param`,
`authorized_write_user_id`, and `write_failure` stay on the controller.

## Consequences

Admin HTTP policy is unit-testable with plain hashes. Existing 50-row pages,
Guard titles, and roles-catalog redirects stay unchanged.

## Alternatives Rejected

- Fold limits into `Admin::Event`: rejected because Event owns AuditLog
  shape, not HTTP query windows.
- Fold permission hashes into `Web::Access`: rejected because Access is the
  shared CSRF/session helper, not admin resource defaults.
- Render errors inside `AdminAccess`: rejected because Guard already owns
  ErrorPayload HTTP rendering.

## Alignment

- `docs/adr/0011-admin-workflow-boundary.md`
- `docs/adr/0016-shared-http-access.md`
- `docs/architecture/admin-workflow.md`
- `docs/architecture/web-access.md`
- `t/137-web-admin-access.t`
- `t/96-admin-controllers.t`
