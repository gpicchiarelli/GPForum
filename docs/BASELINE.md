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
| Load evidence | observed DB query counters, deterministic seed profiles, DB-backed query-plan evidence |
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
script/bench-hotpaths
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
| `script/query-plan-check` | passing with 25 indexed hot-path checks and DB-backed evidence when `GPFORUM_DATABASE_DSN` is configured |
| `script/query-plan-evidence --dry-run` | passing |
| `script/query-plan-evidence --check --profile small|medium|hot-thread` | passing against a seeded PostgreSQL 18.4 Postgres.app evidence database |
| saved benchmark baseline check | passing with `script/benchmark-http --fixture --check --baseline ...` |
| configured benchmark profiles | passing with observed DB query counters for `small`, `medium`, and `hot-thread` |
| Hypnotoad benchmark smoke | passing locally against Postgres.app with 2 workers and observed query headers |
| OS runtime evidence smoke | passing; direct Hypnotoad smoke reports socket probes, event-loop mismatch, PostgreSQL settings availability, and temp filesystem mount |
| Hypnotoad worker scaling smoke | passing locally across 2/4/8 workers on real forum/search routes |
| `script/cpan-license-check` | passing |
| `script/coverage` | passing |
| `script/query-budget --check` | passing against synchronized PostgreSQL-backed query budget rows |

Latest full test suite at baseline time:

```text
Files=59, Tests=2901, Result=PASS
```

Latest coverage gate after Hypnotoad deployment evidence hardening:

```text
Total coverage: 89.3%
```

The coverage gate remains passing. The percentage changed after adding
benchmark/seed observability branches, the DB query observer, and the Hypnotoad
server lifecycle harness; targeted tests cover the request counter, metrics
exposure, profile-aware benchmark output, deterministic seed behavior,
query-plan profile metadata, and Hypnotoad report parsing/threshold logic. The
remaining lower-coverage branches are live process start/stop and failure
fallbacks that are exercised by the deployment evidence command rather than by
unit tests.

Remote GitHub Actions were triggered for this baseline commit, but GitHub did
not start the jobs because the account billing/spending limit blocked runner
execution. No repository failure log was produced by the remote runner.

## Tests Present

The repository currently has 59 `.t` files covering:

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
  `hot-thread` profiles; the local Postgres.app evidence run has verified all
  three profiles materially.
* Security hardening now includes PostgreSQL-backed rate-limit storage,
  observable local fallback, session-expiry enforcement, duplicate-report
  blocking and mention fanout limits.
* Query plan verification now has a DB-backed `EXPLAIN (ANALYZE, BUFFERS)`
  evidence command; `script/query-plan-check` invokes it automatically when a
  database DSN is configured and CI runs it after migrations and seed data.
* Configured HTTP benchmarks now report observed DB query counters, duplicate
  SQL fingerprints and query-budget mismatches.
* Hypnotoad deployment evidence now starts a temporary prefork runtime, records
  worker metadata, compares against in-process results, and observes DB query
  budgets through benchmark-only headers.
* Hypnotoad worker scaling evidence now runs the same real forum/search route
  set across configurable worker counts such as `2,4,8`.
* OS runtime evidence now records the declared OS backend, actual Mojolicious
  reactor class, Hypnotoad `reuse=1` configuration, kernel socket option
  probes, PostgreSQL runtime settings, and the temporary filesystem mount used
  by benchmark runs.
* Realtime remains process-local and covered as an enhancement boundary.
* CI validates migrations on PostgreSQL; local `script/query-budget --check`
  requires an installed PostgreSQL driver and a configured evidence database.
* Coverage is strong overall, but benchmark fixture support has lower line
  coverage because it exists mainly to support measurement harnesses.

## Technical Debt

* Archive medium/hot-thread PostgreSQL evidence JSON as CI artifacts once
  runner limits allow longer configured benchmark jobs.
* Add reverse-proxy benchmark evidence in front of Hypnotoad; current
  deployment evidence measures direct Hypnotoad only.
* Continue expanding negative authorization tests for less common staff
  permission combinations and long-lived session edge cases.
* Promote hot-thread benchmark evidence to a longer manual/nightly gate.
* Keep `docs/CPAN_LICENSE_REVIEW.md` synchronized with every `cpanfile` change.

## Next Priorities

1. Add reverse-proxy benchmark evidence in front of Hypnotoad.
2. Archive medium/hot-thread JSON evidence in CI artifacts.
3. Add longer soak checks for worker RSS drift on hot-thread rendering.
