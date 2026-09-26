# GPForum longevity architecture review

Date: 2026-06-02.

Role: Principal Engineer tasked with assessing maintainability, evolvability,
future cost, architectural complexity, and technical debt over a 5-10 year
horizon.

This is not a security review and it proposes no new features. The assessments
derive from the code inspected in `lib`, `t`, `migrations`, `deploy`, and
`.github/workflows`, and from the architectural gate scripts.

## Main evidence from the code

- `lib` contains 248 Perl modules.
- The largest layers are `Service` with 102 modules and 18,741 lines,
  `Controller` with 12 modules and 5,444 lines, `Command` with 10 modules and
  5,177 lines, and `Schema::Result` with 58 result classes and 3,146 lines.
- The largest controllers are `Controller::Forum` with 1,360 lines,
  `Controller::Identity` with 1,157 lines, `Controller::Moderation` with 651
  lines, and `Controller::Admin` with 622 lines.
- The largest services are `Service::Attachment::Store` as a persistence facade
  over `Record`, `DownloadAccess`, `Lifecycle`, and `Event`;
  `Service::Privacy::DeletionWorkflow` as a facade over `Record`, `Erasure`,
  `Completion`, and `Event`; `RetentionHoldStore` as hold persistence over
  `Event`; and `Service::Outbox::Dispatcher` as a facade over `FailureType`,
  `Retry`, and `ClaimQuery`. `Identity::Store` is a 317-line facade over
  dedicated stores, with `Identity::Event` under `Audit`.
- `Domain` today contains essentially only `EventEnvelope`; the real domain is
  expressed mostly in services, stores, workflows, and the DBIC schema.
- There are 25 migrations; the densest are `004_platform_governance.sql`,
  `003_forum_projection.sql`, `001_core_identity.sql`, and
  `002_event_audit.sql`.
- `t` contains 87 top-level test files and 106 helpers under `t/lib`, for about
  30,115 lines of tests and helpers.
- `script/architecture-check` and the tests `t/34-architecture-discipline.t`,
  `t/75-architecture-foundation.t`, and `t/86-engineering-correctness.t` pass.
- I found no direct dependencies from services toward controllers/views/web and
  no direct DBIC access in controllers; this is a real, positive property.

## Summary

GPForum is a modular monolith that is far tidier than average: an explicit
composition root, a rich DBIC schema, a broad service layer, an outbox,
audit/event logs, query budgets, extensive tests, and deploy templates. That
gives it a concrete base for lasting.

The main risk is not a lack of architecture but the amount of surface already
present relative to the forum core: advanced identity, privacy, moderation,
realtime, plugins, portability, OS runtime, benchmarks, and governance all live
in the monolith. If that surface grows without extracting more stable
application boundaries, future cost will rise non-linearly.

An honest estimate: GPForum can stay maintainable for 5 years without a rewrite
if it remains a modular monolith and if the next 12 months shrink the large
controllers, the identity store, and the overly wide workflows. If instead
federation, public APIs, mobile, external plugins, and multi-site are added
without those refactors, the risk of a partial rewrite becomes high.

## Assessment by area

| Area | Score | Debt | Rationale | Risk | Future cost |
| --- | ---: | --- | --- | --- | --- |
| Architecture | 8.0/10 | ARCHITECTURAL | `GPForum.pm` delegates to targeted bootstraps; `Service`, `Web`, `ViewModel`, `Worker`, and `Schema` are separate; controllers do not use DBIC directly. | Manual composition through Mojolicious helpers and very wide bootstraps can turn into a service locator that is hard to govern. | Medium: grows with every new workflow. |
| Domain | 7.0/10 | STRATEGIC | Forum, identity, moderation, privacy, and event/outbox concepts are recognizable and coherent. | The domain is implicit in stores/schema/state strings; `Domain` is thin and holds no aggregate or workflow semantics. | Medium-high once federation/API/plugins arrive. |
| Database | 8.0/10 | OPERATIONAL | Strong PostgreSQL schema: constraints, indexes, unique keys, partitions for event/audit/notifications, read models, and query budgets. | Data growth calls for more explicit partition lifecycle, archiving, retention, and operational restore; some early migrations are very dense. | Medium up to 10k users, high at 100k. |
| Controllers | 5.5/10 | CODE QUALITY | Controllers respect the DB boundary reasonably well, but `Forum` and `Identity` are too large and duplicate error/render/auth/CSRF/HTML-JSON handling. | Any UX/API change can touch large files, increase branching, and make the web tests fragile. | High over the next 12 months. |
| Workflows | 7.0/10 | ARCHITECTURAL | `PostingWorkflow`, the outbox dispatcher, and the idempotency service are good signals; transactions are concentrated in the stores. | Identity, privacy, and moderation mix too many cases into wide stores/workflows; some workflows are still orchestrated in the controllers. | Medium-high. |
| Testing | 8.0/10 | OPERATIONAL | Broad suite, strict CI, coverage, architecture gates, query budgets, smoke benchmarks, and many business regressions. | Many tests are fixtures/test doubles and textual contracts; maintenance cost grows and real-DB evidence for new concurrency can be missing. | Medium. |
| Performance architecture | 7.0/10 | ARCHITECTURAL | Keyset pagination, query budgets, hot-path indexes, FTS/trigram search, local TTL/tagged cache. | A process-local cache, limited invalidation, and search inside PostgreSQL can become bottlenecks at high scale. | Medium at 10k, high at 100k. |
| Operations | 7.5/10 | OPERATIONAL | Validated config, request id, metrics/readiness, systemd/nginx/freebsd/launchd, preflight, and CI with PostgreSQL. | Environment profiles and rollback are contracts/runbooks more than full automation; multi-process debugging will require operational discipline. | Medium. |
| Future evolution | 6.5/10 | STRATEGIC | A modular monolith suits gradual evolution; a plugin registry and bootstrap boundaries exist. | OAuth/OIDC, public APIs, mobile, multi-site, and federation demand more stable boundaries than the current ones. | High if it grows without refactoring. |

## Architecture

### What works

- `GPForum.pm` is a readable composition root: it builds config/runtime and
  registers specific bootstraps.
- The bootstraps separate the main families: Core, Security, Operations,
  Identity, Discovery, Forum, Workers, Admin, Moderation, Privacy, Routes.
- Controllers do not access `DBIx::Class` resultsets directly; they go through
  helpers/services.
- Services do not depend on controllers or views.
- The architectural gates are executable and they pass.

### Future cost

The system uses Mojolicious helpers as a dependency container. Today that is
pragmatic; in 5 years it can become opaque, because dependencies and lifetimes
are spread between `Bootstrap::*` and the controllers. `Bootstrap::Forum`
registers many heterogeneous dependencies: forum, attachment, community,
notification, and search. That choice stays acceptable while the product remains
an SSR monolith, but it becomes costly once API/mobile or multi-site arrive.

### Debt

ARCHITECTURAL: introduce a more explicit application boundary for critical
write/read workflows before extending the external capabilities.

## Domain

### What works

- Coherent main names: `Thread`, `Post`, `PostBody`, `PostRevision`, `Report`,
  `ModerationAction`, `DeletionRequest`, `ErasureJob`, `OutboxMessage`,
  `EventLog`, `AuditLog`.
- The event/outbox concept is consistent across the main writers.
- `PostingWorkflow` is a good application boundary for threads/replies.
- Read models are separate from writers in several cases.

### Future cost

The domain is not yet expressed as a stable aggregate model. The rules live in
stores and controllers, often as state strings: `visible`, `hidden`, `locked`,
`pending`, `approved`, `held`, `done`. That is not wrong for an MVP, but it
makes it more expensive to add workflow variants without breaking existing
cases.

The `Domain` module is too small relative to the amount of real semantics. There
is no need to create domain objects everywhere, but the main commands should
become clear, testable application contracts.

### Debt

STRATEGIC: formalize the command/result/event contracts of the main workflows
before introducing external integrations.

## Database

### What works

- A broad DBIC schema with understandable names.
- Important constraints are present: unique on users, session hash, post
  position, revision number, bookmark/subscription target, outbox idempotency,
  command log idempotency.
- Hot-path indexes exist for threads, posts, search, outbox, reports, and
  sessions.
- Event, audit, and notifications are prepared for range partitions on
  `created_at`.
- `query-plan-check` and `query-plan-evidence` exist as control tools.

### Future cost

The append-only and semi-append-only tables will become the most expensive
operational point: `event_log`, `audit_log`, `notifications`, `outbox_messages`,
`dead_letters`, `search_documents`, `post_revisions`, `rate_limit_buckets`. The
code already has the concepts, but I do not see in the code a complete
management of partition lifecycle, archiving, per-table retention, or cold data
rotation.

At 100,000 users PostgreSQL can still be the center of the system, but only with
active partitions, measured vacuum/retention, sized search, and a clear
separation of jobs.

### Debt

OPERATIONAL: create an operational partition/retention/archiving lifecycle
before the volume forces it.

## Controllers

### What works

- Controllers delegate heavily to services and view models.
- I found no direct DBIC resultset access in the controllers.
- `Forum` uses `PostingWorkflow` for
  create_thread/create_reply/edit_post/delete_post/restore_post/edit_thread/delete_thread/restore_thread/move_thread
  instead of inserting directly.

### Future cost

`Controller::Forum` and `Controller::Identity` are the most visible debt.
Examples from the code:

- `Controller::Forum` has 1,360 lines and handles read pages, writes, feed,
  bookmarks, subscriptions, reports, search, autocomplete, cache rendering,
  error payloads, CSRF, rate limits, and suspension checks.
- `Controller::Identity` has 1,157 lines and covers login, register, reset,
  settings, email confirmation, profile, and many rendering/route helpers.
- `_render_payload`, `_render_error`, `_csrf_failure`, `_forbidden`,
  `_bad_request`, `_current_user_id`, and similar patterns are duplicated across
  several controllers.

This does not require a mega-refactor. It requires a controlled sequence:
extract the common HTTP helpers and command adapters first, then shorten the
longest methods.

### Debt

CODE QUALITY: refactor within 12 months. Not for aesthetics, but to reduce the
cost of new routes/APIs and regressions in the existing flows.

## Workflows

### What works

- `PostingWorkflow` is a good step forward from business logic in controllers.
- `CommandIdempotency` makes the command/replay concept explicit.
- `PostStore` allocates the position inside a transaction and locks the thread
  with `FOR UPDATE`.
- `Outbox::Dispatcher` uses a PostgreSQL batch claim with
  `FOR UPDATE SKIP LOCKED`.
- `DeletionWorkflow` contains idempotency on approval/job and a hold check.

### Future cost

The quality is not uniform:

- forum posting has an application workflow;
- moderation is still mainly `ActionStore`;
- identity is a single wide store for credentials, sessions, tokens,
  preferences, and audit;
- privacy deletion is a dedicated workflow but already complex;
- bookmarks/subscriptions are simple stores with check-then-write logic.

For 5-year maintainability, the write workflows must converge on a common shape:
command object, authorization decision, idempotency, transaction,
event/audit/outbox, response.

### Debt

ARCHITECTURAL: unify the critical write workflows without building a framework.

## Testing

### What works

- Broad suite: 87 top-level files and 106 helpers.
- CI covers syntax, perltidy, perlcritic, migrations, seed, query budget,
  architecture check, query plan, tests, smoke benchmarks, Hypnotoad, and
  coverage.
- Architecture and engineering-correctness tests exist, not just unit tests.
- Many modules have targeted tests and reusable fixture helpers.

### Future cost

The suite's maintenance cost is already significant. Some tests are very long
(`t/05-database.t`, `t/09-prompt-alignment.t`,
`t/72-forum-bootstrap-workflow.t`) and some verify contracts through text or
regexes. Those gates are useful, but they can become fragile when the design
changes legitimately.

The main risk is false comfort: test doubles and fast fixtures do not replace
concurrent PostgreSQL tests or real operational evidence when command log, audit
chain, outbox, privacy, and moderation are touched.

### Debt

OPERATIONAL: keep the tests fast, but add DB-backed tests only where the real
risk justifies them.

## Performance architecture

### What works

- Keyset pagination in the forum/bookmark readers.
- A query budget catalog and request-level DB observation.
- Search uses PostgreSQL FTS/trigram with bounded limits.
- A local cache with TTL, tags, and LRU-like eviction.
- Public HTTP cache only for guest GET/HEAD and `Vary: Accept, Cookie`.

### Future cost

The cache is per-process. With more workers/processes, each process has its own
view and invalidation is not distributed. Today this is fine because the cache
is treated as a perishable accelerator. At 10k users it can still hold if TTLs
and queries are sane. At 100k users, the project needs to decide between staying
with a conservative local cache and introducing a shared cache only for
well-defined reads.

Search inside PostgreSQL is the right early choice. At high scale it can remain
valid, but only with budgets, indexes, and dataset evidence; it should not be
replaced preemptively.

### Debt

ARCHITECTURAL: keep the local cache while it suffices; prepare a cache adapter
only when real metrics require it.

## Operations

### What works

- `Config` validates the runtime, OS, production secrets, and Hypnotoad
  profiles.
- `Bootstrap::Operations` installs the request id, DB query stats, budget
  headers, metrics snapshot, readiness, and rate limiter.
- Deploy templates for systemd/nginx/freebsd/launchd exist.
- CI uses a PostgreSQL service and applies the migrations.

### Future cost

Operations is good enough for a small team. Future cost comes from:

- environment profiles that are not yet separated as versioned objects;
- rollback/restore that is still more runbook than automation;
- manual query budget endpoint mapping in `Bootstrap::Operations`;
- readiness that also depends on application catalogs that must be synchronized;
- cross-platform deployment that widens the support surface.

### Debt

OPERATIONAL: reduce drift between dev/staging/prod with explicit profiles and
automated evidence.

## Future evolution

### 1,000 users

Probability of staying maintainable: high.

The SSR monolith, PostgreSQL, DBIC, query budgets, and the local cache are
coherent. The main cost will be operational: backups, mail, staging, metrics,
and small controller regressions.

### 10,000 users

Probability of staying maintainable: medium-high.

Discipline is needed on:

- indexes and query plans on a real dataset;
- outbox throughput;
- search projection;
- cache TTLs;
- moderation and privacy workflows;
- controller reduction.

No rewrite is needed. What is needed is avoiding feature spread.

### 100,000 users

Probability of staying maintainable without substantial refactors: medium-low.

The system can still be a modular monolith, but it requires:

- partition/retention lifecycle;
- more measured search and feeds;
- more explicit APIs/read models;
- a more formal cache/invalidation strategy;
- a controlled outbox/worker topology;
- multi-process/multi-host deploy profiles and observability.

It is not the user count itself that breaks the project; it is the combination
of data volume, privacy/moderation workflows, and external integrations.

## Impact of strategic evolutions

| Evolution | Impact on the codebase | Risk if done now | Technical note |
| --- | --- | --- | --- |
| Federation | Very high | High | Requires far stricter event contracts, identity mapping, moderation propagation, and retry semantics. |
| OAuth/OIDC | Medium | Medium | Integrable, but `Identity::Store` must be split into credentials/sessions/tokens/profile. |
| Public APIs | High | High | SSR controllers are not a good stable API boundary; an API adapter over services/workflows is needed. |
| Mobile app | High | Medium-high | Similar to public APIs; requires payload/versioning and more explicit auth/session contracts. |
| Multi-site | Very high | High | The schema shows no global tenancy; adding it late is expensive. |
| Plugin system | High | High | The registry/hook dispatcher are small; turning them into an ecosystem before the core contracts stabilize would be risky. |

## Priority debts

| Debt | Type | Horizon | Cost if ignored |
| --- | --- | --- | --- |
| Large controllers and duplicated HTTP helpers | CODE QUALITY | 0-12 months | High |
| `Identity::Store` too wide | ARCHITECTURAL | done: facade over dedicated stores | Low |
| Non-uniform write workflows | ARCHITECTURAL | 0-12 months | Medium-high |
| Domain model too implicit | STRATEGIC | 12-24 months | Medium-high |
| Partition/retention lifecycle | OPERATIONAL | before data growth | High |
| Process-local cache/invalidation | ARCHITECTURAL | only if it scales | Medium |
| Premature plugin/federation/API contracts | STRATEGIC | only if the roadmap confirms | High |
| Long tests that are fragile against regexes | OPERATIONAL | ongoing | Medium |

## What NOT to change

- Do not replace Mojolicious/SSR: it fits the product and keeps the system
  simple.
- Do not introduce microservices: the codebase still benefits from the modular
  monolith.
- Do not replace PostgreSQL/DBIC without evidence: the schema is a strength, not
  an immediate limit.
- Do not add a distributed cache, Redis, or an external search engine without
  measured saturation.
- Do not turn the bootstraps into a complex DI framework; making the main
  workflows more explicit is enough.
- Do not expand plugins/federation/public APIs before the application boundaries
  stabilize.

## What to refactor within 12 months

1. Extract the common HTTP helpers into `GPForum::Web::*`: auth required, CSRF
   failure, JSON/HTML error payload, redirect helpers, permission denial, and
   current user.
   `Web::Guard`, `Web::Access`, `Web::RealtimeAccess`, `Web::CookieSession`,
   `Web::PublicCacheAccess`, `Web::HomeAccess`, `Web::IdentityAccess`,
   `Web::DiscoveryAccess`, `Web::ForumAccess`, `Web::AttachmentAccess`,
   `Web::NotificationAccess`, `Web::ModerationAccess`, `Web::PrivacyAccess`,
   `Web::AdminAccess`, and `Web::OperationsAccess` cover the shared contracts,
   the home `home_unavailable`, the identity text errors, the crawler document
   limits/rendering, the forum HTTP limits/validations, the attachment HTTP
   limits/filenames, the notification HTTP limits, the moderation HTTP
   limits/filters, the privacy HTTP limits/conflicts, the admin HTTP limits, the
   realtime connect/subscribe hashes, and the `/metrics` token. The success
   statuses of HTTP writes (admin catalog/binding, moderation
   content/queue/suspension, privacy review, community bookmark/subscription)
   live on the same `Web::*Access` objects.
2. Shrink `Controller::Forum`: separate read pages, write commands, community
   actions, and search handlers.
3. Shrink `Controller::Identity`: separate login/session, password lifecycle,
   email lifecycle, settings, and profile rendering.
4. Split `Identity::Store`: done. The facade delegates to `CredentialStore`,
   `SessionStore`, `TokenStore`, `Audit`, `PreferenceStore`, `AccountStore`,
   `AuthStore`, and `RegistrationStore`, with `Identity::Workflow` on top.
   `Password`, `SessionToken`, and `Service::Id` load `Crypt::URandom` lazily;
   the store and the credential/session/token collaborators load `Service::Id`
   lazily.
5. Unify the write workflows: command input, idempotency, transaction,
   event/audit/outbox, response.
   Audit hashing lives in `Infrastructure::AuditRecord`; `EventRecorder` remains
   EventLog/Outbox/AuditLog persistence and chain lookup, and loads
   `Service::Id` lazily together with `Outbox::MessageBuilder` and the
   event-backed stores that used it only for the default. Outbox
   classification, retry, and claim SQL live in `FailureType`, `Retry`, and
   `ClaimQuery`. Attachment envelopes and payloads live in
   `Attachment::Event`. The attachment orphan cleanup policy lives in
   `Attachment::Lifecycle`, including the link fetch caps. Privacy envelopes and
   payloads live in `Privacy::Event`, including retention holds. Identity
   envelopes and audit live in `Identity::Event`, including login and logout.
   Moderation action envelopes and audit live in `Moderation::Event`, including
   reports and suspensions. Admin catalog and binding audit live in
   `Admin::Event`.
6. Make the operational profiles explicit: dev, staging, production-small,
   production-medium.
7. Version the DB lifecycle: partitions, retention, archiving, restore evidence.

## What to refactor only if the project grows

- A shared cache adapter beyond `LocalCache`.
- An external search backend or a separate search service.
- An API versioning layer for mobile/public clients.
- Multi-site tenancy.
- An isolated plugin runtime.
- Federation / an event bridge.
- Sharding or worker/read-model separation.

This work is expensive and should not be anticipated without real pressure.

## What is already good enough

- The modular monolith as a general shape.
- PostgreSQL as the primary database.
- DBIC result classes and tracked migrations.
- Outbox/retry/dead-letter as a pattern.
- Query budgets and query-plan evidence.
- Centralized security/operations bootstraps.
- View models separated from templates.
- CI with Perl::Critic/perltidy/syntax/test/coverage/benchmark.
- The Hypnotoad/systemd/nginx deployment shape.

## Final estimate

How likely is GPForum to stay maintainable in 5 years without a rewrite?

Technical estimate: 70%.

That probability rises toward 80% if the project stays focused on the forum core
and completes the refactors on controllers, the identity store, and the write
workflows within 12 months.

It falls toward 45-50% if the next 12-18 months add federation, public APIs, a
mobile app, multi-site, and a plugin ecosystem without first strengthening the
application boundaries.

Conclusion: GPForum does not need a rewrite. It needs to protect its core,
shrink the large controllers, and make the application workflows more explicit
before the product surface grows.
