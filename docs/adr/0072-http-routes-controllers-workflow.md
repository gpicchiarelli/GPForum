# ADR 0072: HTTP Routes, Controllers and Application Workflow

## Status

Accepted. Converted on 2026-09-19 from `prompt/24.txt` ("GPForum - HTTP
Routes, Controllers & Application Workflow Constitution"); this ADR replaces
the prompt as the binding source.

## Context

Web code needs one contract for the initial route map, controller
responsibilities, request lifecycle, validation rules and application
workflow contracts, so that every mutation passes through the same
authorization, persistence, event and response discipline. The rules are
mandatory for web implementation and govern the HTTP surface of the forum,
identity, subscription and notification, moderation and admin bounded
contexts.

## Decision

### Cross-ADR alignment

- ADR 0094 (accessibility): HTTP workflows that render user-facing pages MUST
  return accessible SSR by default. Forms MUST have labels and associated
  errors, mutating controls MUST be semantic buttons, composer routes MUST
  support keyboard-only use, and no core route may require JavaScript as the
  only path to participation.
- ADR 0100 (domain integrity): HTTP workflows MUST enforce authorization,
  visibility and moderation state before rendering or mutating. Controllers
  MUST remain thin and MUST NOT bypass domain services, event emission, audit
  records, projection updates, cache invalidation, CSRF or anti-leak
  filtering.

### Request philosophy

Every mutating HTTP request MUST follow this order:

1. authenticate where required;
2. authorize;
3. validate input;
4. perform canonical persistence;
5. emit durable events;
6. enqueue asynchronous work where needed;
7. return a safe response.

- Controllers MUST remain thin.
- Business rules MUST live in services, domain workflows or authorization
  policy modules.

### Public routes

- `GET /`: renders forum home or public feed; permission-aware; cache-safe
  for anonymous users.
- `GET /spaces/:space_slug`: renders the space view; lists visible categories
  and recent threads.
- `GET /c/:category_slug`: renders the category thread list; supports
  pagination; filters by permission.
- `GET /t/:thread_id/:slug`: renders the thread view; supports post
  pagination; shows lock/archive/moderation state safely.
- `GET /search`: renders search form and results; permission-aware.

### Identity routes

- `GET /register`: renders the registration form.
- `POST /register`: creates the user; validates credentials; emits
  `user.registered`.
- `GET /login`: renders the login form.
- `POST /login`: validates credentials; creates a session; emits
  `user.logged_in`.
- `POST /logout`: revokes the current session; emits `session.revoked`.
- `GET /u/:username`: renders the public-safe profile.
- `GET /settings`: renders current user settings.
- `POST /settings/profile`: updates profile fields; emits
  `user.profile_updated` if implemented.

### Thread and post routes

- `GET /c/:category_slug/new`: renders the thread composer; requires the
  `thread.create` permission.
- `POST /c/:category_slug/threads`: creates the thread and initial post;
  emits `thread.created` and `post.created`; enqueues search and notification
  workflows.
- `GET /t/:thread_id/reply`: renders the reply composer; requires the
  `thread.reply` permission.
- `POST /t/:thread_id/posts`: creates a post; rejects locked/archived threads
  for normal users; emits `post.created`.
- `GET /posts/:post_id/edit`: renders the edit form; checks `edit_own` or
  `edit_any`.
- `POST /posts/:post_id/edit`: creates a post revision; updates the current
  revision pointer; emits `post.edited`.
- `POST /posts/:post_id/delete`: soft-deletes the post where policy allows;
  emits `post.hidden` or `post.deleted_soft`.

### Subscription routes

- `POST /subscriptions`: creates a subscription; validates target visibility;
  emits `subscription.created` if implemented.
- `DELETE /subscriptions/:id`: revokes the subscription; emits
  `subscription.revoked` if implemented.
- `GET /notifications`: renders the notification list.
- `POST /notifications/:id/read`: marks the notification read; emits
  `notification.read`.

### Moderation routes

- `POST /reports`: creates a content report; emits `report.created`.
- `GET /moderation/reports`: renders the moderation queue; requires
  `report.view_queue`.
- `POST /moderation/reports/:id/resolve`: resolves the report; emits
  `report.resolved`.
- `POST /moderation/threads/:id/lock`: locks the thread; emits
  `thread.locked`.
- `POST /moderation/threads/:id/move`: moves the thread; emits
  `thread.moved`.
- `POST /moderation/posts/:id/hide`: hides the post; emits `post.hidden`.
- `POST /moderation/posts/:id/restore`: restores the post; emits
  `post.restored`.
- `POST /moderation/users/:id/suspend`: suspends the user; emits
  `user.suspended`.

### Admin routes

- `GET /admin`: renders the admin dashboard; requires
  `admin.view_dashboard`.
- `GET /admin/audit`: renders the audit log; requires `admin.view_audit_log`.
- `GET /admin/roles`: renders role management; requires `admin.manage_roles`.
- `POST /admin/roles/bindings`: creates a scoped role binding; emits
  `role_binding.created` if implemented.

### Response rules

- HTML responses MUST be server-rendered.
- HTMX responses MAY return fragments.
- API-style responses MUST include: success or error state; a safe message;
  `correlation_id` where available.
- Errors MUST NOT leak: SQL; stack traces; internal paths; secret values;
  infrastructure topology.

## Consequences

- A single request order for every mutation makes authorization, audit,
  event and outbox behavior reviewable route by route; controllers stay
  replaceable because rules live in services and policy modules.
- The route inventory is the reference for permission names (ADR 0070) and
  emitted events (ADR 0071); adding or renaming a route requires updating
  this ADR under the alignment gate of ADR 0087.
- Open conflicts: the implemented route map in
  `lib/GPForum/Bootstrap/Routes.pm` diverges from the inventory above, and
  either the routes or this ADR must be reconciled:
  - categories are addressed as `/c/:category_id`; `/spaces/:space_slug` is
    not routed;
  - thread creation uses `GET /new-thread` and `POST /threads`; replies use
    `POST /t/:thread_id/replies` and there is no `GET /t/:thread_id/reply`;
  - `GET|POST /posts/:post_id/edit`, `POST /posts/:post_id/delete` and
    `POST /moderation/threads/:id/move` are not routed;
  - subscriptions use `POST /t/:thread_id/subscribe`, `/subscribe/mute` and
    `/subscribe/remove` instead of `/subscriptions`;
  - reports use `POST /p/:post_id/report`, `/t/:thread_id/report` and
    `/u/:username/report` instead of `POST /reports`;
  - profile updates use `POST /settings`; role bindings use
    `POST /admin/users/:user_id/roles`;
  - JSON error bodies from `GPForum::Web::ErrorPayload` carry `status`,
    `error` and `title`; the correlation id travels only in the
    `X-Request-ID` response header.

## Alignment

- ADRs: 0094 and 0100 (cross-alignment), 0070 (permission matrix), 0071
  (event catalog), 0073 (UX), 0085 (API contracts); 0005 (posting workflow),
  0016 (shared HTTP access), 0026 (home page access), 0041 (forum access),
  0044 (moderation access), 0046 (admin access).
- Code: `lib/GPForum/Bootstrap/Routes.pm`, `lib/GPForum/Controller/`,
  `lib/GPForum/Web/Access.pm`, `lib/GPForum/Web/Guard.pm`,
  `lib/GPForum/Web/ErrorPayload.pm`.
- Tests: `t/32-forum-web.t`, `t/35-forum-accessible-ssr.t`,
  `t/61-mvp-user-flow.t`, `t/76-web-error-payload.t`,
  `t/91-forum-controllers.t`, `t/integration/postgres.t`.
- Docs: `API.md`, `EVENTS.md`, `docs/architecture/web-access.md`.
