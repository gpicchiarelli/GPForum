# ADR 0019: Public HTTP Cache Access Decisions

## Status

Accepted.

## Context

`Web::PublicHttpCache` mixed cache storage, HTML rendering, and freshness
decisions. Cacheability, ETag matching, and If-Modified-Since parsing used
postfix control and sat in the same object that writes Cache-Control headers.
Longevity review item 1 asked remaining HTTP decisions to live under
`GPForum::Web::*` as dedicated helpers, matching `Web::Access`,
`Web::RealtimeAccess`, and `Web::CookieSession`.

## Decision

Introduce `GPForum::Web::PublicCacheAccess` as the decision object for:

- anonymous GET/HEAD cacheability;
- If-None-Match / ETag matching including `*`;
- If-Modified-Since / Last-Modified freshness;
- `revalidated` versus `miss-revalidated` header labels.

`Web::PublicHttpCache` still requires a cache backend, renders HTML, stores
entries, and emits 304 responses. Authenticated requests remain uncached
because `Web::Access` reports a cookie-session user id.

## Consequences

Freshness rules can be unit-tested without a cache backend or SSR render.
Existing `Cache-Control`, weak ETag, `Vary: Accept, Cookie`, and 304
contracts stay unchanged.

Tests cover the decision contract in `t/115-web-public-cache-access.t`.

## Alternatives Rejected

- Fold cacheability into `Web::Access`: rejected because Access is
  CSRF/session/JSON, not public-cache freshness.
- Keep decisions inside `PublicHttpCache`: rejected because storage and
  HTTP validators would keep growing together.
- Cache authenticated HTML with private Cache-Control: rejected; public
  SSR cache stays anonymous-only.

## Alignment

- `docs/architecture/web-access.md`
- `docs/PERFORMANCE.md`
- `t/115-web-public-cache-access.t`
- `t/32-forum-web.t`
