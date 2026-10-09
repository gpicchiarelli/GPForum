# ADR 0028: Identity Text Error Access

## Status

Accepted.

## Context

Identity HTTP still rendered CSRF, rate-limit, system-failure, and bad-request
responses inline after `Web::Guard` extracted shared ErrorPayload HTML/JSON
rendering. Login CSRF is plaintext `Bad CSRF token`, not the Guard HTML
template. ADR 0016 already rejected changing that contract.

## Decision

Introduce `GPForum::Web::IdentityAccess` for identity HTTP policy:

- CSRF is always plaintext HTTP 403;
- rate-limit, system-failure, and bad-request choose JSON or plaintext;
- `identity_http` rate-limit hashes for login, register, password, email,
  logout, and settings;
- public-profile thread page defaults;
- locale/theme preference-cookie names and Lax one-year options.

`Controller::Identity::Base` still records security telemetry, still calls
the rate limiter, and still flashes then redirects unauthenticated settings
HTML to login.

## Consequences

Identity text contracts are unit-testable without the application. Guard is
not used. Existing status codes and strings stay unchanged.

## Alternatives Rejected

- Render identity CSRF through `Web::Guard`: rejected by ADR 0016.
- Move settings unauthorized redirects into IdentityAccess: rejected because
  those responses need i18n flash text.

## Alignment

- `docs/adr/0016-shared-http-access.md`
- `docs/architecture/web-access.md`
- `t/76-web-error-payload.t`
- `t/124-web-identity-access.t`
