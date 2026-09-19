# ADR 0045: Privacy Page Limits And HTTP Policy

## Status

Accepted.

## Context

`Controller::Privacy::Base` still mixed list page limits, the
`privacy_rights`/`manage` permission hash, `failed` / `not_found` /
`invalid` / `conflict` mapping, Guard payloads for invalid and blocked
actions, and the default dashboard redirect with CSRF and permission-gate
calls. Longevity review item 1 asked remaining HTTP helpers to live under
`GPForum::Web::*`. Those contracts needed unit coverage without Mojolicious
controllers or the permission gate.

## Decision

Introduce `GPForum::Web::PrivacyAccess` behind the existing privacy HTTP
base. It owns:

- the default privacy list page size;
- the `privacy_http` / `privacy.request` and `privacy.review` rate-limit
  arguments (5 versus 20);
- the staff-review `manage` action, catalog `view` action, and
  `privacy_rights` permission hash;
- review write-success statuses (`deletion_approved`, `deletion_held`);
- `failed` versus `not_found` / `invalid` / `conflict` status mapping;
- Guard payloads for invalid requests and blocked holds;
- the default `privacy_dashboard` redirect.

`Privacy::Base` still checks CSRF, cookie-session identity, permission
gates, the rate limiter, records telemetry, and renders through
`Web::Guard`. Public `limit_param`, `write_user_id`,
`authorized_write_user_id`, and `write_failure` stay on the controller.

## Consequences

Privacy HTTP policy is unit-testable with plain hashes. Existing 25-row
pages, `conflict` → blocked hold titles, and Guard status codes stay
unchanged.

## Alternatives Rejected

- Fold limits into `Privacy::Event`: rejected because Event owns AuditLog
  shape, not HTTP query windows.
- Fold conflict payloads into `Web::Guard`: rejected because Guard renders
  ErrorPayload responses and must not own privacy-specific blocked titles.
- Render errors inside `PrivacyAccess`: rejected because Guard already owns
  ErrorPayload HTTP rendering.

## Alignment

- `docs/adr/0013-privacy-workflow-boundary.md`
- `docs/adr/0016-shared-http-access.md`
- `docs/architecture/privacy-workflow.md`
- `docs/architecture/web-access.md`
- `t/136-web-privacy-access.t`
- `t/100-privacy-controllers.t`
