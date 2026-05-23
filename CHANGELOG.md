# Changelog

All notable changes to GPForum are recorded here.

## Unreleased

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
