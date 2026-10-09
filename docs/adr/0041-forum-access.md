# ADR 0041: Forum Rate Limits And Input Policy

## Status

Accepted.

## Context

`Controller::Forum::Base` still mixed read/write rate-limit hashes,
bookmark/subscription churn caps, participation actions, report field
errors, search filter names, public SSR cache keys, and integer limit
parsing with CSRF/Guard rendering. Longevity review item 1 asked remaining
HTTP helpers to live under `GPForum::Web::*`. Those policies needed unit
coverage without Mojolicious controllers or the rate-limiter service.

## Decision

Introduce `GPForum::Web::ForumAccess` behind the existing forum HTTP base.
It owns:

- `forum_retrieval` and `forum_http` rate-limit argument hashes;
- report versus churn versus default write caps;
- `thread.create` / `reply.create` participation;
- report reason/details errors;
- non-negative integer and bounded-limit parsing;
- search filter field names and public SSR cache keys;
- search page, autocomplete, fetch, and more-results limits;
- category/thread/feed/bookmark list page defaults;
- community post/thread/user target types;
- community bookmark and subscription write-success statuses;
- last-read position validation errors.

`Forum::Base` still checks CSRF, cookie-session identity, suspensions, and
renders through `Web::Guard`. Public `write_user_id`, `read_allowed`,
`bounded_limit`, and `is_non_negative_integer` stay on the controller.

## Consequences

Forum HTTP policy is unit-testable with plain hashes. Existing 20/10/5 write
caps, 60-request read window, 20/50 search pages, 10/50 autocomplete, and
Guard status codes stay unchanged.

## Alternatives Rejected

- Fold limits into `Web::Guard`: rejected because Guard renders ErrorPayload
  responses and must not own rate numbers.
- Fold report validation into `Moderation::Event`: rejected because Event
  owns AuditLog shape, not HTTP field errors.
- Change forum CSRF away from Guard: rejected to preserve the existing HTML
  error contract.

## Alignment

- `docs/adr/0016-shared-http-access.md`
- `docs/architecture/web-access.md`
- `docs/architecture/presentation.md`
- `t/132-web-forum-access.t`
