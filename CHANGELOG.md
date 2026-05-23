# Changelog

All notable changes to GPForum are recorded here.

## Unreleased

- Added plugin extension boundaries for manifest validation, registry
  lifecycle, named hook dispatch, observable failure recording, and PostgreSQL
  migration coverage.
- Added import/export portability boundaries for validated import manifests,
  dry-run jobs, legacy id mapping, import failure reporting, privacy-aware
  export manifests, and PostgreSQL migration coverage.
- Added admin authorization management boundaries for role catalogs, scoped role
  bindings, permission review, and audit-backed role changes.
- Added moderation review boundaries for reports, reversible moderation actions,
  suspensions, audit-backed moderation changes, and admin audit browsing.
- Added advanced community feature boundaries for mention extraction,
  bookmarks, reputation ledger events, trust score snapshots, and rebuildable
  user feed projections.
- Added operations hardening boundaries for rate limiting, metrics snapshots,
  runbook validation, runtime sizing validation, and a JSON metrics endpoint.
- Added attachment upload intent, validation, lifecycle persistence, links,
  variants, scanning hook, media processing hook, and PostgreSQL migration.
- Added bounded keyset pagination contracts for category thread lists and
  thread post lists, including limit-plus-one fetching, stable cursors, and
  pagination metadata.
- Added process-local realtime websocket boundaries for authenticated
  connections, authorized channel subscriptions, thread updates, notification
  badge broadcasts, and explicit polling fallback.
- Added PostgreSQL-native search service boundaries for document building,
  indexing, rebuild, permission-aware querying, autocomplete, lag observation,
  and worker handoff.
- Added GitHub project success surface: CI, hygiene workflow, Dependabot,
  issue templates, pull request template, security policy, contributing guide,
  governance notes, support policy, roadmap, changelog, and ADR template.
- Added notification subscriptions, preferences, inbox projection, read state,
  and fanout services.
- Added worker phase boundaries, outbox dispatch, projection tracking, and
  platform governance migrations.
- Added core identity/session, forum write, event/audit, and projection schema
  foundations.
