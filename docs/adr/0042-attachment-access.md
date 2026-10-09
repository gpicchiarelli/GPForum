# ADR 0042: Attachment Upload Limits And HTTP Policy

## Status

Accepted.

## Context

`Controller::Attachments::Base` still mixed the upload rate-limit hash,
download filename sanitizing, content-disposition quoting, workflow
failure-status mapping, and Guard payloads for invalid uploads and rate
limits with CSRF and session checks. Longevity review item 1 asked remaining
HTTP helpers to live under `GPForum::Web::*`. Those contracts needed unit
coverage without Mojolicious controllers or the rate-limiter service.

## Decision

Introduce `GPForum::Web::AttachmentAccess` behind the existing attachment
HTTP base. It owns:

- the `forum_http` / `attachment.upload` rate-limit arguments;
- quote and line-break filename sanitizing;
- `Content-Disposition` values;
- `failed` versus `not_found` / `invalid` / `forbidden` status mapping;
- Guard payloads for invalid uploads and rate limits.

`Attachments::Base` still checks CSRF, cookie-session identity, and renders
through `Web::Guard`. Public `write_user_id`, `safe_filename`, and
`write_failure` stay on the controller.

## Consequences

Attachment HTTP policy is unit-testable with plain hashes. Existing 20/60s
upload caps, filename replacement, and Guard titles stay unchanged.

## Alternatives Rejected

- Fold limits into `Attachment::DownloadAccess`: rejected because download
  visibility is a store grant, not an HTTP rate or filename policy.
- Fold filename sanitizing into `Attachment::Record`: rejected because Record
  is a row accessor.
- Render errors inside `AttachmentAccess`: rejected because Guard already
  owns ErrorPayload HTTP rendering.

## Alignment

- `docs/adr/0015-attachment-notification-workflow-boundary.md`
- `docs/adr/0016-shared-http-access.md`
- `docs/architecture/attachment-workflow.md`
- `docs/architecture/web-access.md`
- `t/133-web-attachment-access.t`
- `t/104-attachment-controllers.t`
