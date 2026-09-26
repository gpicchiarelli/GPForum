# ADR 0082: SEO, Public Discovery and Syndication

## Status

Accepted. Converted on 2026-09-19 from `prompt/34.txt` ("GPForum - SEO,
Public Discovery & Syndication Constitution"); this ADR replaces the prompt
as the binding source.

## Context

Public deployments want their open discussions to be findable, but every
discovery channel (metadata, sitemaps, feeds, previews) is also a leak path
for hidden, deleted or restricted content. GPForum needs mandatory rules for
public discovery architecture, SEO-safe rendering, canonical URLs, sitemaps,
robots behavior, metadata and syndication feeds. The rules are mandatory for
public deployments and govern the discovery, forum, identity (profiles) and
moderation bounded contexts.

## Decision

### Cross-ADR alignment

- ADR 0100 (domain integrity): SEO, public discovery and syndication MUST be
  visibility-aware, moderation-aware, permission-safe, deletion-aware and
  anti-leak. Restricted content MUST never appear in metadata, OpenGraph,
  sitemaps, feeds, snippets, previews or public discovery projections.
- ADR 0101 (retrieval): RSS, Atom, OpenGraph, metadata, sitemap generation,
  public feeds, previews, snippets, trending and related-thread discovery
  MUST be derived, rebuildable, bounded, cache-safe, visibility-safe,
  moderation-safe, deletion-aware and conservative under ambiguity.

### Discovery philosophy

- Public content should be discoverable when policy allows.
- Private, restricted, deleted, quarantined or moderated content MUST NOT
  leak through discovery systems.
- SEO MUST never override privacy, security or governance.

### Canonical URLs

- Canonical URLs SHOULD be stable.
- Thread URLs SHOULD include: a stable id; a human-readable slug.
- Slug changes MUST not break canonical access.
- Redirects SHOULD preserve legacy links where safe.

### Metadata

- Public pages SHOULD include: title; description; canonical link;
  OpenGraph metadata; basic social preview metadata.
- Metadata MUST be generated from safe, sanitized content.
- Private content MUST NOT appear in public metadata.

### Sitemaps

- The platform SHOULD generate sitemaps for: public spaces; public
  categories; public threads.
- Sitemaps MUST exclude: hidden content; deleted content; quarantined
  content; restricted content; user profiles where policy disallows
  indexing.
- Sitemap generation SHOULD be asynchronous and cacheable.

### Robots

- `robots.txt` SHOULD be configurable.
- It SHOULD disallow: admin routes; moderation routes; login and
  registration routes; user settings; internal endpoints; search result
  pages where policy prefers no indexing.
- Robots rules MUST NOT be treated as access control.

### RSS and Atom

- Public feeds MAY be exposed as RSS or Atom.
- Feeds MUST respect: visibility; deletion; moderation; rate limiting; cache
  safety.
- Feeds SHOULD include only safe excerpts unless policy allows full content.

### Pagination and indexing

- Paginated pages SHOULD expose stable navigation metadata.
- The platform MUST avoid generating infinite crawl spaces.
- Search result pages SHOULD be noindex unless explicitly designed for public
  discovery.

### Abuse resistance

SEO features MUST resist: spam page generation; tag abuse; profile spam;
malicious OpenGraph injection; crawler amplification.

## Consequences

- Discovery outputs are derived from the same visibility and moderation
  state as SSR pages, so hiding or deleting content must also invalidate
  metadata, sitemap and feed caches.
- `/t/:thread_id/:slug` URLs keep links stable when titles change, at the
  cost of redirect handling for slug and legacy URLs (ADR 0081).
- Robots rules only steer crawlers; every excluded route still needs server
  authorization (ADR 0072).

## Alignment

- ADRs: 0100 and 0101 (cross-alignment), 0062 and 0090 (search), 0072
  (routes), 0081 (legacy redirects); 0019 (public cache access), 0030
  (discovery access).
- Code: `lib/GPForum/Service/Discovery/` (`CanonicalUrl`, `FeedBuilder`,
  `MetadataBuilder`, `RobotsPolicy`, `SitemapBuilder`, `VisibilityPolicy`),
  `lib/GPForum/Controller/Discovery.pm`,
  `lib/GPForum/Web/DiscoveryAccess.pm`, `robots.txt`.
- Tests: `t/30-public-discovery.t`, `t/78-web-operations-discovery-payloads.t`,
  `t/126-web-discovery-access.t`.
