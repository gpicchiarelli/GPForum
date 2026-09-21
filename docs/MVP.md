# GPForum MVP HTTP Surface

This document describes what is currently wired as a traversable forum surface.
It is intentionally narrower than the full architectural contract.

## Available Routes

Every route below is registered in `lib/GPForum/Bootstrap/Routes.pm`. Read
routes render SSR by default and return JSON on request; every state-changing
route requires an authenticated session and a CSRF token unless stated
otherwise.

### Home and discovery

* `GET /` renders the public forum home index with visible categories and latest public discussions.
* `GET /robots.txt` renders crawler policy.
* `GET /sitemap.xml` renders public category/thread sitemap XML.
* `GET /feed.atom` renders a public Atom feed.
* `GET /search?q=...` renders PostgreSQL-native search results.
* `GET /search/autocomplete?q=...` returns bounded PostgreSQL-native autocomplete suggestions.
* `GET /legal/terms` renders the terms document.
* `GET /legal/privacy` renders the privacy document.
* `GET /legal/cookies` renders the cookie document.

### Forum reading

* `GET /categories` renders visible categories.
* `GET /c/:category_id` renders one category and a keyset-paginated thread list.
* `GET /t/:thread_id` renders one visible thread and keyset-paginated posts.
* `GET /t/:thread_id/:slug` renders the same visible thread through its canonical public URL.
* `GET /new-thread` renders the thread form with a CSRF token.

### Forum writing

* `POST /threads` creates a thread for an authenticated session user.
* `POST /t/:thread_id/edit` edits a thread title and slug through `Forum::Write`.
* `POST /t/:thread_id/delete` soft-deletes a thread through `Forum::Write`.
* `POST /t/:thread_id/restore` restores a soft-deleted thread through `Forum::Write`.
* `POST /t/:thread_id/move` moves a thread to another category through `Forum::Write`.
* `POST /t/:thread_id/replies` creates a reply for an authenticated session user.
* `POST /p/:post_id` edits a post body and records a revision.
* `POST /p/:post_id/delete` soft-deletes a post through `Forum::Write`.
* `POST /p/:post_id/restore` restores a soft-deleted post through `Forum::Write`.
* `POST /t/:thread_id/read` records per-user thread reading progress.

### Attachments

* `POST /p/:post_id/attachments` uploads an attachment against a post through the upload pipeline.
* `POST /p/:post_id/attachments/:attachment_id/delete` deletes a post attachment through the attachment lifecycle.
* `GET /attachments/:attachment_id/download` serves an attachment after a `DownloadAccess` permission check.

### Community

* `GET /feed` renders the authenticated user's derived personal feed.
* `GET /bookmarks` renders the authenticated user's saved thread bookmarks.
* `POST /t/:thread_id/bookmark` saves or restores a bookmark for a thread.
* `POST /t/:thread_id/bookmark/remove` soft-removes a thread bookmark.
* `POST /t/:thread_id/subscribe` follows a thread for notifications.
* `POST /t/:thread_id/subscribe/mute` mutes a followed thread.
* `POST /t/:thread_id/subscribe/remove` unfollows a thread.
* `GET /u/:username` renders a public-safe contributor profile.

### Reports

* `POST /t/:thread_id/report` creates a moderation report for a visible thread.
* `POST /p/:post_id/report` creates a moderation report for a visible post.
* `POST /u/:username/report` creates a moderation report for a public profile.

### Notifications

* `GET /notifications` renders the authenticated user's notification inbox.
* `POST /notifications/:notification_id/read` marks one notification as read.
* `POST /notifications/read-all` marks every unread notification as read.
* `GET /mentions` renders the authenticated user's mention history.

### Realtime

* `WEBSOCKET /realtime` opens the process-local realtime stream; clients fall back to polling when it is unavailable.

### Identity

* `GET /register` renders the registration form with a CSRF token.
* `POST /register` creates a pending account and issues an email verification token.
* `GET /login` renders the login form with a CSRF token.
* `POST /login` opens a server-side session for a verified account.
* `POST /logout` revokes the current session.
* `GET /password/reset` renders the forgot-password form.
* `POST /password/reset` issues a single-use password reset token.
* `GET /password/reset/:token` renders the reset form for a valid token.
* `POST /password/reset/complete` consumes the token, rotates the credential, and revokes sessions.
* `GET /email/verify` renders the verification resend form.
* `POST /email/verify/request` issues a single-use email verification token.
* `GET /email/verify/:token` renders the verification confirmation form.
* `POST /email/verify/complete` consumes the token and activates the account.
* `GET /email/confirm/:token` renders the email-change confirmation form.
* `POST /email/confirm` consumes the token and applies the pending email change.

### Settings

* `GET /settings` renders account, locale, theme, and notification preferences.
* `POST /settings` updates notification preferences.
* `POST /settings/password` changes the password after verifying the current one.
* `POST /settings/email` requests an email change and issues a confirmation token.
* `POST /locale` sets the active locale; guests keep it in a cookie only.
* `POST /theme` sets the active theme; guests keep it in a cookie only.

### Privacy

* `GET /privacy` renders the member privacy dashboard.
* `POST /privacy/export` requests a personal data export bundle.
* `GET /privacy/export/:export_request_id` downloads a completed export bundle.
* `POST /privacy/deletion` requests account or resource deletion.

### Moderation

* `GET /moderation/reports` renders the authorized moderation report queue.
* `GET /moderation/actions` renders keyset-paginated moderation action history.
* `GET /moderation/suspensions` renders active or historical suspension rows.
* `POST /moderation/reports/:report_id/assign` assigns a report to the current moderator.
* `POST /moderation/reports/:report_id/release` releases an assigned report back to the queue.
* `POST /moderation/reports/:report_id/resolve` resolves a report with an explicit resolution.
* `POST /moderation/posts/:post_id/hide` hides a post through `ActionStore`.
* `POST /moderation/posts/:post_id/restore` restores a hidden post through `ActionStore`.
* `POST /moderation/threads/:thread_id/hide` hides a thread through `ActionStore`.
* `POST /moderation/threads/:thread_id/restore` restores a hidden thread through `ActionStore`.
* `POST /moderation/threads/:thread_id/lock` locks a thread through `ActionStore`.
* `POST /moderation/threads/:thread_id/unlock` unlocks a thread through `ActionStore`.
* `POST /moderation/actions/:action_id/reverse` records reversal of a moderation action.
* `POST /moderation/users/:user_id/suspend` suspends a user through `SuspensionStore`.
* `POST /moderation/suspensions/:suspension_id/revoke` revokes a user suspension.

### Administration

* `GET /admin` renders the authorized admin dashboard.
* `GET /admin/users` renders a bounded, status-filterable member list.
* `GET /admin/roles` renders role and permission catalogs.
* `POST /admin/roles` creates a role through `Admin::Workflow` and `RoleCatalog`.
* `POST /admin/permissions` creates a permission through `Admin::Workflow` and `RoleCatalog`.
* `POST /admin/roles/:role_id/permissions` attaches a permission to a role.
* `GET /admin/users/:user_id/roles` reviews active role bindings for one user.
* `POST /admin/users/:user_id/roles` creates a scoped role binding.
* `POST /admin/role-bindings/:binding_id/revoke` revokes a role binding.
* `GET /admin/categories` renders the category catalog.
* `POST /admin/categories` creates a category through `Admin::Workflow` and `CategoryStore`.
* `POST /admin/categories/:category_id` updates a category through `Admin::Workflow` and `CategoryStore`.
* `GET /admin/audit` renders bounded admin audit review.
* `GET /admin/jobs` renders bounded asynchronous job state with an optional status filter.
* `GET /admin/status` renders the operations status snapshot from `ConsoleReader`.
* `GET /admin/privacy` renders the staff data-rights review queue.
* `POST /admin/privacy/deletions/:request_id/approve` approves a deletion request and enqueues the erasure job.
* `POST /admin/privacy/deletions/:request_id/hold` places a retention legal hold on a deletion request.
* `POST /admin/privacy/erasure/:job_id/run` runs an approved erasure job.

### Operations

* `GET /health` returns a config/runtime health summary as JSON.
* `GET /health/live` returns liveness as JSON, with no dependency checks.
* `GET /health/ready` returns readiness as JSON and a non-`200` status when a dependency check fails.
* `GET /metrics` returns the metrics snapshot, gated by an application-level token.

Read endpoints render semantic SSR by default. They also return JSON when the
client sends `Accept: application/json` or `?format=json`, using the same
controller/service path without changing the command/read boundaries.

The admin surface is an operational MVP, not a full back-office suite. It is
permission-gated through `PermissionGate`, writes through `Admin::Workflow`
into `RoleCatalog` and `RoleBindingStore`, and reviews state through
`PermissionReview` and `AuditReview`. Role binding changes are CSRF-protected
and audit-backed. The
initial operator path is now explicit and repeatable:
`bin/gpforum-admin-bootstrap --user-id USER_ID` creates the owner role,
default admin/moderation permissions, role-permission links, and a global role
binding idempotently.

The root home route uses `HomePageReader` to compose visible categories and
latest public threads through existing reader boundaries. It is SSR/JSON,
keyset-paginated for latest discussions, and deliberately avoids direct
DBIx::Class resultset manipulation in the controller.

Forum form submissions are SSR-friendly: successful thread creation redirects
to the new thread, and successful reply creation redirects to the created post
anchor. API-style clients still receive JSON by sending `Accept:
application/json`.

Authenticated thread pages include read-continuity metadata: last read position,
first unread post anchor, unread count for the current page, and a CSRF-protected
form to mark visible posts as read. The read marker model is compressed to one
row per `(user_id, thread_id)` plus a coalescable delta table for future
asynchronous consolidation.

Public contributor profiles expose only safe identity and contribution data:
display name, public username, trust snapshot, and public visible discussion
links. The profile path uses `ProfileReader`, filters deleted or suspended users,
and keyset-paginates recent public threads without exposing private account
fields.

Authenticated thread pages also include community-continuity controls: save
bookmark, remove bookmark, follow, mute, and unfollow. These controls are
server-rendered, keyboard-accessible, CSRF-protected, and backed by existing
`BookmarkStore` and `SubscriptionStore` service boundaries. Bookmark listing
uses keyset pagination and no `OFFSET`.

Authenticated users can report visible threads and posts directly from the
thread page. Report creation is CSRF-protected, rate-limited, and backed by
`ReportStore`. The store persists the report and emits append-only event, audit,
and outbox rows so moderation intake is observable and asynchronously
projectable without making UI state authoritative.

Authorized moderators can traverse `/moderation/reports` to review the report
queue, assign reports, and resolve reports. Report assignment and resolution
go through `Moderation::Workflow`. The moderation controllers use
`PermissionGate`, which checks PostgreSQL role bindings and permissions rather
than trusting a session flag. Report assignment and resolution are CSRF-protected
and emit append-only transition events, audit rows, and outbox handoffs.
Moderation review now includes read-only history pages. `/moderation/actions`
uses `ReviewReader` to expose a keyset-paginated action ledger with optional
target filters, and `/moderation/suspensions` exposes active or all suspension
rows with user filtering. These pages are permission-gated, SSR/JSON capable,
and never become authoritative outside PostgreSQL.

Moderation actions are now wired as real HTTP write workflows. Authorized staff
can hide/restore posts, lock/unlock threads, and reverse moderation actions
through CSRF-protected routes. `Moderation::Workflow` is the application
boundary: it validates required fields and delegates to `ActionStore`, which
remains the persistence write boundary. The store updates canonical content
state only inside a PostgreSQL transaction and emits a
moderation action row, domain event, audit row, and transactional outbox
handoff. Locked threads remain readable so archival links and discussion
continuity survive moderation, but `locked_at` keeps reply creation closed.

User suspensions are executable and PostgreSQL-backed. Authorized staff can
create and revoke suspension rows through `Moderation::Workflow` and
`SuspensionStore`, which updates
canonical user status and emits event/audit/outbox records. The forum write path
checks the suspension boundary before publishing workflows, so suspended users
cannot create threads or replies; read-continuity and reporting workflows remain
separate from publishing authority.

Authenticated personal feeds expose the existing `user_feed_items` projection
through `FeedReader`. The route is SSR/JSON, keyset-paginated, and deliberately
derived: it returns item references plus visibility/permission versions, not
authoritative content.

Authenticated notification pages expose the existing notification inbox read
model over SSR/JSON. Mark-read is CSRF-protected and writes through
`Notification::Dispatcher`, preserving the notification read projection rather
than inventing process-local UI state. Inbox entries include joined
notification source/type/payload data so SSR pages and JSON clients can link
back to a related discussion when the dispatcher has that context.

Thread and reply creation record resolved `@username` mentions as derived
community state. The canonical post/thread transaction remains authoritative;
mention recording runs through `MentionStore`, skips unknown/self mentions
explicitly, and degrades with a logged warning instead of corrupting the write
path. Outbox-dispatched `post.created` events can fan out reply notifications
to thread subscribers while excluding the post author. `MentionStore` also
creates mention notifications for resolved mentions, and `/mentions` exposes a
keyset-paginated SSR/JSON history for authenticated users.

Public discovery routes are now traversable. They use `CanonicalUrl`,
`RobotsPolicy`, `SitemapBuilder`, `FeedBuilder`, `CategoryReader`, and
`ThreadReader` rather than controller-local discovery logic. Sitemap and Atom
feed output include only public, visible, non-deleted resources and render safe
excerpts only; search remains disallowed in robots policy to avoid indexing
query result pages.

Visible thread pages now publish permission-safe metadata from
`MetadataBuilder`: canonical URL, robots policy, safe description, and
OpenGraph fields derived only from already-visible thread/post data. Hidden,
deleted, private, or moderated resources remain noindex/no-snippet by policy.

Search autocomplete is exposed as a JSON retrieval endpoint. It goes through
`Searcher`, uses bounded limits, rate limits requests, and returns minimal
suggestions without bodies or snippets so autocomplete cannot become a content
leak surface.

## What Works

The HTTP forum path now follows:

```text
route -> Forum controller -> reader/composer/store service -> DBIx::Class
```

Thread creation and reply creation still delegate persistence to `ThreadStore`
and `PostStore`, so event log, audit log, outbox messages, post bodies,
revisions, and counter deltas remain in the existing transaction boundary.

Thread and post lists use keyset pagination through `PageWindow`; no forum route
uses `OFFSET`.

The SSR forum templates use semantic landmarks, labeled forms, stable post
anchors, accessible pagination navigation, and no JavaScript requirement for
core forum reading.

Bookmarks are soft-deleted and can be restored idempotently for the same
`(user_id, target_type, target_id)` tuple. Thread subscriptions are also
idempotent and can clear muted/revoked state when the user follows the same
thread again. These are continuity tools, not authoritative moderation or
permission records.

`/health/ready` now performs a real lightweight DB readiness check and verifies
that event, outbox, and projection resultsets are reachable.

## Local Limits

Realtime websocket connections remain process-local, but fanout no longer does:
outbox-dispatched domain events emit bounded PostgreSQL `LISTEN/NOTIFY`
messages on `gpforum_domain_events`, and every web process forwards matching
events only to its locally connected websocket clients. PostgreSQL/outbox stays
authoritative; if a process misses NOTIFY while offline or degraded, the
listener falls back to bounded cursor polling over completed outbox rows.
Notification badge fallback is rebuilt from PostgreSQL notification tables, and
clients still receive polling fallback metadata in the websocket handshake.

The rate limiter remains process-local. It is acceptable as a fallback and test
boundary, but a PostgreSQL-backed limiter is the next production-grade step.

The local cache remains process-local and disposable. It is TTL bounded,
max-entry bounded, namespace-aware, tag-invalidatable, and visible through
`/metrics`. It backs read-mostly category lists and anonymous public SSR cache
for category/thread pages with `ETag`, `Last-Modified`, and
`stale-while-revalidate` response headers. Cache invalidation workers derive
tags from authoritative domain events; cached data is never authoritative and is
safe to discard.

Reply position allocation is now owned by `PostStore` inside the canonical write
transaction. The store locks the target thread row with PostgreSQL `FOR UPDATE`,
allocates the next position, and the unique `(thread_id, position)` constraint
remains the final database invariant. A staging PostgreSQL concurrency test for
hot threads is still required before go-live.

Search depends on the `search_documents` projection. If the projection is empty
or unavailable, the HTTP route returns an explicit degraded empty result rather
than using OpenSearch or an external service.

## Commands

Run the full test suite:

```sh
script/test
```

Run Perl::Critic:

```sh
script/perlcritic
```

Run coverage:

```sh
script/coverage
```

Profile a route:

```sh
script/profile-route /categories
nytprofhtml -f var/profile/route-nytprof.out.*
```

Profile an existing Perl command:

```sh
script/profile -Ilib t/32-forum-web.t
```

Apply migrations:

```sh
carton exec perl -Ilib bin/gpforum-migrate --plan
carton exec perl -Ilib bin/gpforum-migrate --apply
```

Bootstrap an initial owner after the target user exists:

```sh
carton exec perl -Ilib bin/gpforum-admin-bootstrap --user-id USER_ID
carton exec perl -Ilib bin/gpforum-admin-bootstrap --user-id USER_ID --actor-user-id OPERATOR_ID --role-name gpforum_owner
```

Start the app:

```sh
carton exec morbo bin/gpforum
```

OS-level tuning flags default to conservative `auto` and are observable through
`/health` and `/metrics`:

```sh
GPFORUM_OS_REUSEPORT=auto
GPFORUM_OS_SENDFILE=auto
GPFORUM_OS_WORKER_PRIORITY=auto
GPFORUM_OS_STATIC_XSENDFILE=auto
GPFORUM_OS_AFFINITY=off
```

Local generated files and disposable cache artifacts should use
`GPForum::OS::Filesystem->write_atomic`, which writes a temporary file in the
same filesystem and promotes it with `rename`.

Socket and process behavior is centralized in `GPForum::OS::Socket` and
`GPForum::OS::Process`. `/health`, `/metrics`, and `script/system-preflight`
surface reuseport/sendfile posture, process-class scheduling recommendations,
event backend, and recommended worker count without making OS-specific tuning
mandatory. `GPForum::Service::Operations::OSPreflight` converts that posture
into ok/degraded/fail checks for readiness and operational metrics. The
thresholds `GPFORUM_OS_MIN_RECOMMENDED_WORKERS` and
`GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS` let deployments make host-capacity
expectations explicit without hard-coding OS assumptions.

Endpoint query budgets are represented by
`GPForum::Service::Operations::QueryBudget` and surfaced through `/metrics`.
They currently cover home, category lists, category thread pages, thread view,
thread/reply creation, and search. They are release-gate contracts for future
instrumented observations rather than runtime query counters. The same service
can synchronize the catalog into `endpoint_query_budgets` and report drift if
the database contract diverges from the executable catalog. The CLI entry point
is `carton exec bin/gpforum-query-budget --print|--sync|--check`. Metrics
expose both the catalog and, when a schema is configured, the drift report used
by readiness. `carton exec bin/gpforum-platform-check` aggregates OS preflight,
the selected operational profile, and optional DB-backed query budget drift
into a single CI/deploy check.

Run outbox workers directly for a bounded batch or supervised loop:

```sh
carton exec bin/gpforum-outbox-dispatch --once --limit 100
carton exec bin/gpforum-outbox-dispatch --loop --limit 100 --sleep 5
```

Start Minion workers after optional Minion PostgreSQL configuration is present:

```sh
GPFORUM_MINION_ENABLED=1 \
GPFORUM_MINION_PG_URL=postgresql://gpforum@/gpforum_minion \
carton exec perl -Ilib bin/gpforum minion worker
```
