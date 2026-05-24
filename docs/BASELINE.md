# GPForum Baseline

Baseline date: 2026-05-24.

This file records commit 1 for GPForum consolidation: audit, CI, and baseline.
It intentionally does not introduce product features or architectural redesign.

## Repository State

| Area | Current state |
| --- | --- |
| Application | Perl-first Mojolicious modular monolith |
| Persistence | DBIx::Class over PostgreSQL authoritative storage |
| Async | Minion worker boundaries and transactional outbox |
| Forum surface | home, categories, category, thread, thread replies, search, bookmarks, feed |
| Governance surface | admin roles/permissions/audit, moderation reports/actions/suspensions |
| Operational surface | health/live/ready, metrics, platform check, query budget, profiling scripts |
| Security surface | Argon2id password service, CSRF, session tokens, rate limiter, browser security headers |
| Architecture discipline | service boundaries, controller persistence ban, OS abstraction, query budget catalog |
| Dependency discipline | Carton lockfile and CPAN license review gate |

## Commands Required By Baseline

```sh
carton check
git diff --check
script/bootstrap-deps --postgres
script/cpan-license-check
script/perltidy-check
script/perlcritic --severity 5
script/architecture-check
script/query-plan-check
script/query-plan-evidence --check
carton exec prove -lr t
script/query-budget --check
script/coverage
```

`script/query-budget --check` requires `DBD::Pg`, a database with migrations
applied, and the query budget catalog synchronized. CI performs:

```sh
carton exec bin/gpforum-migrate --apply
script/query-budget --sync
script/query-budget --check
```

## Results Recorded

The current local baseline passes:

| Command | Result |
| --- | --- |
| `carton exec prove -lr t` | passing |
| `script/perlcritic --severity 5` | passing |
| `script/perltidy-check` | passing |
| `script/architecture-check` | passing |
| `script/query-plan-check` | passing with 21 indexed hot-path checks |
| `script/query-plan-evidence --dry-run` | passing |
| `script/query-plan-evidence --check` | attempted locally; fails clearly because optional `DBD::Pg` is not installed; enforced in CI after PostgreSQL setup and deterministic seed |
| `script/cpan-license-check` | passing |
| `script/coverage` | passing |
| `script/query-budget --check` | attempted locally; fails in this Carton tree because optional `DBD::Pg` is not installed; enforced in CI with `script/bootstrap-deps --postgres` |

Latest full test suite at baseline time:

```text
Files=54, Tests=2709, Result=PASS
```

Latest coverage gate at baseline time:

```text
Total coverage: 93.0%
```

Remote GitHub Actions were triggered for this baseline commit, but GitHub did
not start the jobs because the account billing/spending limit blocked runner
execution. No repository failure log was produced by the remote runner.

## Tests Present

The repository currently has 54 `.t` files covering:

* load/config/health/home;
* identity registration, web forms, profile, session token service;
* database mappings and SQL migration intent;
* forum thread/post stores, pagination, readers, web flows, SSR accessibility;
* event, audit, outbox, projection offsets and generations;
* search, public discovery, feeds, sitemap/robots/metadata;
* notifications, realtime, read-state, bookmarks, mentions and community flows;
* moderation review and web workflows;
* admin roles, authorization and bootstrap;
* attachments, import/export, plugins, privacy rights;
* OS performance abstraction, filesystem, platform check, query budget;
* local cache, benchmark harness, query-plan gate and browser security headers.

## Areas Scoperte

* PostgreSQL benchmark seed exists with deterministic `small`, `medium`, and
  `hot-thread` profiles, but local DB-backed execution still requires optional
  `DBD::Pg`.
* Query plan verification now has a DB-backed `EXPLAIN (ANALYZE, BUFFERS)`
  evidence command, enforced in CI after migrations and seed data.
* Realtime remains process-local and covered as an enhancement boundary.
* CI validates migrations on PostgreSQL, but local baseline without PostgreSQL
  does not run `script/query-budget --check` unless a database is configured.
* Coverage is strong overall, but benchmark fixture support has lower line
  coverage because it exists mainly to support measurement harnesses.

## Technical Debt

* Add archived medium-profile PostgreSQL evidence output once local/remote
  runner PostgreSQL execution is available.
* Add observed DB query counters to configured HTTP benchmark output.
* Continue expanding negative authorization tests for edge combinations around
  admin, moderation and session expiry.
* Promote hot-thread benchmark evidence to a longer manual/nightly gate.
* Keep `docs/CPAN_LICENSE_REVIEW.md` synchronized with every `cpanfile` change.

## Next Priorities

1. Run medium-profile DB-backed evidence and archive JSON reports.
2. Add observed DB query counting around configured HTTP benchmark routes.
3. Coverage cleanup for benchmark fixture/support modules or documented exclusion.
