# ADR 0016: Shared HTTP Access Decisions

## Status

Accepted.

## Context

Controller bases still duplicated CSRF token checks, cookie-session user id
lookups, and JSON negotiation after `Web::Guard` extracted error rendering.
Longevity review item 1 asked remaining HTTP helpers for auth-required and
CSRF decisions to live under `GPForum::Web::*` without a generic web
framework. Identity CSRF failures remain text payloads for the login HTML
contract.

## Decision

Introduce `GPForum::Web::Access` as the shared decision object:

- `csrf_invalid` reports Mojolicious CSRF protection failures;
- `user_id` reads the cookie-session identity through `Responder`;
- `wants_json` delegates content negotiation;
- `has_text` tests defined non-empty strings.

Controllers keep rate limits, permission gates, telemetry, and error
rendering. `Web::Guard` continues to render ErrorPayload responses.
Identity CSRF still renders `ErrorPayload->csrf_text` through
`Web::IdentityAccess`.

## Consequences

Admin, moderation, privacy, forum, attachment, notification, identity, and
realtime HTTP files no longer own the CSRF/session/JSON decision snippets.
Public HTTP cache anonymous checks and identity session validation use the
same user-id lookup. Existing status codes and payloads stay unchanged.

Tests cover the decision contract in `t/108-web-access.t`.
Identity text error rendering is covered by `t/124-web-identity-access.t`.

## Alternatives Rejected

- Fold CSRF checks into `Web::Guard`: rejected because Guard renders
  responses and must not decide whether a token is invalid.
- Add Mojolicious helpers for every decision: rejected because composition
  already uses explicit `Web::*` objects.
- Change identity CSRF to HTML ErrorPayload: rejected to preserve the
  existing login text contract.

## Alignment

- `docs/architecture/web-access.md`
- `t/108-web-access.t`
- `t/102-web-guard.t`
- `t/126-web-discovery-access.t`
- `docs/adr/0041-forum-access.md`
- `docs/adr/0042-attachment-access.md`
- `docs/adr/0043-notification-access.md`
- `docs/adr/0044-moderation-access.md`
- `docs/adr/0045-privacy-access.md`
- `docs/adr/0046-admin-access.md`
- `docs/adr/0047-metrics-token-access.md`
