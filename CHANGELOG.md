# Changelog

All notable changes to GPForum are recorded here.

## Unreleased

- Hidden posts now drop their `user_feed_items` rows through
  `FeedProjector->remove_item`; restore re-projects the author and thread
  subscribers with the existing `project_item` API. There is no
  `thread.hidden` event.
- Moderation hide, restore, lock, and unlock HTTP writes now mint and
  pass `command_id` the same way forum posting does, so ActionStore
  replay can fire on retry.
- Wired `FeedProjector` and `ReputationLedger` onto the existing outbox
  worker path. Created posts and threads now project into `/feed` for the
  author and thread subscribers, and posting, hide/restore, and suspension
  events update trust snapshots instead of leaving them at registration
  defaults.
- Added a oneshot `gpforum-scheduled-jobs` command, hourly systemd timer,
  and launchd sample so expired sessions, rate-limit buckets, identity
  tokens, completed outbox rows, and dead letters are deleted in bounded
  batches. The same run calls attachment orphan cleanup and
  `PartitionLifecycle` policy/evidence only (no app-owned
  `CREATE TABLE ... PARTITION OF`). See `docs/ops/scheduled-jobs.md`.
- Forum post bodies labeled `markdown` now render a safe subset (emphasis,
  http/https/mailto links, quotes, fenced code) through
  `Service::Forum::BodyRenderer` at compose time and in post presenters.
  Source is escaped before markup is added, so script tags and unsafe URLs
  stay text.
- Wired the existing `forum_retrieval` limiter on `GET /search`, and added
  `write_rate_input` hashes on `Web::ModerationAccess`, `Web::AdminAccess`,
  and `Web::PrivacyAccess` so moderation writes, admin writes, and privacy
  requests share the same CSRF/telemetry write helpers as forum
  `write_user_id`.
- Closed HIGH concurrency races on command replay, bookmarks, subscriptions,
  open reports, moderation actions, and the audit hash chain. Unique
  violations now replay the winning row, moderation hide/restore/lock take
  `FOR UPDATE`, and audit appends serialize previous-hash lookup with
  `pg_advisory_xact_lock` instead of swallowing chain-break errors.
  `migrations/026_concurrency_uniqueness.sql` makes the open-report unique
  index real and unique-indexes moderation `command_id`.
- Category create and update now invalidate the public category-list cache
  tags through the existing `CacheInvalidation` worker, so later admin
  edits do not wait for the 30s TTL.
- Delivered private-beta identity mail for password reset, email change,
  and registration verification through an injectable `Email::Sender`
  mailer. Pending accounts no longer receive a session until the
  verification token is confirmed, and the login page links to forgot
  password. `Email::Address::XS` 1.05 is a declared runtime pin so
  `Email::Sender::Simple` can load.
- Admin category create and update now go through `Admin::Workflow` and
  `Admin::CategoryStore`, so the first administrator can add the first
  forum category on a fresh install without `PerformanceSeed`.
- Deploy units and reverse-proxy samples can start after
  `carton install --deployment`: supervisors invoke `script/gpforum-carton`
  (not the non-existent `local/bin/carton`), Nginx proxies
  `/attachments/:id/download` instead of intercepting `/attachments/` as
  `internal`, and Nginx/Caddy serve `/assets/` from the repo `assets/` tree.
  GlifiStore remains an operator-supplied server plus `GlifiStore::Client`
  (not a Carton/PAUSE pin). systemd units create `/run/gpforum` with
  `RuntimeDirectory`.
- Search and moderation/admin optional-query hashes no longer drop the
  following keys when a missing next-page size or empty optional param
  used a bare `return` (Perl empty list). `ForumAccess::search_more_limit`
  and controller `optional_param` now return an explicit undef.
- Updated every locked CPAN distribution to its latest release and pruned
  32 orphaned distributions from `cpanfile.snapshot` (187 -> 157). DBI moves
  from 1.647, which carried 11 CPANSA advisories, to 1.653; URI, HTTP::Date,
  and List::SomeUtils::XS also leave vulnerable versions. Security floors for
  those transitive dependencies are now declared in `cpanfile`, and
  `cpan-audit` reports no open advisories apart from the two unfixed
  Mojolicious default-secret advisories, which `GPFORUM_SESSION_SECRET`
  enforcement already mitigates.
- Install and bootstrap now recognize CPAN distributions from `cpanfile`
  plus the `postgres` feature in `cpanfile.postgres`, and fetch only
  through Carton (`make install-deps` / `script/bootstrap-deps`) using
  `carton install --deployment`, `cpanfile.snapshot` pins, and the
  official MetaCPAN HTTPS mirror. Carton is resolved via
  `script/gpforum-carton` when it is not on PATH. The previous unpinned
  `cpanm --notest` PostgreSQL sideload is gone.
- Loaded `Crypt::URandom` lazily from `Service::Id` so UUID minting no
  longer imports that XS module at compile time.
- Moved attachment per-post and per-attachment link fetch caps onto
  `Attachment::Lifecycle` so the store no longer owns those windows inline
  with resultset searches.
- Loaded `Crypt::URandom` lazily from `Password` and `SessionToken`, and
  `Service::Id` lazily from `Identity::Store` and its credential/session/token
  stores, so identity compile-time tests can inject `Test::Id` without that
  XS module.
- Made GlifiStore the required disposable L2 cache for public SSR and
  category read-model seams; staging and production fail closed when
  `GPFORUM_GLIFISTORE_URL` is missing, while PostgreSQL stays authoritative.
- Raised runtime CPAN floors to current secure releases, including
  Mojolicious 9.49, Cpanel::JSON::XS 4.52 (CVE-2026-9334,
  CVE-2026-9516), Crypt::Argon2 0.032, DateTime 1.67, DBD::Pg 3.21.2,
  and Mojo::Pg 5.0.
- Rejected non-hash JSON in `Outbox::ClaimedMessage` so Cpanel::JSON::XS
  4.42+ `allow_nonref` cannot treat scalar payloads as outbox events.
- Loaded `Service::Id` lazily from `EventRecorder`,
  `Outbox::MessageBuilder`, and the event-backed stores that only used it
  for default construction so compile-time tests can inject `Test::Id`
  without `Crypt::URandom`.
- Moved community bookmark/subscription write-success statuses onto
  `Web::ForumAccess` so `Forum::Community` no longer owns those strings
  inline with store writes.
- Moved admin catalog/binding, moderation content/queue/suspension, and
  privacy review write-success statuses onto the existing `Web::*Access`
  objects so those controllers no longer own those strings inline with CSRF
  checks.
- Moved moderation permission action and resource names, plus admin and
  privacy catalog `view` actions, onto the existing `Web::*Access` objects
  so those controllers no longer own those strings inline with CSRF checks.
- Extracted `Web::OperationsAccess` for `/metrics` token presence, Bearer
  and `X-GPForum-Metrics-Token` comparison, and the unauthorized JSON
  payload so `Controller::Operations` no longer owns those contracts
  inline with snapshot rendering.
- Moved the 30-day authenticated cookie-session lifetime onto
  `Web::CookieSession` so `Controller::Identity` no longer owns
  `expires_at` inline with login rotation.
- Moved community `post`/`thread`/`user` target types onto
  `Web::ForumAccess` so `Forum::Community` no longer owns those strings
  inline with bookmark and report writes.
- Moved locale/theme preference-cookie names and Lax one-year options onto
  `Web::IdentityAccess` so `Identity::Base` and `Bootstrap::UI` share the
  same names without owning cookie writes there.
- Moved forum list page defaults, admin dashboard row caps, and identity
  profile thread limits onto the existing `Web::*Access` objects so those
  controllers no longer own the numbers inline with rendering.
- Moved `user`-scope `realtime.connect` / `realtime.subscribe` rate-limit
  hashes and plaintext handshake texts onto `Web::RealtimeAccess` so the
  websocket controller no longer owns those contracts inline with hub
  registration and telemetry.
- Moved identity_http rate-limit hashes onto `Web::IdentityAccess` so
  `Identity::Base` no longer owns login/register/password/logout/settings
  windows inline with CSRF telemetry.
- Moved search page, autocomplete, fetch, and more-results limits onto
  `Web::ForumAccess` so `Forum::Search` no longer owns those windows inline
  with degraded-search evals.
- Extracted `Web::AdminAccess` for catalog page limits, the
  `admin_console`/`manage` permission hash, Guard invalid-request titles,
  and the roles redirect so `Admin::Base` no longer owns those contracts
  inline with CSRF and telemetry.
- Extracted `Web::PrivacyAccess` for privacy list page limits, the
  `privacy_rights`/`manage` permission hash, `conflict` blocked-hold
  payloads, and Guard invalid-request titles so `Privacy::Base` no longer
  owns those contracts inline with CSRF checks.
- Extracted `Web::ModerationAccess` for report-queue page limits, default
  open/active filters, permission-target hashes, and Guard invalid-request
  payloads so `Moderation::Base` no longer owns those contracts inline with
  CSRF and telemetry.
- Extracted `Web::NotificationAccess` for inbox/mention page limits, the
  `notification_http` write rate-limit hash, and `failed`/`not_found`
  mapping so `Notifications::Base` no longer owns those contracts inline
  with CSRF and telemetry.
- Extracted `Web::AttachmentAccess` for upload rate-limit hashes, download
  filename sanitizing, content-disposition values, and Guard payloads so
  `Attachments::Base` no longer owns those contracts inline with CSRF checks.
- Extracted `Web::ForumAccess` for forum read/write rate-limit hashes,
  participation actions, report field errors, search filter names, public
  SSR cache keys, and integer limits so `Forum::Base` no longer owns those
  contracts inline with Guard rendering.
- Extracted attachment orphan-cleanup search, actor/reason fallbacks, and
  result hashes onto `Attachment::Lifecycle` so the store no longer owns
  those contracts inline with resultset deletes.
- Extracted login/logout AuditLog hashes onto `Identity::Event` so
  `Identity::SecurityAudit` no longer owns identifier hashing and request
  metadata inline with recorder writes.
- Extracted `Admin::Event` for role-binding and role-catalog AuditLog hashes so
  `RoleBindingStore` and `RoleCatalog` no longer own those contracts inline
  with row writes.
- Extracted suspend and revoke EventLog/AuditLog hashes onto
  `Moderation::Event` so `SuspensionStore` no longer owns those contracts
  inline with row writes.
- Extracted report created, duplicate-blocked, and transition EventLog/AuditLog
  hashes onto `Moderation::Event` so `ReportStore` no longer owns those
  contracts inline with row writes.
- Extracted `Moderation::Event` for created-action and reversal EventLog
  envelopes, payloads, and AuditLog hashes so `ActionStore` no longer owns
  those contracts inline with row writes.
- Extracted `Identity::Event` for `user.registered` envelopes, registration
  audit hashes, and typed identity audit arguments so `Identity::Audit` no
  longer owns those contracts inline with recorder writes.
- Extracted retention-hold EventLog/AuditLog hashes onto `Privacy::Event` so
  `RetentionHoldStore` no longer owns those contracts inline with row
  inserts.
- Extracted `Privacy::Event` for deletion-request, approval, hold, block, and
  completion EventLog hashes plus recorder EventLog/AuditLog arguments so the
  deletion workflow no longer owns those contracts inline with locks and
  row writes.
- Extracted `Attachment::Event` for EventLog envelopes, scan event types,
  payload hashes, and AuditLog arguments so the attachment store no longer
  owns those contracts inline with resultset writes.
- Extracted `Web::DiscoveryAccess` for sitemap/feed reader limits and crawler
  document rendering so the discovery controller no longer owns those
  contracts inline with category and thread reads.
- Extracted `Privacy::Completion` for approval/completion replay hashes, job
  done checks, skip payloads, and the default legal-hold reason so the
  deletion workflow no longer owns those results inline with locks and
  event writes.
- Extracted `Web::IdentityAccess` for identity CSRF text, rate-limit,
  system-failure, and bad-request rendering so the identity HTTP base no
  longer owns those contracts inline and does not reuse `Web::Guard`.
- Extracted `Attachment::Lifecycle` for upload replay, scan state
  transitions, and delete replay so the attachment store no longer owns those
  hashes inline with resultset writes.
- Extracted `Web::HomeAccess` for home reader limits, the success payload,
  and the custom `home_unavailable` 500 contract so the home controller no
  longer owns those hashes inline and does not reuse `Web::Guard`.
- Moved linked-versus-unlinked attachment download payloads onto
  `Attachment::DownloadAccess->authorized` so the store only preloads links
  and target rows.
- Extracted `Outbox::FailureType`, `Outbox::Retry`, and `Outbox::ClaimQuery`
  so the dispatcher no longer mixes failure classification, attempt/backoff
  policy, and PostgreSQL claim SQL with transport dispatch and row updates.
  `DeadLetterRecorder` loads `Service::Id` only when a production id service
  is needed.
- Split `ViewModel::Forum::Presenter` into row, page, and new-thread form
  helpers so the facade no longer mixes payload mapping with form defaults
  and thread-page assembly.
- Extracted `Privacy::Record` and `Privacy::Erasure` so deletion workflow no
  longer mixes row accessors and anonymized identity values with approval
  locks, hold blocking, and audit persistence.
- Extracted `Attachment::Record` and `Attachment::DownloadAccess` so the
  attachment store no longer mixes row accessors and download visibility
  with intent, scan, and audit persistence.
- Split `Service::I18N` into catalog lookup, locale negotiation, and
  date/number formatting helpers so the public facade no longer owns the
  bundled English and Italian strings inline.
- Extracted `Infrastructure::AuditRecord` for canonical audit hashing and
  verification so `EventRecorder` no longer mixes hash-chain construction
  with EventLog, OutboxMessage, and AuditLog persistence.
- Extracted `Web::PublicCacheAccess` for anonymous GET/HEAD cacheability and
  ETag/Last-Modified freshness so `PublicHttpCache` no longer mixes storage
  with validator decisions.
- Extracted `Web::CookieSession` for cookie-session presence, expiry, clearing,
  and login-value assembly so bootstrap identity and the login controller no
  longer mutate session keys inline.
- Extracted `Web::RealtimeAccess` for websocket origin, payload-size, and
  subscribe-message decisions so the realtime controller no longer mixes
  handshake rules with hub registration and telemetry.
- Extracted `Identity::RegistrationStore` for duplicate checks and
  transactional user/credential persistence so the identity store facade no
  longer owns registration writes.
- Extracted `Identity::AuthStore` for login credential verification and
  server-session creation so the identity store facade no longer owns
  authentication lookups.
- Extracted `Identity::AccountStore` for password reset, password change, and
  email-change persistence so the identity store facade no longer owns those
  token, credential, and user-row updates.
- Extracted `Identity::PreferenceStore` for locale and theme persistence so
  the identity store facade no longer owns preference row updates, and
  converted operations metrics auth helpers off postfix control.
- Extracted `Web::Access` for shared CSRF, session-user, and JSON decisions
  used by HTTP bases, identity settings, realtime, public cache, and session
  validation, leaving error rendering on `Web::Guard`.
- Routed identity locale/theme persistence and notification preference writes
  through `Identity::Workflow` and `Notification::Workflow`, keeping cookies
  and session rotation in the HTTP controllers.
- Split attachment and notification HTTP ownership, introduced
  `Attachment::Workflow` for post uploads and downloads, and
  `Notification::Workflow` for mark-read writes so controllers no longer
  look up posts, enforce authors, or map store exceptions themselves.
- Introduced `Identity::Workflow` as the write boundary for registration,
  login, logout, password, and email commands, keeping cookie-session rotation
  in the HTTP controller.
- Split privacy HTTP ownership into member dashboard, request, and staff
  review controllers, introduced `Privacy::Workflow` as the write boundary for
  export, deletion, hold, and erasure commands, and extracted `Web::Guard` for
  shared CSRF, auth, rate-limit, and error rendering used by privacy, admin,
  moderation, forum, attachments, and notifications.
- Wired operational profiles into `platform-check` and readiness so undersized
  production floors fail the same gate as OS preflight and query-budget drift.
- Added versioned operational profiles for development, staging,
  production-small, and production-medium, plus a partition lifecycle policy
  for monthly planning, retention detach, archival states, and restore
  evidence.
- Split admin HTTP ownership into review, catalog, and binding controllers, and
  introduced `Admin::Workflow` as the write boundary for roles, permissions,
  and role bindings.
- Split moderation HTTP ownership into review, queue, action, and suspension
  controllers, and introduced `Moderation::Workflow` as the write boundary for
  report, content, and suspension commands.
- Added public discovery and syndication boundaries for canonical URLs, safe
  metadata, robots.txt rules, sitemap entries, feed items, and prompt alignment.
- Added privacy rights operation boundaries for deletion requests, erasure jobs,
  retention legal holds, staff review, and DBIx::Class mapping coverage for the
  existing platform governance tables.
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
