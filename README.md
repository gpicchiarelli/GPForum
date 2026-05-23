# GPForum

<p align="center">
  <img src="assets/img/gpforum-logo.svg" alt="GPForum logo" width="420">
</p>

![GPForum hero](assets/img/gpforum-hero.png)

[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-a6532f.svg)](LICENSE)
[![CI](https://github.com/gpicchiarelli/GPForum/actions/workflows/ci.yml/badge.svg)](https://github.com/gpicchiarelli/GPForum/actions/workflows/ci.yml)
[![Project Hygiene](https://github.com/gpicchiarelli/GPForum/actions/workflows/project-hygiene.yml/badge.svg)](https://github.com/gpicchiarelli/GPForum/actions/workflows/project-hygiene.yml)
[![Project Status](https://img.shields.io/badge/status-active%20development-214237.svg)](prompt/20.txt)
[![Repository](https://img.shields.io/badge/repository-private-111412.svg)](https://github.com/gpicchiarelli/GPForum)
[![Prompt Constitutions](https://img.shields.io/badge/prompt%20constitutions-50-a6532f.svg)](prompt)
[![GitHub Ready](https://img.shields.io/badge/github-project%20ready-3f5f72.svg)](prompt/44.txt)
[![Security Policy](https://img.shields.io/badge/security-policy-111412.svg)](SECURITY.md)
[![Contributing](https://img.shields.io/badge/contributing-guide-63735f.svg)](CONTRIBUTING.md)
[![ADR](https://img.shields.io/badge/ADR-required-a6532f.svg)](docs/adr)

[![Perl](https://img.shields.io/badge/runtime-Perl%205.38%2B-214237.svg)](cpanfile)
[![Perl First](https://img.shields.io/badge/application-Perl--first-63735f.svg)](prompt/40.txt)
[![Multi Process](https://img.shields.io/badge/scaling-multi--process%20Perl-3f5f72.svg)](prompt/40.txt)
[![Mojolicious](https://img.shields.io/badge/web-Mojolicious-c9835a.svg)](https://mojolicious.org/)
[![DBIx::Class](https://img.shields.io/badge/ORM-DBIx::Class-3f5f72.svg)](https://metacpan.org/pod/DBIx::Class)
[![Minion](https://img.shields.io/badge/workers-Minion-a6532f.svg)](https://metacpan.org/pod/Minion)

[![PostgreSQL](https://img.shields.io/badge/database-PostgreSQL-214237.svg)](prompt/3.txt)
[![PostgreSQL Native Search](https://img.shields.io/badge/search-PostgreSQL%20FTS-3f5f72.svg)](prompt/42.txt)
[![pg_trgm](https://img.shields.io/badge/search-pg__trgm-63735f.svg)](prompt/42.txt)
[![OpenSearch](https://img.shields.io/badge/OpenSearch-optional%20only-c9835a.svg)](prompt/42.txt)
[![Redis](https://img.shields.io/badge/Redis%2FKeyDB-optional%20acceleration-c9835a.svg)](prompt/19.txt)

[![Carton](https://img.shields.io/badge/deps-Carton-63735f.svg)](cpanfile.snapshot)
[![Lockfile](https://img.shields.io/badge/deps-locked-214237.svg)](cpanfile.snapshot)
[![Perl::Critic](https://img.shields.io/badge/critic-brutal-111412.svg)](.perlcriticrc)
[![Coverage](https://img.shields.io/badge/coverage-mandatory-a6532f.svg)](prompt/41.txt)
[![Profiling](https://img.shields.io/badge/profiling-Devel::NYTProf-3f5f72.svg)](script/profile)
[![Devel::Cover](https://img.shields.io/badge/coverage-Devel::Cover-63735f.svg)](script/coverage)

[![Rendering](https://img.shields.io/badge/rendering-SSR%20first-214237.svg)](prompt/6.txt)
[![Security](https://img.shields.io/badge/security-defense--in--depth-111412.svg)](prompt/5.txt)
[![Authorization](https://img.shields.io/badge/authz-RBAC%20%2B%20ABAC-a6532f.svg)](prompt/22.txt)
[![Privacy](https://img.shields.io/badge/privacy-GDPR--ready-3f5f72.svg)](prompt/26.txt)
[![Governance](https://img.shields.io/badge/governance-explicit-63735f.svg)](prompt/32.txt)

[![Debian](https://img.shields.io/badge/os-Debian-214237.svg)](prompt/38.txt)
[![FreeBSD](https://img.shields.io/badge/os-FreeBSD-a6532f.svg)](prompt/38.txt)
[![Nginx or HAProxy](https://img.shields.io/badge/edge-Nginx%20%7C%20HAProxy-3f5f72.svg)](prompt/2.txt)
[![BSD-3 Compatible](https://img.shields.io/badge/license-compatible%20with%20commercial%20use-63735f.svg)](LICENSE)

**GPForum is an independent, Perl-native community platform for durable forums, explicit governance, serious moderation, and long-term operational clarity.**

It is designed as a PostgreSQL-centric, multi-process Perl system: Mojolicious for the web layer, DBIx::Class for persistence, Minion for asynchronous work, PostgreSQL full-text search for retrieval, Carton for reproducible dependencies, and strict profiling/coverage discipline from the first implementation milestone.

## About

GPForum starts from an architectural constitution rather than a pile of incidental code. The repository defines how the platform should behave, scale, test, profile, govern itself, and evolve before the first production subsystem is generated.

The goal is not to clone legacy forum software. GPForum is intended to become a modern independent platform for communities that need:

* durable public discussion;
* transparent moderation and appeals;
* scoped authorization;
* server-rendered speed;
* PostgreSQL-native search;
* Perl-first operational simplicity;
* reproducible builds;
* profiling and coverage as release gates;
* long-term maintainability.

## Current Status

This repository currently contains:

* a public static platform page in [index.html](index.html);
* visual identity assets in [assets](assets);
* editable logo source artwork in [assets/source/gpforum-logo-source.svg](assets/source/gpforum-logo-source.svg);
* 50 architectural prompt constitutions in [prompt](prompt);
* GitHub project success surface in [.github](.github), [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [GOVERNANCE.md](GOVERNANCE.md), [SUPPORT.md](SUPPORT.md), [ROADMAP.md](ROADMAP.md), [CHANGELOG.md](CHANGELOG.md), and [docs/adr](docs/adr);
* BSD-3 license in [LICENSE](LICENSE);
* strict Perl::Critic configuration in [.perlcriticrc](.perlcriticrc);
* Carton dependency manifests in [cpanfile](cpanfile) and [cpanfile.snapshot](cpanfile.snapshot);
* PostgreSQL-specific dependency manifest in [cpanfile.postgres](cpanfile.postgres);
* Mojolicious application skeleton in [lib/GPForum.pm](lib/GPForum.pm);
* DBIx::Class schema root in [lib/GPForum/Schema.pm](lib/GPForum/Schema.pm);
* PostgreSQL core identity and event/audit migrations in [migrations](migrations);
* forum hot-path/projection migration with post head/body/revision split;
* platform governance migration for command log, ledgers, projection lag, partition registry, dead letters, and query budgets;
* partial, BRIN, covering, trigram, and projection-oriented indexes;
* DBIx::Class mappings for core forum heads, bodies, revisions, counters, stats, and search projections;
* first forum thread creation boundary with composer/store split, thread/post events, and audit record;
* forum reply creation boundary with post/body/revision persistence, post event, audit record, and anti-hot-row counter shard delta;
* bounded keyset pagination readers for category thread lists and thread post lists;
* server-side session persistence in the canonical `sessions` table;
* UUIDv7 identifier generation for sortable distributed ids;
* Argon2id password hashing and random session token services;
* server-rendered identity routes for registration, login, logout, and public contributor profiles;
* CSRF enforcement for state-changing identity requests;
* registration persistence boundary for users, credentials, events, and audit records;
* transactional outbox rows for forum domain events;
* retry-aware outbox dispatcher boundary for future Minion workers;
* dead-letter preservation for exhausted outbox deliveries;
* projection offset tracking for lag and health visibility;
* projection generation management for blue/green read-model rebuilds;
* Minion registration, idempotent job runner, and worker placeholders for search, notification, and cache invalidation;
* notification subscriptions, preferences, inbox creation, read state, and fanout services;
* PostgreSQL-native search document building, indexing, rebuild, permission-aware querying, and worker handoff services;
* process-local realtime websocket boundaries for authenticated connections, authorized channel subscription, thread updates, notification badges, and polling fallback;
* attachment upload intent, validation, lifecycle persistence, links, variants, scanning hook, and media processing worker boundaries;
* operations hardening boundaries for rate limiting, metrics snapshots, runbook validation, and runtime sizing;
* advanced community boundaries for mentions, bookmarks, reputation, trust snapshots, and user feed projection;
* HTTP bookmark and thread-follow controls backed by idempotent community/notification stores;
* mention extraction and persistence on thread/reply creation as derived social continuity state;
* moderation review boundaries for reports, reversible moderation actions, suspensions, and admin audit review;
* admin authorization boundaries for role catalogs, scoped role bindings, permission review, and audit-backed role changes;
* idempotent admin bootstrap command for initial owner role, default admin/moderation permissions, and global role binding;
* import/export portability boundaries for manifest validation, dry-run import jobs, legacy id mapping, failure reporting, and privacy-aware export manifests;
* plugin extension boundaries for manifest validation, plugin registry lifecycle, named hook dispatch, and observable plugin failures;
* privacy rights boundaries for account deletion requests, erasure jobs, retention legal holds, and staff data-rights review;
* public discovery boundaries for canonical URLs, no-leak metadata, robots rules, sitemaps, and safe public feeds;
* navigable forum HTTP routes for the public home index, categories, category thread lists, thread pages, thread creation, reply creation, and search;
* real readiness checks for database/resultset availability;
* automation scripts in [script](script).

The current implementation has reached **Milestone 17: Forum HTTP MVP** under the
constraints in [prompt/20.txt](prompt/20.txt). See [docs/MVP.md](docs/MVP.md)
for the route surface that is actually traversable today.

## MVP Web Surface

The current forum MVP exposes these routes. Read routes render accessible,
semantic SSR by default and still return JSON when requested with
`Accept: application/json` or `?format=json`:

* `GET /`
* `GET /admin`
* `GET /admin/roles`
* `POST /admin/roles`
* `POST /admin/permissions`
* `POST /admin/roles/:role_id/permissions`
* `GET /admin/users/:user_id/roles`
* `POST /admin/users/:user_id/roles`
* `POST /admin/role-bindings/:binding_id/revoke`
* `GET /admin/audit`
* `GET /categories`
* `GET /c/:category_id`
* `GET /t/:thread_id`
* `GET /new-thread`
* `POST /threads`
* `POST /t/:thread_id/replies`
* `POST /t/:thread_id/read`
* `GET /feed`
* `GET /bookmarks`
* `POST /t/:thread_id/bookmark`
* `POST /t/:thread_id/bookmark/remove`
* `POST /t/:thread_id/subscribe`
* `POST /t/:thread_id/subscribe/mute`
* `POST /t/:thread_id/subscribe/remove`
* `POST /t/:thread_id/report`
* `POST /p/:post_id/report`
* `GET /moderation/reports`
* `GET /moderation/actions`
* `GET /moderation/suspensions`
* `POST /moderation/reports/:report_id/assign`
* `POST /moderation/reports/:report_id/resolve`
* `POST /moderation/posts/:post_id/hide`
* `POST /moderation/posts/:post_id/restore`
* `POST /moderation/threads/:thread_id/lock`
* `POST /moderation/threads/:thread_id/unlock`
* `POST /moderation/actions/:action_id/reverse`
* `POST /moderation/users/:user_id/suspend`
* `POST /moderation/suspensions/:suspension_id/revoke`
* `GET /notifications`
* `POST /notifications/:notification_id/read`
* `GET /mentions`
* `GET /u/:username`
* `GET /search?q=...`
* `GET /robots.txt`
* `GET /sitemap.xml`
* `GET /feed.atom`

State-changing forum routes require CSRF and an authenticated session user. Read
paths use keyset pagination and never `OFFSET`. Thread and reply creation remain
inside the existing `ThreadStore` and `PostStore` transaction boundaries, so
event log, audit log, outbox, bodies, revisions, and counters stay coherent.
Thread read progress is stored as compressed per-user read state plus a
coalescable delta row, preserving continuity without making it authoritative
forum content.

The admin console is now minimally traversable for operators with
`admin_console.view` or `admin_console.manage` permissions. It exposes role and
permission catalogs, scoped role binding review/write workflows, binding
revocation, and bounded audit review through thin Mojolicious controllers over
the existing admin services. Role binding writes remain audit-backed and
CSRF-protected; the controller never manipulates persistence directly.
Initial operator access is bootstrapped outside the HTTP console with
`bin/gpforum-admin-bootstrap --user-id USER_ID`, which is idempotent and writes
through the same role catalog and role binding boundaries.

The root home route is backed by `HomePageReader`. It renders a public forum
index from visible categories and keyset-paginated public threads, while keeping
the controller free of DBIx::Class resultset logic.

Public contributor profiles are backed by `ProfileReader`. They expose a safe
identity summary, trust snapshot, and keyset-paginated public discussions
without leaking email, credential, deleted, suspended, private, or moderated
content.
Thread bookmarks and follow/mute/unfollow controls are wired through the
existing community and notification stores. They are idempotent per user/thread,
SSR-accessible, CSRF-protected, and derived from PostgreSQL rows rather than any
process-local state.
Thread and post reports are now traversable from the thread page. They require
an authenticated session, CSRF, and rate limiting, then write through
`ReportStore`, which records the report, append-only domain event, audit row,
and transactional outbox handoff.
The moderation report queue is also traversable for authorized staff. Access is
checked by `PermissionGate` against PostgreSQL role bindings and permissions;
assignment and resolution remain CSRF-protected and emit report transition
events, audit rows, and outbox handoffs.
Staff review is now traversable beyond the queue itself: `/moderation/actions`
exposes a keyset-paginated moderation action history and
`/moderation/suspensions` exposes active or historical suspension rows. Both
routes stay read-only, permission-gated, SSR/JSON capable, and backed by
PostgreSQL rather than process-local state.
Moderators can now execute reversible content actions from the same HTTP
boundary. Post hide/restore, thread lock/unlock, and moderation action reversal
delegate to `ActionStore`; each action runs in a PostgreSQL transaction and
records the moderation action, domain event, audit row, and transactional
outbox handoff. Locked threads remain readable for archival continuity, while
reply creation is still blocked by `locked_at`.
User suspension is also wired as an executable boundary. Authorized staff can
suspend users and revoke suspensions through `SuspensionStore`; the store writes
canonical suspension rows, updates user status, emits event/audit/outbox rows,
and the forum write path blocks suspended users from creating threads or
replies while keeping non-publishing continuity actions separate.
The authenticated `/feed` route exposes the existing `user_feed_items`
projection as a keyset-paginated personal continuity feed. It is derived,
rebuildable, and non-authoritative: it stores only item references and version
metadata, while canonical thread/post visibility remains enforced by the write
and projection boundaries.
The notification inbox is also traversable over HTTP. It uses the existing
notification dispatcher read model, keyset pagination, and a CSRF-protected
mark-read workflow so realtime badge updates have an SSR fallback.
Thread and reply creation now record resolved `@username` mentions after the
canonical write path completes. Mention recording is PostgreSQL-backed,
idempotent at the service boundary, and treated as derived social signal: a
mention failure is logged and does not corrupt the authoritative post/thread
transaction. Reply events dispatched through the outbox can fan out
notifications to thread subscribers while excluding the post author.
Mention notifications are now created by the mention boundary itself and the
authenticated `/mentions` page exposes a keyset-paginated mention history.
The notification inbox includes joined source/type/payload data so a mention
can link back into the discussion without making realtime delivery
authoritative.
Public discovery is also wired over HTTP. `/robots.txt`, `/sitemap.xml`, and
`/feed.atom` are generated from the existing discovery services, canonical URL
configuration, and public thread/category readers. They are permission-safe,
moderation-aware, and derived from PostgreSQL-backed read paths; private,
hidden, or deleted content is not emitted.
SSR form submissions redirect back into the discussion flow; JSON clients keep
the explicit `201 Created` payload by sending `Accept: application/json`.
OS-level feature flags such as `GPFORUM_OS_REUSEPORT`,
`GPFORUM_OS_SENDFILE`, and `GPFORUM_OS_AFFINITY` are validated at config load
and exposed in health/metrics output. Runtime snapshots also expose socket
policy and process-class priority posture, so deployment tuning stays visible
without scattering OS checks through application code. `/health/ready`,
`/metrics`, and `script/system-preflight` include OS preflight status so unknown
or degraded host capabilities are visible before production traffic depends on
them. `GPFORUM_OS_MIN_RECOMMENDED_WORKERS` and
`GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS` provide conservative readiness thresholds
for host capacity posture.
The process-local disposable cache is implemented in pure Perl with namespace,
TTL, max-entry, key invalidation, tag invalidation, and metrics. It is wired
only into read-mostly category lists by default through
`GPFORUM_LOCAL_CACHE_MAX_ENTRIES` and `GPFORUM_CATEGORY_CACHE_TTL_SECONDS`;
worker cache invalidation consumes domain events and invalidates matching tags.
Local generated files have a dedicated atomic-write helper under
`GPForum::OS::Filesystem`.

Known MVP limits: realtime fanout and rate limiting are process-local, search
depends on PostgreSQL projection rows, and reply position allocation is protected
by the database uniqueness constraint but should gain advisory locking or a
dedicated sequence allocator before hot production traffic.
Endpoint query budgets are now exposed through operational metrics for hot
paths such as home, category threads, thread view, create workflows, and search.
Use `carton exec bin/gpforum-query-budget --print`, `--sync`, or `--check` to
inspect, persist, or verify those budgets against PostgreSQL governance state.
Use `carton exec bin/gpforum-platform-check --local|--strict-local|--with-db|--strict-with-db`
as a deploy/CI gate for OS preflight and, when DB-backed, query budget drift.

## Architecture

```text
Nginx or HAProxy
  -> multi-process Mojolicious application nodes
  -> DBIx::Class domain/persistence layer
  -> PostgreSQL authoritative storage
  -> PostgreSQL FTS / pg_trgm search projections
  -> Minion worker pools
  -> local disposable caches
  -> optional Redis/KeyDB acceleration
```

The application runtime is Perl-first and process-first. Threads are allowed only for bounded, reviewed workloads. Search is PostgreSQL-native by default; external search engines require an ADR and remain optional derived acceleration.

## Core Decisions

* **Language:** modern Perl.
* **Web:** Mojolicious, server-rendered first.
* **Persistence:** PostgreSQL as authoritative system of record.
* **Schema Style:** canonical tables separated from rebuildable projection tables.
* **Search:** PostgreSQL full-text search, `tsvector`, GIN, `pg_trgm`, Perl orchestration.
* **Events:** partition-aware event/audit logs plus transactional outbox.
* **Async:** Minion workers.
* **Caching:** local disposable caches, Redis/KeyDB optional.
* **Dependencies:** Carton.
* **Profiling:** Devel::NYTProf.
* **Coverage:** Devel::Cover.
* **License:** BSD-3-Clause.

## Quick Start

Install base Perl dependencies:

```sh
script/bootstrap-deps
```

Check system prerequisites:

```sh
script/system-preflight
```

Run quality commands:

```sh
script/perlcritic
script/test
script/coverage
script/profile -Ilib bin/gpforum-migrate --plan
script/profile-route /categories
```

Inspect the migration plan:

```sh
carton exec perl -Ilib bin/gpforum-migrate --plan
carton exec perl -Ilib bin/gpforum-migrate --apply
```

Enable PostgreSQL-specific Perl modules after installing system PostgreSQL client development files:

```sh
script/bootstrap-deps --postgres
```

On Debian/Ubuntu:

```sh
sudo apt install libpq-dev
```

On FreeBSD:

```sh
sudo pkg install postgresql16-client
```

## Public Page

Preview the platform page locally:

```sh
python3 -m http.server 8000
```

Then open:

```text
http://127.0.0.1:8000/index.html
```

## Prompt Map

Foundational architecture:

* [1](prompt/1.txt) Foundation
* [2](prompt/2.txt) Infrastructure
* [3](prompt/3.txt) Database
* [4](prompt/4.txt) Perl engineering
* [5](prompt/5.txt) Security
* [6](prompt/6.txt) Frontend
* [7](prompt/7.txt) Realtime
* [8](prompt/8.txt) Workers
* [9](prompt/9.txt) Authorization and governance
* [10](prompt/10.txt) Observability
* [11](prompt/11.txt) CI/CD
* [12](prompt/12.txt) APIs
* [13](prompt/13.txt) Domain model
* [14](prompt/14.txt) Search
* [15](prompt/15.txt) Performance
* [16](prompt/16.txt) Software engineering

Implementation and operations:

* [17](prompt/17.txt) Community operations
* [19](prompt/19.txt) Cache and Redis decision
* [20](prompt/20.txt) MVP roadmap
* [21](prompt/21.txt) Initial schema
* [22](prompt/22.txt) Permission matrix
* [23](prompt/23.txt) Event catalog
* [24](prompt/24.txt) HTTP workflows
* [25](prompt/25.txt) UX
* [26](prompt/26.txt) Privacy
* [27](prompt/27.txt) Runbooks
* [28](prompt/28.txt) Bootstrap implementation
* [29](prompt/29.txt) Configuration
* [30](prompt/30.txt) Email
* [31](prompt/31.txt) Admin console
* [32](prompt/32.txt) Content policy
* [33](prompt/33.txt) Import/export
* [34](prompt/34.txt) SEO and syndication
* [35](prompt/35.txt) Plugins
* [36](prompt/36.txt) Test strategy
* [37](prompt/37.txt) API contracts
* [38](prompt/38.txt) Packaging and deployment
* [39](prompt/39.txt) Prompt governance
* [40](prompt/40.txt) Perl multi-process scaling
* [41](prompt/41.txt) Profiling and coverage automation
* [42](prompt/42.txt) PostgreSQL-native search
* [43](prompt/43.txt) Executable architecture contract
* [44](prompt/44.txt) GitHub project success contract
* [45](prompt/45.txt) Verifiable engineering invariants
* [46](prompt/46.txt) Accessibility engineering
* [47](prompt/47.txt) Human-centered community lifecycle
* [48](prompt/48.txt) Core boundary and architectural discipline
* [49](prompt/49.txt) OS-level performance
* [50](prompt/50.txt) Execution constitution for operational integrity

[prompt/18.txt](prompt/18.txt) is an exploration memo. [prompt/19.txt](prompt/19.txt) and [prompt/42.txt](prompt/42.txt) are authoritative final decisions.

## Precedence

When documents conflict:

1. Security and privacy constraints win.
2. Final-decision prompts win over exploration memos.
3. More specific domain prompts win over broad philosophy.
4. Intentional architecture changes require ADRs.

Known final decisions:

* Redis/KeyDB is optional acceleration, not correctness infrastructure.
* OpenSearch is no longer default; PostgreSQL-native search is authoritative.
* Perl application runtime is multi-process and process-first.
* Carton, coverage, profiling, and Perl::Critic are mandatory automation surfaces.
* Prompt alignment is mandatory for every architecture-changing implementation.
* GitHub project success surface is mandatory for reviewability, security, contribution, and release discipline.
* Architecture-by-verifiable-invariants is mandatory for long-term correctness, release discipline, and maintainability.
* Accessibility engineering is mandatory for participation equality, WCAG enforcement, semantic rendering, and release correctness.
* Human-centered community lifecycle design is mandatory for durable participation without dark patterns.
* Core boundary discipline is mandatory: small stable core, capability-scoped plugins, no controller business logic, and no cache/projection authority.
* OS-level performance discipline is mandatory: persistent Perl processes, centralized OS abstraction, bounded hot paths, reverse-proxy file delivery, PostgreSQL coordination, and profiling before invasive optimization.
* Execution constitution is mandatory: every workflow change must identify canonical state, event emission, projection impact, audit record, indexes, permissions, failure mode, rebuildability, replayability, and operational scaling.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
