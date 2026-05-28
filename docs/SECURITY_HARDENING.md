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
* Signed-cookie identity is cross-checked against the server-side `sessions`
  row when both `session_id` and `user_id` are present; expired or revoked
  rows clear the web session.
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

| Route | Auth requirement | Permission | CSRF | Rate limit | Query budget |
| --- | --- | --- | --- | --- | --- |
| `POST /register` | anonymous allowed | none | required | `identity.register` | identity write path |
| `POST /login` | anonymous allowed | none | required | `identity.login` | identity read/write path |
| `POST /logout` | anonymous allowed, idempotent | session revoke if present | required | `identity.logout` | identity write path |
| `POST /threads` | authenticated | active participation | required | `thread.create` | `thread_create:6` |
| `POST /t/:thread_id/replies` | authenticated | active participation and unlocked thread | required | `reply.create` | `reply_create:6` |
| `POST /t/:thread_id/read` | authenticated | visible thread | required | `thread.read` | thread read-state path |
| `GET /feed` | authenticated | own feed projection | not applicable | no write limit | feed projection path |
| `GET /bookmarks` | authenticated | own bookmark projection | not applicable | no write limit | bookmark projection path |
| `POST /t/:thread_id/bookmark` | authenticated | visible thread | required | `thread.bookmark` | bookmark write path |
| `POST /t/:thread_id/bookmark/remove` | authenticated | visible thread | required | `thread.bookmark.remove` | bookmark write path |
| `POST /t/:thread_id/subscribe` | authenticated | visible thread | required | `thread.subscribe` | subscription write path |
| `POST /t/:thread_id/subscribe/mute` | authenticated | visible thread | required | `thread.subscription.mute` | subscription write path |
| `POST /t/:thread_id/subscribe/remove` | authenticated | visible thread | required | `thread.unsubscribe` | subscription write path |
| `POST /t/:thread_id/report` | authenticated | visible thread | required | `report.create` | `report_create:5` |
| `POST /p/:post_id/report` | authenticated | visible post and thread | required | `report.create` | `report_create:5` |
| `POST /notifications/:notification_id/read` | authenticated | recipient owns notification | required | `notification.read` | notification write path |
| `POST /admin/*` | authenticated | `admin_console.manage` or scoped admin permission | required | request path budget | admin budgets |
| `POST /moderation/*` | authenticated | resource/action specific moderation permission | required | request path budget | moderation budgets |
| `GET /search` | anonymous or authenticated | permission-aware search projection | not applicable | read path budget | `search:2` |
| `GET /search/autocomplete` | anonymous or authenticated | permission-aware search projection | not applicable | `search.autocomplete` | `search_autocomplete:2` |
| `GET /realtime` | authenticated websocket | `realtime.subscribe` per channel | same-origin handshake | `realtime.connect` / `realtime.subscribe` | realtime enhancement |

## Abuse Controls

| Abuse vector | Control |
| --- | --- |
| Session fixation | login removes prior identity markers and rotates `login_rotation` |
| Expired session reuse | `before_dispatch` expires stale cookie sessions and rejects expired server-side session rows |
| Credential stuffing | login/register rate limits through PostgreSQL-backed limiter |
| Report spam | `report.create` has a tighter write limit and duplicate open reports are blocked |
| Mention fanout | mention recording caps fanout and audits skipped excess mentions |
| Bookmark/subscription churn | bookmark and subscription writes use tighter per-action limits |
| Suspended-user posting | thread/reply creation records `suspended_user_block` and returns `403` |
| Hidden-content discovery | search, profile, feed, sitemap, Atom and autocomplete tests reject leaks |
| Realtime resource leaks | channel authorizer denies unknown channels by default and validates thread/category/moderation visibility |
| Cross-user notification read | notification websocket channels only allow `notifications:<own_user_id>` |
| Websocket CSRF/origin abuse | websocket handshake validates same-origin `Origin` when present |

## Observability

`/metrics` exposes:

* `rate_limits.store`;
* `rate_limits.status`;
* `rate_limits.rate_limit_allowed`;
* `rate_limits.rate_limit_blocked`;
* `rate_limits.degraded_rate_limiter_active`;
* `rate_limits.stats.checks`;
* `rate_limits.stats.blocked`;
* `rate_limits.stats.primary_failures`;
* `rate_limits.stats.fallback_used`;
* `security.events.csrf_failure.count`;
* `security.events.auth_denial.count`;
* `security.events.rate_limit_hit.count`;
* `security.events.suspended_user_block.count`.
* `security.events.realtime_subscription_denied.count`;
* `security.events.realtime_origin_denied.count`;
* `security.events.realtime_payload_rejected.count`.

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
| `script/query-plan-check` | passed with 23 indexed hot-path checks and DB-backed evidence |
| `carton exec prove -lr t` | passed: 55 files, 2767 tests |
| `script/coverage` | passed: total coverage 93.0% |
| `script/query-plan-evidence --dry-run` | passed |
| `script/benchmark-http --fixture --check --iterations 5 --warmup 1` | passed |
| `script/bench-hotpaths --iterations 1 --warmup 0 --route /health` | passed |
| `script/query-budget --check` | passed against synchronized PostgreSQL-backed query budget rows |

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
* DB-backed denial and rate-limit evidence now has a seeded PostgreSQL local
  smoke; broader medium/hot-thread abuse evidence remains future hardening work.
* Advanced bot heuristics and device/session anomaly detection remain future
  hardening work.
