# ADR 0015: Attachment and Notification Workflow Boundaries

## Status

Accepted.

## Context

Attachment HTTP mixed post lookup, author checks, upload-pipeline calls, and
byte delivery in one controller. Notification HTTP mixed inbox reads,
mention reads, and mark-read writes in one controller. Forum posting,
moderation, admin, privacy, and identity already use dedicated write
workflows with a normalized `{ ok, status, error, errors, stored }` contract.
Longevity review item 5 asked remaining write paths to converge on that shape
without a generic framework. Item 1 asked remaining mixed controllers to
split HTTP ownership.

## Decision

Introduce `GPForum::Service::Attachment::Workflow` as the application
boundary for post attachment uploads and downloads, and
`GPForum::Service::Notification::Workflow` as the boundary for mark-read
writes. Split HTTP ownership:

- `Controller::Attachments` keeps downloads;
- `Controller::Attachments::Upload` owns post attachment writes;
- `Controller::Notifications` keeps the inbox;
- `Controller::Notifications::Read` owns mark-read writes;
- `Controller::Notifications::Mentions` owns mention reads.

The attachment workflow looks up a visible post, enforces author ownership,
and delegates storage to the existing upload pipeline and delivery service.
Missing posts and objects surface as `not_found`. Non-author uploads and
unavailable objects surface as `forbidden`. Pipeline validation errors
surface as `invalid`.

The notification workflow maps missing inbox rows to `not_found`. Dispatchers
and readers keep persistence and projection ownership.

`gp_attachment_workflow` and `gp_notification_workflow` are composed from the
existing pipeline, delivery, post-reader, and dispatcher helpers so web tests
that stub those helpers keep working.

## Consequences

Attachment and notification HTTP files no longer own store exception mapping
or post-author checks. Rate-limit denials on attachment uploads now return
without treating the rendered controller as a user id. Existing upload and
delivery semantics are unchanged.

Tests cover controller/route ownership in `t/104-attachment-controllers.t`
and `t/106-notification-controllers.t`, and workflow contracts in
`t/105-attachment-workflow.t` and `t/107-notification-workflow.t`.

## Alternatives Rejected

- Keep orchestration in `Attachments.pm` and `Notifications.pm`: rejected
  because those files mixed reads, writes, and authorization branching.
- Fold HTTP validation into `UploadPipeline` or `Dispatcher`: rejected
  because those services already own storage and projection semantics.
- Introduce a generic write-workflow framework: rejected by the longevity
  review.

## Alignment

- `docs/architecture/attachment-workflow.md`
- `docs/architecture/notification-workflow.md`
- `t/104-attachment-controllers.t`
- `t/105-attachment-workflow.t`
- `t/106-notification-controllers.t`
- `t/107-notification-workflow.t`
- `t/63-attachments-web.t`
- `t/32-forum-web.t`
- `docs/adr/0042-attachment-access.md`
- `docs/adr/0043-notification-access.md`
