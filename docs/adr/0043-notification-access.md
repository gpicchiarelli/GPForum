# ADR 0043: Notification Page Limits And HTTP Policy

## Status

Accepted.

## Context

`Controller::Notifications::Base` still mixed inbox/mention page limits, the
`notification_http` write rate-limit hash, and `failed` / `not_found`
workflow mapping with CSRF, telemetry, and Guard rendering. Longevity review
item 1 asked remaining HTTP helpers to live under `GPForum::Web::*`. Those
contracts needed unit coverage without Mojolicious controllers or the
rate-limiter service.

## Decision

Introduce `GPForum::Web::NotificationAccess` behind the existing
notification HTTP base. It owns:

- the default inbox/mention page size;
- `notification_http` write rate-limit arguments;
- `failed` versus `not_found` status mapping.

`Notifications::Base` still checks CSRF, cookie-session identity, records
telemetry, and renders through `Web::Guard`. Public `page_limit`,
`write_user_id`, and `write_failure` stay on the controller.

## Consequences

Notification HTTP policy is unit-testable with plain hashes. Existing 25-row
pages, 120/60s write caps, and Guard status codes stay unchanged.

## Alternatives Rejected

- Fold limits into `Notification::Workflow`: rejected because Workflow is the
  write boundary, not HTTP query windows.
- Fold rate hashes into `Web::ForumAccess`: rejected because notification
  writes use a dedicated `notification_http` scope and cap.
- Render errors inside `NotificationAccess`: rejected because Guard already
  owns ErrorPayload HTTP rendering.

## Alignment

- `docs/adr/0015-attachment-notification-workflow-boundary.md`
- `docs/adr/0016-shared-http-access.md`
- `docs/architecture/notification-workflow.md`
- `docs/architecture/web-access.md`
- `t/134-web-notification-access.t`
- `t/106-notification-controllers.t`
