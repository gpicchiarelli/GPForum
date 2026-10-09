# ADR 0017: Realtime Handshake Access Decisions

## Status

Accepted.

## Context

The realtime websocket controller mixed origin matching, payload-size checks,
subscribe-message shape, HTTP rendering, hub registration, and security
telemetry in `stream` and `_handle_message`. Those two methods sat above the
McCabe limit and used postfix control. Longevity review item 1 asked remaining
HTTP decisions to live under `GPForum::Web::*` without a generic web
framework. `Web::Access` already owns CSRF, cookie-session user id, and JSON
negotiation, but not websocket handshake rules.

## Decision

Introduce `GPForum::Web::RealtimeAccess` as the decision object for:

- Origin header matching against the request origin and public base URL;
- JSON payload size against the realtime byte limit;
- subscribe-message type checks;
- channel-type prefix parsing;
- `user`-scope `realtime.connect` / `realtime.subscribe` rate-limit hashes;
- plaintext handshake texts for origin, authentication, and too-many
  connections.

`Controller::Realtime` keeps rate-limiter checks, hub register/subscribe,
telemetry, HTTP status rendering, and websocket frames. Failed origin and
payload checks still record the same security events as before.

## Consequences

Realtime handshake rules can be unit-tested without opening a websocket.
Controller complexity stays at or below the critic McCabe ceiling. Existing
401/403/429 texts and subscribe error reasons stay unchanged.

Tests cover the decision contract in `t/113-web-realtime-access.t`.

## Alternatives Rejected

- Fold origin checks into `Web::Access`: rejected because Access is
  request-shape/session, not websocket-specific.
- Call the rate limiter from RealtimeAccess: rejected because limiter checks
  stay controller-owned like other HTTP writes.
- Change origin-denied rendering to `Web::Guard`: rejected to preserve the
  existing plaintext websocket handshake contract.

## Alignment

- `docs/architecture/web-access.md`
- `docs/realtime.md`
- `t/113-web-realtime-access.t`
- `t/81-realtime-operational.t`
