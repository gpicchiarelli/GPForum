# GPForum Product Flows

Date: 2026-05-24.

This document records commit 5 product-flow completion. The scope is deliberately
limited to workflows already present in the repository. No social-network layer,
plugin marketplace, external service, Redis dependency, OpenSearch dependency,
or SPA-first architecture is introduced here.

## Flow Status

| Flow | Status | Controller | Service boundary | Tests | Notes |
| --- | --- | --- | --- | --- | --- |
| Registration | complete | `Identity` | `Identity::Registration`, `Identity::Store` | `t/06-identity-web.t`, `t/07-registration-service.t`, `t/08-identity-store.t` | Creates schema-compatible user and password credential rows, emits event/audit, and returns non-enumerative duplicate errors. |
| Login/logout | complete | `Identity` | `Identity::Store`, `Password`, `SessionToken`, `Identity::SecurityAudit` | `t/06-identity-web.t`, `t/08-identity-store.t`, `t/50-security-hardening.t` | Verifies Argon2id credentials, creates server-side session rows, rotates cookie-session identity, revokes server-side sessions on logout, and audits login/logout requests. |
| Public profile | complete | `Identity` | `Identity::ProfileReader` | `t/06-identity-web.t`, `t/42-profile-reader.t` | Public-safe profile view hides private email and exposes contributor summary plus public discussions. |
| Categories | complete | `Forum` | `Forum::CategoryReader` | `t/31-forum-http-readers.t`, `t/32-forum-web.t`, `t/35-forum-accessible-ssr.t` | Lists and finds non-deleted categories with bounded limits and disposable local cache support. |
| Thread listing/show | complete | `Forum` | `ThreadReader`, `ThreadDetailReader`, `PostReader`, `PageWindow` | `t/21-forum-pagination.t`, `t/31-forum-http-readers.t`, `t/32-forum-web.t` | Uses keyset pagination, explicit visibility/moderation filters, and post body separation. |
| Thread/reply creation | complete | `Forum` | `ThreadComposer`, `ThreadStore`, `PostComposer`, `PostStore`, `PostPosition` | `t/11-forum-thread.t`, `t/12-forum-post.t`, `t/32-forum-web.t` | Writes canonical thread/post/body/revision/counter/event/audit/outbox records through existing store boundaries. |
| Read-state | complete | `Forum` | `Forum::ReadState` | `t/41-thread-read-state.t`, `t/32-forum-web.t` | Marks thread read state through CSRF/authenticated POST and returns keyset-safe reading summary. |
| Bookmark | complete | `Forum` | `Community::BookmarkStore` | `t/24-advanced-community.t`, `t/32-forum-web.t` | Supports save, restore, remove, status, and user listing. |
| Subscription | complete | `Forum` | `Notification::SubscriptionStore` | `t/17-notifications.t`, `t/32-forum-web.t` | Supports subscribe, mute, revoke, restore, status, and fanout recipient discovery. |
| Notifications | complete | `Notifications` | `Notification::Dispatcher` | `t/17-notifications.t`, `t/32-forum-web.t` | Lists inbox, marks read, and now returns coherent `404` for missing notification inbox rows. |
| Mentions | complete | `Notifications`, `Forum` | `MentionExtractor`, `MentionStore`, `MentionReader` | `t/24-advanced-community.t`, `t/32-forum-web.t` | Extracts unique mentions, skips unknown/self mentions, creates mention notifications, and exposes recipient inbox. |
| Reports | complete | `Forum`, `Moderation` | `Moderation::ReportStore` | `t/25-moderation-review.t`, `t/32-forum-web.t`, `t/43-moderation-web.t` | Authenticated users can report threads/posts; moderators can assign and resolve reports. |
| Moderation | complete | `Moderation` | `ActionStore`, `ReportStore`, `SuspensionStore`, `ReviewReader` | `t/25-moderation-review.t`, `t/43-moderation-web.t`, `t/50-security-hardening.t` | Covers queues, action history, hide/restore, lock/unlock, reverse, suspend, and revoke. |
| Admin roles/permissions | complete | `Admin` | `RoleCatalog`, `RoleBindingStore`, `PermissionReview`, `PermissionGate`, `AuditReview` | `t/26-admin-authorization.t`, `t/44-admin-web.t`, `t/50-security-hardening.t` | Authorization distinguishes `401` anonymous from `403` permission denied and keeps writes CSRF-protected. |
| Search | complete | `Forum` | `Search::Searcher` | `t/19-search.t`, `t/32-forum-web.t` | PostgreSQL-native derived search and autocomplete remain visibility/permission-aware and bounded. |
| Public feed | complete | `Discovery` | `FeedBuilder`, `ThreadReader`, `VisibilityPolicy` | `t/30-public-discovery.t`, `t/32-forum-web.t` | Atom feed exposes only public visible excerpts, not full private/moderated content. |
| Sitemap/robots/canonical metadata | complete | `Discovery`, `Forum` | `SitemapBuilder`, `RobotsPolicy`, `CanonicalUrl`, `MetadataBuilder` | `t/30-public-discovery.t`, `t/32-forum-web.t` | Public discovery is canonical, noindex-safe for restricted content, and excludes hidden/deleted resources. |
| Realtime | partial | `Realtime` | `Realtime::Hub`, `ConnectionRegistry`, `ChannelAuthorizer` | `t/20-realtime.t` | Existing process-local websocket layer is intentionally unchanged in this commit. Advanced realtime remains outside product-flow completion. |
| Worker delivery | partial | workers | Minion registrar and handler boundaries | `t/16-workers-phase.t` | Worker placeholders are operationally registered; full async delivery semantics remain later stabilization work. |

## Completion Rules Applied

* Controllers remain thin and delegate workflow work to service boundaries.
* CSRF is enforced on every current POST route.
* Anonymous protected reads/writes return `401`.
* Authenticated users without permission return `403`.
* Missing resources return `404` where the workflow can distinguish absence.
* User-facing identity failures avoid account enumeration.
* Search, feed, sitemap, metadata, notifications, and autocomplete remain
  permission/moderation safe.
* Pagination remains keyset-based and now ignores malformed cursors rather than
  letting them become request-path failures.

## Residual Risk Register

| Area | Risk | Current mitigation | Priority |
| --- | --- | --- | --- |
| Email verification | Registration creates login-capable accounts before a full verification workflow exists. | Account state is explicit and email verification columns already exist. | medium |
| Multi-process rate limiting | PostgreSQL-backed limiter exists; local memory remains degraded fallback. | `/metrics` exposes primary failures, fallback usage and blocked decisions. | low |
| Realtime fanout | Websocket state is process-local. | Realtime is enhancement-only and canonical writes do not depend on it. | medium |
| Worker placeholders | Some Minion tasks are registered placeholders. | Outbox, dispatcher, and handler boundaries already exist; placeholders are observable. | medium |
| Rich content rendering | Safe rendered body boundary is trusted by templates. | Tests preserve escaping/sanitized-body contract. | high before rich renderer |

## Commands

```sh
carton exec prove -lr t/06-identity-web.t t/07-registration-service.t t/08-identity-store.t
carton exec prove -lr t/17-notifications.t t/21-forum-pagination.t t/31-forum-http-readers.t t/32-forum-web.t
carton exec prove -lr t
script/perltidy-check
script/perlcritic --severity 5
script/architecture-check
script/query-plan-check
```

Result:

* product-flow test set passed: 7 files, 390 tests;
* full test suite passed: 55 files, 2738 tests;
* `script/perltidy-check` passed;
* `script/perlcritic --severity 5` passed;
* `script/architecture-check` passed;
* `script/query-plan-check` passed with 23 indexed query plans and 0
  `OFFSET` violations.

`script/query-budget --check` still requires the PostgreSQL test runtime and
`DBD::Pg` in the local Carton tree.

## Next Product Priorities

1. Add email verification workflow on top of the existing identity schema.
2. Replace worker placeholder tasks with real outbox-driven handlers in priority
   order: search indexing, notification dispatch, cache invalidation.
3. Run PostgreSQL-backed rate-limit evidence against a seeded database.
4. Expand SSR form tests for admin/moderation happy-path redirects, not only
   JSON responses.
5. Add fixture-backed browser walkthrough for register -> login -> thread ->
   reply -> notification using a real PostgreSQL test database.
