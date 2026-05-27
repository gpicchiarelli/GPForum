# ADR 0002: Bootstrap Boundaries

## Status

Accepted.

## Context

`GPForum.pm` is the application composition root. As product boundaries grew, it
started mixing route registration with helper wiring for core runtime services,
security policy, UI, locale handling, identity, forum workflows, moderation,
privacy, metrics, readiness, query budget evidence, and operational telemetry.

Keeping all registration directly in the composition root makes startup harder
to scan and increases merge conflict risk as the monolith gains more product
surfaces.

## Decision

Move cohesive helper, hook, and route registration into small bootstrap modules.
Keep `GPForum.pm` as a narrow orchestration root that loads configuration,
builds runtime policy, invokes bootstrap units, and returns from startup.

Current bootstrap modules:

- `GPForum::Bootstrap::Core` registers application secrets, mode/static asset
  setup, clock, identifier, and realtime hub helpers.
- `GPForum::Bootstrap::Security` registers session policy and security response
  headers.
- `GPForum::Bootstrap::I18N` creates the i18n service and delegates SSR
  translation and presentation helper registration to the UI bootstrap.
- `GPForum::Bootstrap::UI` registers SSR presentation helpers, locale helpers,
  breadcrumbs, flash mapping, formatting helpers, and `Content-Language`.
- `GPForum::Bootstrap::Operations` registers runtime/config helpers, schema
  wiring, query statistics, local cache, security telemetry, rate limiting,
  metrics, readiness, logging, and benchmark query-budget headers.
- `GPForum::Bootstrap::Identity` registers password, session token,
  registration, identity store, identity audit, profile reader helpers, and the
  server-side session validation guard.
- `GPForum::Bootstrap::Discovery` registers canonical URL, metadata, robots,
  sitemap, and Atom feed helpers for public discovery surfaces.
- `GPForum::Bootstrap::Forum` registers forum readers, composers, stores,
  read-state helpers, attachment/media services, community helpers,
  notification helpers, search services, and the posting workflow used by SSR
  forum controllers.
- `GPForum::Bootstrap::Admin` registers role, permission, audit, and admin
  console helpers.
- `GPForum::Bootstrap::Moderation` registers report, moderation action,
  suspension, and moderation review helpers.
- `GPForum::Bootstrap::Privacy` registers privacy export, deletion workflow,
  data-rights review, and retention hold helpers.
- `GPForum::Bootstrap::Routes` registers the existing public, forum, identity,
  admin, moderation, privacy, operations, notification, attachment, discovery,
  and realtime routes.

The bootstrap modules do not own controller behavior or business workflows. They
only install application-level collaborators, hooks, routes, and presentation or
operational helpers. Public URLs, route names, helper names, service contracts,
templates, and responses remain unchanged.

## Consequences

`GPForum.pm` remains the composition root, but repeated startup concerns and the
route map are grouped by boundary. Tests can exercise bootstrap behavior without
going through the full application, and composition tests assert that existing
route and helper names continue to register.

Future extractions should follow the same rule: move registration only when the
boundary is cohesive and observable through existing helpers or routes.

## Alternatives Rejected

- Keep all helper and route registration in `GPForum.pm`: rejected because the
  composition root had become hard to review and easy to conflict on.
- Convert each boundary into a Mojolicious plugin: rejected for now because the
  project still benefits from explicit local bootstrap modules without plugin
  lifecycle indirection.
- Let controllers instantiate services directly: rejected because it would make
  helper contracts implicit and weaken startup-level verification.
