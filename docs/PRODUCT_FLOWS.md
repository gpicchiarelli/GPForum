# GPForum Product Flows

Date: 2026-05-24.

This document records commit 5 product-flow completion. The scope is deliberately
limited to workflows already present in the repository. No social-network layer,
plugin marketplace, external service, Redis dependency, OpenSearch dependency,
or SPA-first architecture is introduced here.

## Flow Status

| Flow | Status | Controller | Service boundary | Tests | Notes |
| --- | --- | --- | --- | --- | --- |
| Registration | complete | `Identity` | `Identity::Workflow`, `Identity::Registration`, `Identity::Store`, `Identity::RegistrationStore`, `Identity::Mailer` | `t/06-identity-web.t`, `t/07-registration-service.t`, `t/08-identity-store.t`, `t/103-identity-workflow.t`, `t/112-identity-registration-store.t`, `t/146-identity-mailer.t`, `t/147-identity-email-verification.t` | Creates a pending user and password credential, emits event/audit, sends a verification message through `Identity::Mailer`, and returns non-enumerative duplicate errors. |
| Login/logout | complete | `Identity` | `Identity::Workflow`, `Identity::Store`, `Identity::AuthStore`, `Identity::AccountStore`, `Web::CookieSession`, `Password`, `SessionToken`, `Identity::SecurityAudit` | `t/06-identity-web.t`, `t/08-identity-store.t`, `t/50-security-hardening.t`, `t/70-bootstrap-identity.t`, `t/103-identity-workflow.t`, `t/110-identity-account-store.t`, `t/111-identity-auth-store.t`, `t/114-web-cookie-session.t`, `t/147-identity-email-verification.t` | Verifies Argon2id credentials, creates server-side session rows, rotates cookie-session identity through `Web::CookieSession`, revokes server-side sessions on logout, completes password/email commands through the account store, and audits login/logout requests. Pending members do not receive a session until email verification; already-active bootstrap admins do not need `email_verified_at`. |
| Email lifecycle | complete | `Identity::Password`, `Identity::Email`, `Identity::Verification` | `Identity::Workflow`, `Identity::Mailer`, `Identity::AccountStore` | `t/06-identity-web.t`, `t/110-identity-account-store.t`, `t/146-identity-mailer.t`, `t/147-identity-email-verification.t` | Sends password-reset, email-change, and registration-verification mail from `GPFORUM_MAIL_*` (test transport in development, sendmail in staging/production, optional SMTP). Raw tokens are mailed then stripped from the workflow result and are never logged. Delivery is synchronous at the workflow boundary and is not outbox-queued. |
| Public profile | complete | `Identity` | `Identity::ProfileReader` | `t/06-identity-web.t`, `t/42-profile-reader.t` | Public-safe profile view hides private email and exposes contributor summary plus public discussions. |
| Member settings | complete | `Identity::Settings` | `Identity::Workflow`, `Identity::PreferenceStore`, `Notification::Workflow`, `Notification::PreferenceStore` | `t/66-locale-preference.t`, `t/80-settings-web.t`, `t/103-identity-workflow.t`, `t/107-notification-workflow.t`, `t/109-identity-preference-store.t` | Authenticated members persist locale, theme, and notification channels through dedicated write workflows; cookies and session rotation stay HTTP. |
| Categories | complete | `Forum` | `Forum::CategoryReader` | `t/31-forum-http-readers.t`, `t/32-forum-web.t`, `t/35-forum-accessible-ssr.t` | Lists and finds non-deleted categories with bounded limits and disposable local cache support. |
| Thread listing/show | complete | `Forum` | `ThreadReader`, `ThreadDetailReader`, `PostReader`, `PageWindow` | `t/21-forum-pagination.t`, `t/31-forum-http-readers.t`, `t/32-forum-web.t` | Uses keyset pagination, explicit visibility/moderation filters, and post body separation. |
| Thread/reply creation | complete | `Forum` | `PostingWorkflow`, `ThreadComposer`, `ThreadStore`, `PostComposer`, `PostStore`, `CommandIdempotency` | `t/11-forum-thread.t`, `t/12-forum-post.t`, `t/32-forum-web.t`, `t/87-command-idempotency.t` | Writes canonical thread/post/body/revision/counter/event/audit/outbox records through existing store boundaries; supplied idempotency keys replay completed retries and reject mismatched payloads. |
| Read-state | complete | `Forum` | `Forum::ReadState` | `t/41-thread-read-state.t`, `t/32-forum-web.t` | Marks thread read state through CSRF/authenticated POST and returns keyset-safe reading summary. |
| Bookmark | complete | `Forum` | `Community::BookmarkStore` | `t/24-advanced-community.t`, `t/32-forum-web.t` | Supports save, restore, remove, status, and user listing. |
| Subscription | complete | `Forum` | `Notification::SubscriptionStore` | `t/17-notifications.t`, `t/32-forum-web.t` | Supports subscribe, mute, revoke, restore, status, and fanout recipient discovery. |
| Notifications | complete | `Notifications`, `Notifications::Read`, `Identity::Settings` | `Notification::Workflow`, `Notification::Dispatcher`, `Notification::PreferenceStore` | `t/17-notifications.t`, `t/32-forum-web.t`, `t/80-settings-web.t`, `t/106-notification-controllers.t`, `t/107-notification-workflow.t` | Lists inbox, marks read, and persists channel preferences through a dedicated write workflow, and returns coherent `404` for missing notification inbox rows. |
| Mentions | complete | `Notifications::Mentions`, `Forum` | `MentionExtractor`, `MentionStore`, `MentionReader` | `t/24-advanced-community.t`, `t/32-forum-web.t`, `t/106-notification-controllers.t` | Extracts unique mentions, skips unknown/self mentions, creates mention notifications, and exposes recipient inbox. |
| Attachments | complete | `Attachments`, `Attachments::Upload` | `Attachment::Workflow`, `UploadPipeline`, `Delivery` | `t/22-attachments.t`, `t/63-attachments-web.t`, `t/104-attachment-controllers.t`, `t/105-attachment-workflow.t` | Authors upload and link files to visible posts; downloads enforce delivery visibility and return `404`/`403` for missing or unavailable objects. |
| Reports | complete | `Forum`, `Moderation` | `Moderation::ReportStore` | `t/25-moderation-review.t`, `t/32-forum-web.t`, `t/43-moderation-web.t` | Authenticated users can report threads/posts; moderators can assign and resolve reports. |
| Moderation | complete | `Moderation`, `Moderation::Queue`, `Moderation::Actions`, `Moderation::Suspensions` | `Workflow`, `ActionStore`, `ReportStore`, `SuspensionStore`, `ReviewReader` | `t/25-moderation-review.t`, `t/43-moderation-web.t`, `t/50-security-hardening.t`, `t/94-moderation-controllers.t`, `t/95-moderation-workflow.t` | Covers queues, action history, hide/restore, lock/unlock, reverse, suspend, and revoke through a dedicated write workflow. |
| Admin roles/permissions | complete | `Admin`, `Admin::Catalog`, `Admin::Bindings` | `Workflow`, `RoleCatalog`, `RoleBindingStore`, `PermissionReview`, `PermissionGate`, `AuditReview` | `t/26-admin-authorization.t`, `t/44-admin-web.t`, `t/50-security-hardening.t`, `t/96-admin-controllers.t`, `t/97-admin-workflow.t` | Authorization distinguishes `401` anonymous from `403` permission denied and keeps writes CSRF-protected through a dedicated admin workflow. |
| Privacy rights | complete | `Privacy`, `Privacy::Requests`, `Privacy::Review` | `Workflow`, `DeletionWorkflow`, `ExportBundleBuilder`, `RetentionHoldStore`, `DataRightsReview` | `t/29-privacy-rights.t`, `t/62-privacy-web.t`, `t/100-privacy-controllers.t`, `t/101-privacy-workflow.t` | Members request export and deletion; staff approve, hold, or erase through a dedicated privacy workflow. Active legal holds return `409`. |
| Search | complete | `Forum` | `Search::Searcher` | `t/19-search.t`, `t/32-forum-web.t` | PostgreSQL-native derived search and autocomplete remain visibility/permission-aware and bounded. |
| Public feed | complete | `Discovery` | `FeedBuilder`, `ThreadReader`, `VisibilityPolicy` | `t/30-public-discovery.t`, `t/32-forum-web.t` | Atom feed exposes only public visible excerpts, not full private/moderated content. |
| Sitemap/robots/canonical metadata | complete | `Discovery`, `Forum` | `SitemapBuilder`, `RobotsPolicy`, `CanonicalUrl`, `MetadataBuilder` | `t/30-public-discovery.t`, `t/32-forum-web.t` | Public discovery is canonical, noindex-safe for restricted content, and excludes hidden/deleted resources. |
| Realtime | complete | `Realtime` | `Web::RealtimeAccess`, `Realtime::Hub`, `ConnectionRegistry`, `ChannelAuthorizer`, `PgNotifier`, `PgListener`, `ListenerSupervisor` | `t/20-realtime.t`, `t/81-realtime-operational.t`, `t/82-realtime-supervisor.t`, `t/113-web-realtime-access.t` | Realtime is strict-auth, LISTEN/NOTIFY capable, supervised per web process, and remains an enhancement over polling. Handshake origin and payload decisions live outside the controller. |
| Personal feed | complete | `Forum` | `FeedReader`, `FeedProjector` via outbox `FeedProjection` | `t/24-advanced-community.t`, `t/148-feed-projection-handler.t`, `t/16-workers-phase.t` | Authenticated `/feed` reads `user_feed_items`. Created and restored posts/threads project rows for the author and active thread subscribers; `post.hidden` deletes those rows. |
| Worker delivery | complete | workers | `Outbox::Dispatcher`, `DomainEventTransport`, `MinionRegistrar`, worker handlers | `t/16-workers-phase.t`, `t/83-outbox-worker-wiring.t`, `t/148-feed-projection-handler.t`, `t/149-reputation-update-handler.t` | Outbox dispatch is wired to real handlers through a direct worker command and optional Minion registration; feed projection and reputation updates run on the same transport as search, notifications, and cache. |

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
| Email lifecycle | Mail send happens in-process after the token transaction; a delivery failure is logged and does not roll back issuance. | `Identity::Mailer` uses an injectable `Email::Sender` transport from `GPFORUM_MAIL_*`. Raw tokens are not logged. Pending accounts stay session-less until verify. Mail is not outbox-queued. | low |
| Multi-process rate limiting | PostgreSQL-backed limiter exists; local memory remains degraded fallback. | `/metrics` exposes primary failures, fallback usage and blocked decisions. | low |
| Realtime fanout | Websocket state is process-local. | Each web process can run a supervised LISTEN/NOTIFY listener; polling remains canonical fallback. | low |
| Worker operations | Minion backend is opt-in and requires explicit PostgreSQL URL/backend dependencies. | Direct outbox dispatch command is always available; Minion startup fails explicitly if configured incompletely. | low |
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
* full test suite passed: 55 files, 2767 tests;
* `script/perltidy-check` passed;
* `script/perlcritic --severity 5` passed;
* `script/architecture-check` passed;
* `script/query-plan-check` passed with 23 indexed query plans, 0 `OFFSET`
  violations, and DB-backed evidence activation when a DSN is configured.

`script/query-budget --check` passes when pointed at the synchronized local
Postgres.app evidence database.

## Next Product Priorities

1. Optionally queue identity mail through the outbox if send must survive
   process crash after token issuance.
2. Replace worker placeholder tasks with real outbox-driven handlers in priority
   order: search indexing, notification dispatch, cache invalidation.
3. Run PostgreSQL-backed rate-limit evidence against a seeded database.
4. Expand SSR form tests for admin/moderation happy-path redirects, not only
   JSON responses.
5. Add fixture-backed browser walkthrough for register -> login -> thread ->
   reply -> notification using a real PostgreSQL test database.
