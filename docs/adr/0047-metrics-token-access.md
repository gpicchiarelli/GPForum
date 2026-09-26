# ADR 0047: Metrics Token Access Decisions

## Status

Accepted.

## Context

`Controller::Operations` mixed Bearer and `X-GPForum-Metrics-Token`
constant-time comparison, the unconfigured-token open path, unauthorized
JSON rendering, and snapshot rendering. Longevity review item 1 asked
remaining HTTP helpers to live under `GPForum::Web::*`. Those checks needed
unit coverage without Mojolicious controllers or metrics collectors.

## Decision

Introduce `GPForum::Web::OperationsAccess` behind the existing operations
controller. It owns:

- whether a configured metrics token is required;
- constant-time Bearer and metrics-header matching against the current
  token and optional previous tokens;
- the HTTP 401 `metrics token required` JSON payload;
- the `X-GPForum-Metrics-Token` header name.

`Controller::Operations` still reads request headers, renders JSON, and
collects the snapshot through `OperationsPayload`. Reverse-proxy allowlists
stay outside the app.

## Consequences

Metrics token policy is unit-testable with plain hashes. Existing open
unconfigured-token behavior and 401 JSON stay unchanged.

## Alternatives Rejected

- Fold token matching into `OperationsPayload`: rejected because Payload
  owns snapshot shape, not scrape authorization.
- Render 401 inside OperationsAccess: rejected because the controller
  already owns Mojolicious rendering.
- Change identity-style Guard HTML for metrics: rejected to preserve the
  existing JSON scrape contract.

## Alignment

- `docs/adr/0016-shared-http-access.md`
- `docs/architecture/web-access.md`
- `docs/OBSERVABILITY.md`
- `t/138-web-operations-access.t`
- `t/23-operations-hardening.t`
