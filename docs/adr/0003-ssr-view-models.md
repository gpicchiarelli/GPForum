# ADR 0003: SSR View Models

## Status

Accepted.

## Context

GPForum controllers were staying thin for authorization and workflow calls, but
they still shaped large SSR and JSON payload hashes directly. Forum, admin,
moderation, identity, community, privacy, attachment, and discovery controllers
repeated row-to-hash mapping, profile labels, metadata lists, notification
presentation, pagination payloads, and form error metadata.

That made controllers harder to scan and increased the risk of DBIx::Class row
objects leaking into templates as the SSR surface grows.

## Decision

Introduce dedicated presentation view models under `GPForum::ViewModel::*`.
Controllers remain HTTP-oriented: they authorize, rate-limit, call application
services, choose response status, and render or redirect. View models own
serialization-safe payload shaping for SSR templates and JSON-compatible
responses.

Current presenter groups:

- `GPForum::ViewModel::Forum::Presenter` is the public facade. Row hashes live
  in `Forum::Rows`, page assembly in `Forum::Page`, and new-thread form state
  in `Forum::Form`.
- `GPForum::ViewModel::Community::Presenter` shapes bookmarks and feed items,
  and keeps compatibility delegates for notification surfaces.
- `GPForum::ViewModel::Notifications::Presenter` shapes notification inbox
  rows, mention rows, localized notification presentation, and stable
  notification heading metadata.
- `GPForum::ViewModel::Admin::Presenter` shapes roles, permissions, bindings,
  audit rows, dashboard summaries, and stable audit metadata items.
- `GPForum::ViewModel::Attachment::Presenter` shapes upload response payloads
  and download links.
- `GPForum::ViewModel::Discovery::Presenter` shapes sitemap and Atom feed
  resource rows.
- `GPForum::ViewModel::Moderation::Presenter` shapes report queue rows,
  moderation actions, suspensions, reversibility metadata, and pagination state.
- `GPForum::ViewModel::Identity::Presenter` shapes auth form state and public
  profile payloads.
- `GPForum::ViewModel::Privacy::Presenter` shapes user privacy dashboards,
  staff review queues, export manifests, deletion requests, retention holds,
  erasure jobs, and deletion review responses.

The existing `GPForum::View::Presenter` continues to provide small reusable UI
primitives such as actions and badges. View models sit one level above those
primitives and prepare page/domain payloads.

## Consequences

Templates receive plain Perl hashes and arrays, not DBIx::Class results.
Controllers no longer keep large `_thread_hash`, `_post_hash`, `_audit_hash`,
or similar mappers. Presentation-specific metadata such as heading ids,
permalink anchors, form described-by targets, and localized notification labels
is prepared in one place.

View models must not perform persistence writes or contain HTML templates. When
they need localized strings, they call presentation/rendering services already
owned by the UI boundary. Future presenters should preserve public JSON fields
unless an API change is explicitly accepted.

## Alternatives Rejected

- Keep row-to-hash mapping in controllers: rejected because controllers became
  harder to audit and duplicated presentation logic across routes.
- Pass DBIx::Class rows directly to templates: rejected because templates should
  consume stable plain data and avoid accidental persistence-layer coupling.
- Put HTML rendering in services: rejected because services should remain usable
  by SSR, JSON, workers, and tests without template concerns.
