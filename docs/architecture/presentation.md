# Presentation Architecture

GPForum keeps SSR presentation in three layers:

- controllers collect input, enforce auth/CSRF/rate-limit decisions, call
  services, and choose HTTP status or redirects;
- `GPForum::ViewModel::*::Presenter` modules shape plain Perl hashes for SSR
  templates and JSON-compatible responses;
- `GPForum::Web::ErrorPayload` centralizes repeated HTTP error hashes while
  leaving rendering and status-code decisions in controllers;
- `GPForum::Web::Responder` owns JSON/HTML content negotiation, SSR payload
  rendering, public HTML cache hand-off, and current-user session lookup so
  controllers do not duplicate those helpers;
- `GPForum::Web::HealthPayload` and `GPForum::Web::RealtimePayload` centralize
  technical JSON message contracts for health endpoints and websocket control
  frames;
- `GPForum::Web::RealtimeAccess` owns websocket origin matching, payload size,
  `user`-scope connect/subscribe rate-limit hashes, and plaintext handshake
  texts without rendering handshake errors;
- `GPForum::Web::HomeAccess` owns home reader limits and the custom
  `home_unavailable` 500 contract without using `Web::Guard`;
- `GPForum::Web::CookieSession` owns cookie-session presence, the 30-day
  login lifetime, and login-value assembly without validating store rows;
- `GPForum::Web::IdentityAccess` owns identity CSRF plaintext, identity_http
  rate-limit hashes, public-profile thread limits, locale/theme
  preference-cookie names, and related JSON/text error contracts without
  using `Web::Guard`;
- `GPForum::Web::DiscoveryAccess` owns sitemap/feed reader limits and
  crawler document rendering without using `Web::Guard` or `Web::Responder`;
- `GPForum::Web::ForumAccess` owns forum rate-limit hashes, report field
  errors, search page and autocomplete limits, list page defaults, community
  target types, community write-success statuses, search filter names, and
  integer limits without using `Web::Guard`;
- `GPForum::Web::AttachmentAccess` owns attachment upload rate-limit hashes,
  filename sanitizing, and Guard payloads without rendering responses;
- `GPForum::Web::NotificationAccess` owns inbox/mention page limits and the
  notification write rate-limit hash without using `Web::Guard`;
- `GPForum::Web::ModerationAccess` owns report-queue limits, default filters,
  permission action and resource names, write-success statuses, and
  permission-target hashes without rendering responses;
- `GPForum::Web::PrivacyAccess` owns privacy list limits, manage/view
  actions, review write-success statuses, permission-target hashes, and
  blocked-hold Guard payloads without rendering responses;
- `GPForum::Web::AdminAccess` owns catalog page limits, the dashboard row
  cap, manage/view actions, catalog and binding write-success statuses,
  permission-target hashes, and invalid-request Guard payloads without
  rendering responses;
- `GPForum::Web::OperationsAccess` owns `/metrics` token matching and the
  unauthorized JSON payload without rendering responses;
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

- Forum: `ViewModel::Forum::Rows` shapes categories, threads, posts, search,
  autocomplete, and reports; `ViewModel::Forum::Page` assembles pages,
  summaries, and mutation responses; `ViewModel::Forum::Form` owns new-thread
  field descriptors. `ViewModel::Forum::Presenter` remains the public facade.
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
