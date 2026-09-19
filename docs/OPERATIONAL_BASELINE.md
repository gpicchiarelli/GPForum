# GPForum Operational Baseline

This document captures the current consolidation baseline for GPForum. It is
kept intentionally operational: it records what exists, what is measured, and
where the next conservative work should land.

Last local verification: 2026-05-26, with `script/test`,
`script/perltidy-check`, `script/perlcritic --severity 5`,
`script/architecture-check`, and `script/query-plan-check`.

## Repository Map

| Surface | Current reality | State |
| --- | --- | --- |
| HTTP routes | home, discovery, health, metrics, admin, forum, moderation, notifications, identity, search, realtime | MVP funzionante |
| Controllers | `Home`, `Discovery`, `Health`, `Operations`, `Admin`, `Forum`, `Moderation`, `Notifications`, `Identity`, `Realtime` | MVP funzionante |
| Services | explicit service layer under `lib/GPForum/Service` for forum, identity, search, notifications, moderation, admin, projection, outbox, OS, operations | già stabile |
| DBIx::Class results | canonical, projection, audit, event, outbox, moderation, admin, attachment, privacy, plugin, feed/read-state classes | già stabile |
| Workers | Minion registrar plus notification, media, cache, search, attachment handlers | MVP funzionante |
| Tests | 59 test files covering architecture, SSR accessibility, web flows, query budget, query-plan evidence, OS hardening, cache, moderation, admin, profile, read-state, security abuse hardening, benchmark harnesses, and Hypnotoad scaling | già stabile |
| Scripts | test, coverage, critic, perltidy, migration, platform check, query budget, query-plan evidence, system preflight, local HTTP benchmark, Hypnotoad benchmark, Hypnotoad scaling, profiling route | MVP funzionante |
| Constitutions | 53 prompt documents covering architecture, DB, security, UX, performance, trust, accessibility, engineering discipline | già stabile |

## Risk Classification

| Area | Classification | Main risk | Next conservative action |
| --- | --- | --- | --- |
| Forum SSR traversal | MVP funzionante | regressions in permission-safe rendering | keep route smoke and accessibility tests mandatory |
| Admin/moderation | MVP funzionante | authorization drift | expand negative permission tests before feature growth |
| Search/discovery | MVP funzionante | metadata/feed leakage | keep anti-leak tests near every new discovery path |
| Browser security | MVP funzionante | response/security header drift | keep security header smoke tests mandatory |
| Realtime | contract-only/MVP boundary | process-local behavior only | keep fallback documented and non-authoritative |
| Benchmarks | MVP funzionante | thresholds are intentionally loose and evidence can drift if not refreshed | keep fixture, configured PostgreSQL, and Hypnotoad evidence in CI/local release checks |
| Query topology | MVP funzionante | DB-backed evidence depends on a configured PostgreSQL dataset | run migrations, seed, query-plan evidence, query-budget check, and platform check in CI |
| CPAN governance | MVP funzionante | new dependency can bypass review if `cpanfile` and review docs drift | keep `script/cpan-license-check` mandatory for every dependency change |
| Formatting | MVP funzionante | formatting drift if perltidy version or generated code changes | keep `script/perltidy-check` as a non-mutating CI gate |

## Priority List

1. Enforce CI baseline: tests, critic, perltidy, architecture-check, coverage,
   dependency review, query-plan evidence, query budget, benchmark smoke, and
   local platform check.
2. Keep deterministic benchmark evidence fresh for fixture, configured
   PostgreSQL, and Hypnotoad routes.
3. Keep documented p50/p95/p99/req-s thresholds aligned with the benchmark
   command output and release-gate tolerance.
4. Keep `script/query-plan-check` and `script/query-plan-evidence`
   synchronized with selected hot queries and indexes.
5. Add more negative authorization tests for admin/moderation boundaries before
   expanding operator workflows.
6. Extend security tests around CSRF, rate-limit, session expiry, duplicate
   report abuse, and suspension edge cases.
7. Keep feed/sitemap/metadata/autocomplete anti-leak tests aligned with every discovery
   change.
8. Keep DB indexes and query budget synchronized with hot path changes.
9. Treat multi-process realtime fanout as the next production boundary only
   after PostgreSQL-backed evidence remains green.
10. Keep GitHub Actions as the external release gate for every main branch push.
