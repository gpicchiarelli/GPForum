# ADR 0030: Discovery Reader Limits And Document Rendering

## Status

Accepted.

## Context

`Controller::Discovery` owned sitemap/feed row limits and content-type plus
body rendering after `DiscoveryPayload` already shaped robots, sitemap, and
Atom documents. Longevity review item 1 asked remaining HTTP helpers to live
under `GPForum::Web::*`. Those limits were not unit-testable without category
and thread readers.

## Decision

Introduce `GPForum::Web::DiscoveryAccess` for:

- default sitemap row and Atom feed limits;
- the content-type header and document body render.

`Controller::Discovery` still loads public categories and threads.
`DiscoveryPayload` still builds document data.

## Consequences

Feed and sitemap limits are unit-testable without reader services. Existing
content types, formats, and HTTP 200 defaults stay unchanged.

## Alternatives Rejected

- Fold reader limits into `DiscoveryPayload`: rejected because payloads own
  document bytes, not HTTP query windows.
- Render through `Web::Responder`: rejected because crawler documents are
  raw `data` bodies, not SSR templates or JSON hashes.

## Alignment

- `docs/architecture/web-access.md`
- `docs/architecture/presentation.md`
- `t/78-web-operations-discovery-payloads.t`
- `t/126-web-discovery-access.t`
