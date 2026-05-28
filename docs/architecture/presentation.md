# Presentation Architecture

GPForum keeps SSR presentation in three layers:

- controllers collect input, enforce auth/CSRF/rate-limit decisions, call
  services, and choose HTTP status or redirects;
- `GPForum::ViewModel::*::Presenter` modules shape plain Perl hashes for SSR
  templates and JSON-compatible responses;
- `GPForum::Web::ErrorPayload` centralizes repeated HTTP error hashes while
  leaving rendering and status-code decisions in controllers;
- `GPForum::Web::HealthPayload` and `GPForum::Web::RealtimePayload` centralize
  technical JSON message contracts for health endpoints and websocket control
  frames;
- `GPForum::Web::OperationsPayload` and `GPForum::Web::DiscoveryPayload`
  centralize metrics and crawler/feed document contracts without moving HTTP
  rendering into services;
- `templates/components/*.html.ep` render reusable semantic HTML primitives.

View models accept DBIx::Class-like rows and plain hashes through
`GPForum::ViewModel::Base`. Returned payloads must not contain blessed result
objects. Stable UI metadata such as heading ids, field ids, anchors, and
reversibility flags belongs in `ui` hashes.
When a metadata value becomes a DOM id, presenters use the shared `stable_id`
helper so IDs stay deterministic and safe even when sourced from operational
rows such as users, outbox messages, dead letters, privacy requests, or
attachments.
Mutation response hashes belong in the same presenter boundary. Controllers
still decide HTTP success, failure, redirect, and content negotiation, but
presenters own stable JSON-compatible shapes such as admin role responses and
moderation action responses.

Current presenter boundaries:

- Forum: categories, threads, posts, search, autocomplete, reporting, reading,
  engagement, new-thread JSON field compatibility, SSR form descriptors, and
  create/report/read-marker mutation responses.
- Community: bookmarks and feed, while notification methods delegate to the
  dedicated Notifications presenter for compatibility; bookmark and
  subscription mutation responses also live here.
- Notifications: inbox rows, mentions, localized notification presentation, and
  notification-specific heading metadata, plus mark-read response payloads.
- Admin: dashboard, roles, user-role bindings, users, audit rows, async jobs,
  dead letters, operations status payloads, and role/permission mutation
  response payloads.
- Moderation: reports, action history, suspension queues, and action form
  control ids, plus moderation action/report/suspension mutation responses.
- Identity: login/register form fields, error-summary wiring, profile payloads,
  account settings payloads, and public activity metadata.
- Privacy, Attachments, and Discovery: SSR/JSON payloads for their product
  surfaces, including privacy workflow and attachment upload mutation responses.

Services must not render HTML. The only exception is already-sanitized post body
HTML produced by the forum read model and passed through by the presenter.
