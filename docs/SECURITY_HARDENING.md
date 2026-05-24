# GPForum Security & Abuse Hardening

Hardening date: 2026-05-24.

This document records the second consolidation iteration. It does not introduce
new user-facing features. It strengthens existing session, rate-limit,
authorization, CSRF, anti-leak and abuse-control paths.

## Current Guarantees

* Login overwrites pre-authenticated identity markers and issues a fresh
  `login_rotation` marker.
* Web sessions carry an explicit `session_expires_at_epoch`; stale sessions are
  expired before route dispatch.
* Logout remains idempotent: a missing or already-revoked server session still
  returns the same accepted logout response after CSRF validation.
* Rate limiting is PostgreSQL-backed when the database is available and falls
  back to local memory in explicitly degraded mode.
* Rate-limit blocks are audit-backed when a schema is available.
* Security telemetry counts CSRF failures, authorization denials, rate-limit
  hits and suspended-user participation blocks without exposing raw actors,
  passwords, IP addresses or submitted content.
* Hidden, deleted and private content remains excluded from public discovery
  surfaces and autocomplete responses.

## Route Security Matrix

| Route | Auth requirement | CSRF | Rate limit | Permission |
| --- | --- | --- | --- | --- |
| `POST /register` | anonymous allowed | required | `identity.register` | none |
| `POST /login` | anonymous allowed | required | `identity.login` | none |
| `POST /logout` | anonymous allowed, idempotent | required | `identity.logout` | session revoke if present |
| `POST /threads` | authenticated | required | `thread.create` | active participation |
| `POST /t/:thread_id/replies` | authenticated | required | `reply.create` | active participation and unlocked thread |
| `POST /t/:thread_id/read` | authenticated | required | `thread.read` | visible thread |
| `POST /t/:thread_id/bookmark` | authenticated | required | `thread.bookmark` | visible thread |
| `POST /t/:thread_id/bookmark/remove` | authenticated | required | `thread.bookmark.remove` | visible thread |
| `POST /t/:thread_id/subscribe` | authenticated | required | `thread.subscribe` | visible thread |
| `POST /t/:thread_id/subscribe/mute` | authenticated | required | `thread.subscription.mute` | visible thread |
| `POST /t/:thread_id/subscribe/remove` | authenticated | required | `thread.unsubscribe` | visible thread |
| `POST /t/:thread_id/report` | authenticated | required | `report.create` | visible thread |
| `POST /p/:post_id/report` | authenticated | required | `report.create` | visible post and thread |
| `POST /notifications/:notification_id/read` | authenticated | required | `notification.read` | recipient owns notification |
| `POST /admin/*` | authenticated | required | request path budget | `admin_console.manage` |
| `POST /moderation/*` | authenticated | required | request path budget | resource/action specific moderation permission |
| `GET /search/autocomplete` | anonymous or authenticated | not applicable | `search.autocomplete` | permission-aware search projection |

## Abuse Controls

| Abuse vector | Control |
| --- | --- |
| Session fixation | login removes prior identity markers and rotates `login_rotation` |
| Expired session reuse | `before_dispatch` expires stale sessions |
| Credential stuffing | login/register rate limits through PostgreSQL-backed limiter |
| Report spam | `report.create` has a tighter write limit and duplicate open reports are blocked |
| Mention fanout | mention recording caps fanout and audits skipped excess mentions |
| Bookmark/subscription churn | bookmark and subscription writes use tighter per-action limits |
| Suspended-user posting | thread/reply creation records `suspended_user_block` and returns `403` |
| Hidden-content discovery | search, profile, feed, sitemap, Atom and autocomplete tests reject leaks |

## Observability

`/metrics` exposes:

* `rate_limits.store`;
* `rate_limits.status`;
* `rate_limits.stats.checks`;
* `rate_limits.stats.blocked`;
* `rate_limits.stats.primary_failures`;
* `rate_limits.stats.fallback_used`;
* `security.events.csrf_failure.count`;
* `security.events.auth_denial.count`;
* `security.events.rate_limit_hit.count`;
* `security.events.suspended_user_block.count`.

Security metrics intentionally do not expose raw usernames, IP addresses,
passwords, body text, search text, report details or private content.

## Verification

Latest local hardening verification:

| Command | Result |
| --- | --- |
| `carton check` | passed |
| `git diff --check` | passed |
| `script/perltidy-check` | passed |
| `script/perlcritic --severity 5` | passed |
| `script/architecture-check` | passed |
| `script/query-plan-check` | passed with 23 indexed hot-path checks |
| `carton exec prove -lr t` | passed: 55 files, 2738 tests |
| `script/coverage` | passed: total coverage 93.1% |
| `script/query-plan-evidence --dry-run` | passed |
| `script/benchmark-http --fixture --check --iterations 5 --warmup 1` | passed |
| `script/query-budget --check` | requires optional `DBD::Pg` and a configured PostgreSQL runtime; not runnable in this local Carton tree |

## PostgreSQL Rate Limit Storage

The `rate_limit_buckets` table is keyed by:

```text
scope, actor_hash, action, window_started_at
```

Actors are stored as salted-by-scope hashes, not raw addresses or usernames.
The table is disposable operational state, but PostgreSQL-backed storage makes
limits coherent across GPForum web workers.

## Residual Risks

* Local fallback rate limiting is process-local and only acceptable in degraded
  mode.
* PostgreSQL-backed rate-limit checks require the `016_security_abuse_hardening`
  migration to be applied.
* DB-backed denial and rate-limit evidence still needs a seeded PostgreSQL run
  on an environment with `DBD::Pg`.
* Advanced bot heuristics and device/session anomaly detection remain future
  hardening work.
