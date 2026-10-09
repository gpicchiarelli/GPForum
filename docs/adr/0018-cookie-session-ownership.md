# ADR 0018: Cookie Session Field Ownership

## Status

Accepted.

## Context

Bootstrap identity mixed cookie-session presence, expiry, field deletion, and
store validation in `_validate_server_session` and `_expire_stale_session`.
The identity login controller assembled cookie hashes and deleted keys inline.
Longevity review item 1 asked remaining HTTP helpers to live under
`GPForum::Web::*`. `Web::Access` already reads `user_id`; it does not own
session-id presence, expiry, or login-value assembly.

## Decision

Introduce `GPForum::Web::CookieSession` as the cookie-session field object:

- `has_server_session` requires both `session_id` and `user_id`;
- `expired` compares `session_expires_at_epoch` to a supplied clock;
- `session_seconds` / `expires_at` own the 30-day authenticated cookie
  lifetime;
- `clear` deletes server-session keys and expires the Mojolicious cookie;
- `replace_login` resets login keys and writes authenticated values;
- `validation_reason` maps missing store results to `validation_failed`.

Bootstrap identity still calls `Identity::Store->validate_session` and records
telemetry. The identity controller still sets locale/theme cookies after
login replacement. Preference-cookie names and options live on
`Web::IdentityAccess`.

## Consequences

Cookie-session field rules can be unit-tested without Mojolicious hooks.
Invalidation still leaves locale and theme cookies in place; login
replacement still overwrites them. Existing 401 telemetry statuses stay
unchanged. Server-side session TTL remains on `Identity::SessionStore`.

Tests cover the contract in `t/114-web-cookie-session.t`.

## Alternatives Rejected

- Fold expiry into `Web::Access`: rejected because Access is request-shape
  and CSRF, not cookie-session mutation.
- Validate server sessions inside CookieSession: rejected because the store
  remains the persistence boundary.
- Clear locale/theme on invalidation: rejected to preserve the current
  preference-cookie contract.

## Alignment

- `docs/architecture/web-access.md`
- `t/114-web-cookie-session.t`
- `t/70-bootstrap-identity.t`
- `t/06-identity-web.t`
