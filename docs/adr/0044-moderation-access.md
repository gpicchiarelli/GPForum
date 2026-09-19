# ADR 0044: Moderation Queue Limits And HTTP Policy

## Status

Accepted.

## Context

`Controller::Moderation::Base` still mixed report-queue page limits, default
open/active filters, report-resource permission hashes, workflow
failure-status mapping, and the Guard invalid-request payload with CSRF,
telemetry, and permission-gate calls. Longevity review item 1 asked remaining
HTTP helpers to live under `GPForum::Web::*`. Those contracts needed unit
coverage without Mojolicious controllers or the permission gate.

## Decision

Introduce `GPForum::Web::ModerationAccess` behind the existing moderation
HTTP base. It owns:

- the default report-queue page size;
- default report `open` and suspension `active` filters;
- permission action and resource names for queue, content, and
  suspension writes;
- write-success statuses for hide/restore/lock/unlock/reverse, queue
  assign/release/resolve, and suspend/revoke;
- permission-target hashes, including the report-resource default;
- `failed` versus `not_found` / `invalid` status mapping;
- the Guard payload for invalid moderation commands.

`Moderation::Base` still checks CSRF, cookie-session identity, permission
gates, records telemetry, and renders through `Web::Guard`. Public
`queue_limit`, `authorized_write_user_id`, and `write_failure` stay on the
controller.

## Consequences

Moderation HTTP policy is unit-testable with plain hashes. Existing 50-row
queues, default filters, and Guard titles stay unchanged.

## Alternatives Rejected

- Fold limits into `Moderation::Event`: rejected because Event owns AuditLog
  shape, not HTTP query windows.
- Fold permission hashes into `Web::Access`: rejected because Access is the
  shared CSRF/session helper, not moderation resource defaults.
- Render errors inside `ModerationAccess`: rejected because Guard already
  owns ErrorPayload HTTP rendering.

## Alignment

- `docs/adr/0010-moderation-workflow-boundary.md`
- `docs/adr/0016-shared-http-access.md`
- `docs/architecture/moderation-workflow.md`
- `docs/architecture/web-access.md`
- `t/135-web-moderation-access.t`
- `t/94-moderation-controllers.t`
