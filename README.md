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
[![Prompt Constitutions](https://img.shields.io/badge/prompt%20constitutions-44-a6532f.svg)](prompt)
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
* 44 architectural prompt constitutions in [prompt](prompt);
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
* server-rendered identity routes for registration, login, logout, and public profiles;
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
* moderation review boundaries for reports, reversible moderation actions, suspensions, and admin audit review;
* admin authorization boundaries for role catalogs, scoped role bindings, permission review, and audit-backed role changes;
* import/export portability boundaries for manifest validation, dry-run import jobs, legacy id mapping, failure reporting, and privacy-aware export manifests;
* automation scripts in [script](script).

The current implementation has reached **Milestone 13: Import Export Portability** service
boundaries under the constraints in [prompt/20.txt](prompt/20.txt).

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

## License

BSD-3-Clause. See [LICENSE](LICENSE).
