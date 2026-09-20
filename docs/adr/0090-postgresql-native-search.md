# ADR 0090: PostgreSQL-Native Search and Perl Retrieval

## Status

Accepted. Converted on 2026-09-19 from `prompt/42.txt` ("GPForum -
PostgreSQL Native Search & Perl Retrieval Constitution"); this ADR replaces
the prompt as the binding source. It replaces OpenSearch as the default
search architecture.

## Context

An external search cluster would be a second stateful system to operate,
secure and keep permission-consistent with PostgreSQL. GPForum instead makes
PostgreSQL full-text and trigram search, with Perl-owned policy, the default
retrieval architecture, and keeps any external engine optional. This ADR is
foundational and mandatory and governs the search, discovery, feed and
projection bounded contexts.

## Decision

### Cross-ADR alignment

- ADR 0101 (retrieval): PostgreSQL-native retrieval covers search, feeds,
  syndication, autocomplete, ranking, metadata and discovery projections.
  These surfaces MUST remain derived, rebuildable, permission-safe,
  moderation-safe, deletion-aware, observable and anti-leak.

### Search decision

- GPForum search MUST be PostgreSQL-native by default.
- The canonical search model is: PostgreSQL full-text search; PostgreSQL
  trigram search; PostgreSQL search projection tables; Perl indexing
  orchestration; Perl query normalization; Perl ranking policy;
  Minion-backed asynchronous indexing.
- OpenSearch is OPTIONAL external acceleration and MUST NOT be foundational
  infrastructure.

### PostgreSQL search features

- The search subsystem SHOULD use: `tsvector` columns; `tsquery` and
  `websearch_to_tsquery`; GIN indexes; `pg_trgm` for autocomplete and fuzzy
  matching; `unaccent` where appropriate; language-specific configurations;
  weighted vectors for title/body/category metadata.
- Italian support SHOULD be first-class.

### Perl search layer

- The Perl search layer SHOULD include: `GPForum::Search`;
  `GPForum::Search::Indexer`; `GPForum::Search::Query`;
  `GPForum::Search::Ranker`; `GPForum::Search::Rebuild`;
  `GPForum::Search::PermissionFilter`.
- Perl MUST own search policy.
- PostgreSQL executes retrieval.

### Search projection tables

- Search documents SHOULD be stored in PostgreSQL projection tables.
- Recommended projection fields: `entity_type`; `entity_id`; `space_id`;
  `visibility`; `permission_scope`; `language`; `title`; `body`;
  `search_vector`; `indexed_at`; `source_version`.
- Search projections MUST remain rebuildable from canonical persistence.
- Search documents are never authoritative. A hidden post MUST be removed
  from or filtered out of search before it can be shown to ordinary users.
- Search projection rows MUST include `source_version`,
  `visibility_version` and `permission_version`. Rebuild jobs MUST compare
  these versions before publishing results or cache invalidations.

### Indexing workflow

- Indexing MUST be asynchronous.
- Canonical workflow:
  1. canonical write completes;
  2. domain event is stored;
  3. a Minion job indexes or updates the search projection;
  4. PostgreSQL search indexes are updated;
  5. cache invalidation is emitted where needed.
- Indexing MUST NOT block user-facing writes.

### Ranking

- Ranking SHOULD combine: PostgreSQL `ts_rank` or `ts_rank_cd`; title/body
  weighting; freshness; category/thread visibility; moderation state;
  optional Perl-side ranking policy.
- Ranking MUST remain explainable.

### Authorization

- Search MUST be permission-aware.
- Authorization filtering MAY occur through: indexed visibility fields;
  permission scope columns; SQL joins; post-query Perl filtering for final
  safety.
- Private, quarantined, hidden, deleted or restricted content MUST NOT leak
  through search results, snippets, counts, autocomplete or feeds.

### Autocomplete

- Autocomplete SHOULD use `pg_trgm` where appropriate.
- Autocomplete MUST be: rate-limited; permission-aware; bounded;
  abuse-resistant.

### Rebuild

- Search rebuild MUST support: full rebuild; targeted rebuild; event-range
  replay; progress tracking; idempotency; safe interruption and resume.
- Rebuild MUST NOT block canonical forum writes.

### Optional external search

- External search engines MAY be introduced only through ADR.
- Any external search engine MUST remain: derived; rebuildable;
  non-authoritative; permission-aware; operationally optional.
- The default GPForum architecture remains PostgreSQL-native search with
  Perl orchestration.

## Consequences

- Search runs on the same PostgreSQL that holds canonical data, so there is
  no second cluster to operate, and permission filtering can join canonical
  visibility state.
- Search load competes with OLTP load on PostgreSQL, which makes query
  budgets, GIN index maintenance and asynchronous indexing capacity part of
  database capacity planning (ADR 0063, ADR 0088).
- Version columns on projection rows let rebuilds and replays detect stale
  documents before publishing them.
- Open conflicts: the Perl search layer is implemented as
  `GPForum::Service::Search::DocumentBuilder`, `::Indexer`,
  `::PermissionEngine` and `::Searcher`; the recommended
  `GPForum::Search::*` namespace and separate `Query`, `Ranker` and
  `Rebuild` modules do not exist.

## Alignment

- ADRs: 0101 (cross-alignment), 0062 (search, indexing and retrieval),
  0063 and 0088 (capacity), 0074 (search and privacy), 0075 (search rebuild
  runbook), 0082 (feeds and discovery); 0030 (discovery access).
- Code: `lib/GPForum/Service/Search/`, `lib/GPForum/Bootstrap/Workers.pm`,
  `lib/GPForum/Controller/Forum/Search.pm`.
- Migrations: `migrations/003_forum_projection.sql` (`search_documents`,
  `pg_trgm`), `migrations/018_search_product_hardening.sql`.
- Tests: `t/19-search.t`, `t/integration/postgres.t`.
