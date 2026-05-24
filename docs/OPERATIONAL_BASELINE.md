# GPForum Operational Baseline

This document captures the current consolidation baseline for GPForum. It is
kept intentionally operational: it records what exists, what is measured, and
where the next conservative work should land.

## Repository Map

| Surface | Current reality | State |
| --- | --- | --- |
| HTTP routes | home, discovery, health, metrics, admin, forum, moderation, notifications, identity, search, realtime | MVP funzionante |
| Controllers | `Home`, `Discovery`, `Health`, `Operations`, `Admin`, `Forum`, `Moderation`, `Notifications`, `Identity`, `Realtime` | MVP funzionante |
| Services | explicit service layer under `lib/GPForum/Service` for forum, identity, search, notifications, moderation, admin, projection, outbox, OS, operations | già stabile |
| DBIx::Class results | canonical, projection, audit, event, outbox, moderation, admin, attachment, privacy, plugin, feed/read-state classes | già stabile |
| Workers | Minion registrar plus notification, media, cache, search, attachment handlers | MVP funzionante |
| Tests | 46 test files covering architecture, SSR accessibility, web flows, query budget, OS hardening, cache, moderation, admin, profile, read-state | già stabile |
| Scripts | test, coverage, critic, migration, platform check, query budget, system preflight, profiling route | MVP funzionante |
| Constitutions | 53 prompt documents covering architecture, DB, security, UX, performance, trust, accessibility, engineering discipline | già stabile |

## Risk Classification

| Area | Classification | Main risk | Next conservative action |
| --- | --- | --- | --- |
| Forum SSR traversal | MVP funzionante | regressions in permission-safe rendering | keep route smoke and accessibility tests mandatory |
| Admin/moderation | MVP funzionante | authorization drift | expand negative permission tests before feature growth |
| Search/discovery | MVP funzionante | metadata/feed leakage | keep anti-leak tests near every new discovery path |
| Browser security | MVP funzionante | response/security header drift | keep security header smoke tests mandatory |
| Realtime | contract-only/MVP boundary | process-local behavior only | keep fallback documented and non-authoritative |
| Benchmarks | incompleto | no p50/p95/p99 baseline | add deterministic local HTTP benchmark harness |
| Query topology | MVP funzionante | budget exists but needs CI enforcement against a real DB | run migrations, query-budget check, and query-plan check in CI |
| CPAN governance | incompleto | new dependency can bypass review | require license review rows for every `cpanfile` dependency |
| Formatting | MVP funzionante | no non-mutating perltidy CI gate | add `script/perltidy-check` |

## Priority List

1. Enforce CI baseline: tests, critic, perltidy, architecture-check, coverage,
   dependency review, query budget, and local platform check.
2. Add deterministic local HTTP benchmark harness for hot SSR/API routes.
3. Add documented benchmark thresholds and report format.
4. Keep `script/query-plan-check` synchronized with selected hot queries and indexes.
5. Add negative authorization tests for admin/moderation boundaries.
6. Extend security tests around CSRF/rate-limit/session expiry paths.
7. Keep feed/sitemap/metadata anti-leak tests aligned with every discovery
   change.
8. Keep DB indexes and query budget synchronized with hot path changes.
9. Avoid new user features until benchmark and security baselines are stable.
10. Keep GitHub Actions as the external release gate for every main branch push.
