# ADR 0062: Search, Indexing and Information Retrieval

## Status

Accepted. Converted on 2026-09-19 from `prompt/14.txt` ("GPForum — Search,
Indexing & Information Retrieval Constitution"); this ADR replaces the prompt
as the binding source.

## Context

Search reads across all discussion content and is the easiest place to leak
hidden, quarantined or deleted material, to overload the database through
hostile queries, or to let a derived index drift into acting as a source of
truth.

This ADR is foundational and mandatory. It defines the search architecture,
indexing philosophy, retrieval model, ranking strategy, query discipline,
synchronization workflows, language analysis rules, authorization-aware
filtering and long-term information retrieval principles. It governs the
Search bounded context (search documents, indexing workers, query
normalization, ranking, autocomplete, search caching and search APIs) and its
consumption of Discussion, Moderation and Authorization events.

## Decision

### Cross-Constitution Alignment

- ADR 0093: search is a derived, rebuildable, permission-aware system. Search
  documents MUST NOT become authoritative state. Search invariants MUST be
  contract-tested, including negative tests that hidden, deleted,
  quarantined or unauthorized content never appears in search output.
- ADR 0094: search interfaces MUST be accessible. Search forms, filters,
  result lists, snippets, empty states and pagination MUST use semantic HTML,
  accessible labels, keyboard navigation and screen-reader-safe result
  counts and status messages.
- ADR 0099: search is a hot, derived, rebuildable projection. Search
  documents MUST support idempotent rebuilds, inactive rebuild generations,
  activation swaps where needed, permission-safe stale-state handling and
  graceful degradation when indexing stalls.
- ADR 0101: search, autocomplete, ranking, feeds, metadata and syndication
  MUST remain PostgreSQL-native by default, derived, rebuildable,
  permission-aware, moderation-aware, deletion-aware, observable, bounded,
  anti-leak and operationally optional.

### Search Philosophy

- Search is a distributed projection system, an asynchronous retrieval layer
  and a derived information model.
- Search is NOT the canonical persistence layer, the authoritative business
  database or the primary transactional system.
- The authoritative source of truth remains PostgreSQL.
- Search MUST remain rebuildable, eventually consistent, permission-aware and
  operationally isolated.

### Search Architecture

- Preferred search technology: PostgreSQL full-text search.
- Preferred supporting PostgreSQL features: `tsvector`, `tsquery`, GIN
  indexes, `pg_trgm`, `unaccent` where appropriate, and language-aware text
  search configurations.
- Perl MUST own indexing orchestration, query normalization, ranking policy,
  rebuild workflows and authorization-aware filtering.
- The search subsystem MUST remain PostgreSQL-native by default,
  asynchronously synchronized, process-scalable through Perl workers and
  operationally observable.
- External search engines MAY be added only as optional acceleration.
- External search engines MUST remain separated from transactional
  persistence and request-critical workflows.

### Indexing Philosophy

- Indexing MUST occur asynchronously, event-driven and replay-aware.
- Canonical persistence MUST complete before indexing propagation, ranking
  updates and aggregation updates.
- Indexing MUST NOT block post creation, thread creation, moderation actions
  or user workflows.

### Search Synchronization

- Search synchronization SHOULD consume domain events, moderation events,
  visibility events and authorization changes (for example `post.created`,
  `post.edited`, `thread.locked`, `user.suspended`,
  `category.visibility_changed`).
- Search MUST tolerate delayed propagation, replay and duplicate indexing
  attempts.

### Search Document Philosophy

- Search indexes SHOULD use denormalized search documents.
- Search documents MAY aggregate thread metadata, post excerpts, author
  metadata, category metadata and moderation visibility state.
- Search documents MUST remain rebuildable, traceable and asynchronously
  generated.

### Search Document Ownership

- Search documents are projections, derived representations and disposable
  read models.
- Search indexes MUST NOT become authoritative persistence, canonical
  moderation state or permission authority.

### Authorization-Aware Search

- Search results MUST remain permission-filtered, moderation-aware and
  visibility-aware.
- The search layer MUST enforce authorization filtering, moderation
  visibility, quarantine restrictions and soft deletion semantics.
- Search MUST NOT leak hidden content, quarantined content or restricted
  moderation data.

### Ranking Philosophy

- Ranking SHOULD prioritize relevance, freshness, permission safety and
  operational predictability.
- Ranking MUST remain deterministic where possible, explainable and tunable.
- The platform SHOULD avoid opaque ranking systems and unstable scoring
  behavior.

### Language Analysis

- The search system SHOULD support multilingual analysis, stemming, token
  normalization and Unicode-aware indexing.
- Italian language support SHOULD include stemming, stopword handling,
  accent normalization and token-aware ranking.

### Search Query Philosophy

- Queries MUST remain validated, bounded, rate-limited and abuse-aware.
- The platform MUST avoid unrestricted wildcard explosion, backend query
  injection and unbounded aggregation.
- Search input MUST be treated as hostile.

### Full-Text Search

- Search SHOULD support thread, post, category, tag and user search.
- Search SHOULD support phrase search, relevance ranking, recency boosting
  and partial matching where appropriate.

### Incremental Indexing

- The architecture MUST support incremental indexing, partial document
  updates and asynchronous refresh.
- The indexing pipeline SHOULD minimize full index rebuild dependency.

### Rebuild Philosophy

- The search architecture MUST support full rebuild, partial rebuild and
  replay-based reconstruction.
- Search indexes MUST remain disposable and reconstructable from
  authoritative persistence.
- Rebuild workflows MUST remain operationally safe, observable and
  resumable.

### Moderation & Search

- Moderation state MUST influence indexing visibility, search ranking and
  search eligibility.
- Moderated or quarantined content MUST remain filterable and
  authorization-aware.
- Soft-deleted content SHOULD remain operationally reconstructable and
  publicly hidden.

### Search Caching

- Search caching MAY support query acceleration, aggregation reuse and
  autocomplete optimization.
- Caches MUST remain disposable, permission-aware and invalidation-aware.

### Autocomplete & Suggestions

- Autocomplete systems SHOULD remain rate-limited, abuse-resistant and
  permission-aware.
- Autocomplete MUST avoid leaking hidden entities and moderation-sensitive
  content.

### Search Pagination

- Search responses MUST paginate, remain bounded and expose deterministic
  ordering.
- Unbounded search result retrieval is prohibited.

### Search Analytics

- Search analytics MAY include query popularity, failed searches, ranking
  performance and latency metrics.
- Analytics MUST remain privacy-aware and operationally useful.

### Search Abuse Mitigation

- The search subsystem MUST defend against scraping, query flooding,
  wildcard abuse, aggregation abuse and automated harvesting.
- Search rate limits MUST remain configurable, observable and adaptive.

### Search Observability

- The search subsystem MUST expose indexing latency, queue depth, query
  latency, shard health, rebuild progress and failed indexing metrics.
- Operational visibility is mandatory.

### Search Failure Philosophy

- The platform MUST tolerate delayed indexing, partial index outage, shard
  degradation and stale projections.
- Search failure MUST NOT corrupt authoritative persistence or block posting
  workflows.
- The system MUST degrade gracefully.

### Search Scalability

- Search infrastructure MUST support horizontal scaling, distributed
  indexing, partition-aware ingestion and high query concurrency.
- The architecture MUST assume large communities, massive post volumes and
  realtime indexing demand.

### Search API Philosophy

- Search APIs MUST enforce authorization, support pagination, validate
  queries and remain abuse-resistant.
- Search APIs MUST remain operationally bounded and observable.

### Long-Term Information Retrieval Goal

- GPForum search architecture MUST remain scalable, rebuildable,
  permission-aware, operationally sustainable, distributed-safe and
  resilient under extreme data growth.
- Search is a derived retrieval system over authoritative persistence.
- All future search and indexing development MUST comply with this ADR.

## Consequences

- Search stays on PostgreSQL with no extra engine to operate; an external
  engine can only be added later as optional acceleration outside
  request-critical paths.
- Search can lag or fail without blocking posting or corrupting canonical
  data, but results can be stale, and every stale path must still filter
  hidden, quarantined and deleted content.
- Rebuild generations, activation swaps and negative anti-leak contract tests
  are required engineering work, not optional hardening.
- Open conflicts:
  - The example events `post.edited` and `category.visibility_changed` do not
    exist; the code emits `post.updated`, and
    `GPForum::Worker::Handler::SearchIndexing` consumes neither
    `user.suspended` nor any category visibility event.
  - `t/09-prompt-alignment.t` reads `prompt/14.txt` to check the ADR 0099 and
    ADR 0101 alignment markers and will fail once the prompt is deleted.

## Alignment

- ADR 0093 (verifiable invariants), ADR 0094 (accessibility), ADR 0099
  (projection stability), ADR 0101 (search, feed and syndication execution),
  ADR 0090 (PostgreSQL-native search and Perl retrieval).
- ADR 0060 (search APIs), ADR 0061 (Search domain), ADR 0063 (search
  scalability), ADR 0082 (SEO and public discovery), ADR 0056 (workers and
  queues), ADR 0067 (cache decision).
- ADR 0030 (discovery reader limits).
- `lib/GPForum/Service/Search/DocumentBuilder.pm`,
  `lib/GPForum/Service/Search/Indexer.pm`,
  `lib/GPForum/Service/Search/PermissionEngine.pm`,
  `lib/GPForum/Service/Search/Searcher.pm`,
  `lib/GPForum/Worker/Handler/SearchIndexing.pm`,
  `lib/GPForum/Service/Projection/GenerationManager.pm`.
- `migrations/003_forum_projection.sql` (`search_documents`, GIN and
  `pg_trgm` indexes), `migrations/018_search_product_hardening.sql`.
- `docs/OBSERVABILITY.md`, `docs/PERFORMANCE.md`.
- `t/19-search.t`, `t/15-projection-generation.t`,
  `t/55-security-abuse-hardening.t`, `t/09-prompt-alignment.t`.
