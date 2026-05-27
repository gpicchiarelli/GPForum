# ADR 0002: Bootstrap Boundaries

## Status

Accepted.

## Context

`GPForum.pm` is the application composition root. As product boundaries grew, it
started mixing route registration with helper wiring for UI, locale handling,
runtime policy, metrics, readiness, query budget evidence, and operational
telemetry.

Keeping all registration directly in the composition root makes startup harder
to scan and increases merge conflict risk as the monolith gains more product
surfaces.

## Decision

Move cohesive helper and hook registration into small bootstrap modules while
keeping route ownership in `GPForum.pm`.

Current bootstrap modules:

- `GPForum::Bootstrap::UI` registers SSR presentation helpers, locale helpers,
  breadcrumbs, flash mapping, formatting helpers, and `Content-Language`.
- `GPForum::Bootstrap::Operations` registers runtime/config helpers, schema
  wiring, query statistics, local cache, security telemetry, rate limiting,
  metrics, readiness, logging, and benchmark query-budget headers.
- `GPForum::Bootstrap::Identity` registers password, session token,
  registration, identity store, identity audit, profile reader helpers, and the
  server-side session validation guard.

The bootstrap modules do not own controller behavior or business workflows.
They only install application-level collaborators, hooks, and presentation or
operational helpers.

## Consequences

`GPForum.pm` remains the central route map and composition root, but repeated
startup concerns are grouped by boundary. Tests can exercise bootstrap behavior
without going through the full application.

Future extractions should follow the same rule: move registration only when the
boundary is cohesive and observable through existing helpers or routes.
