# ADR 0026: Home Page Access Contract

## Status

Accepted.

## Context

`Controller::Home` owned reader limits, the success payload, and a custom
HTTP 500 with `home_unavailable` plus template `home/unavailable`. Longevity
review item 1 asked remaining HTTP helpers to live under `GPForum::Web::*`.
`Web::Guard->system_failure` uses a generic ErrorPayload and the default error
template, which would change the home contract.

## Decision

Introduce `GPForum::Web::HomeAccess` for:

- home-page reader query limits;
- the `{ home, runtime }` success payload;
- the `home_unavailable` failure payload, status 500, and template.

`Controller::Home#show` still evaluates the reader and logs failures.

## Consequences

The home unavailable contract is unit-testable without loading the
application. JSON and HTML negotiation stay on `Responder`. Existing home
status codes and error names stay unchanged.

## Alternatives Rejected

- Reuse `Web::Guard->system_failure`: rejected because it would replace
  `home_unavailable` and `home/unavailable`.
- Move the reader eval into HomeAccess: rejected because the logged failure
  belongs on the controller action.

## Alignment

- `docs/architecture/web-access.md`
- `docs/architecture/presentation.md`
- `t/03-home.t`
- `t/122-web-home-access.t`
