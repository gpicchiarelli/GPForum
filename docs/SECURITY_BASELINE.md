# GPForum Security Baseline

Date: 2026-05-24.

This is the security hardening baseline. It strengthens existing HTTP workflows
without adding new product features, external services, Redis, OpenSearch, or a
new authentication architecture.

## Scope

| Area | Status after this commit |
| --- | --- |
| CSRF | Every current server-rendered POST form includes `csrf_field`; every current POST route is covered by functional missing-token tests. |
| Session cookies | Development cookies are `HttpOnly` and `SameSite=Lax`; production cookies are additionally `Secure`. |
| Login/register/logout | CSRF protected, rate limited, generic rate-limit errors, non-enumerative duplicate-registration response, login/logout audit hooks. |
| Session rotation | Existing cookie-session payload is changed on accepted login through a rotation marker; stale session markers are expired before dispatch. |
| Rate limiting | PostgreSQL-backed bucket store with explicit local degraded fallback. |
| Admin authorization | Anonymous requests return `401`; permission-denied users return `403`; POST routes require CSRF before authorization checks. |
| Moderation authorization | Anonymous requests return `401`; permission-denied users return `403`; POST routes require CSRF before authorization checks. |
| Forum write authorization | Thread/reply/read/bookmark/subscription/report POSTs require CSRF and an authenticated session. |
| Audit | Registration, thread, post, report, admin role binding, moderation actions, suspension actions, login requests, and logout requests have audit paths. |
| Abuse telemetry | CSRF failures, authorization denials, rate-limit hits and suspended-user blocks are exposed through `/metrics` without sensitive data. |
| Escaping | Templates use escaped output by default; raw post body rendering remains restricted to the sanitized body boundary. |

The current route-by-route hardening matrix is maintained in
`docs/SECURITY_HARDENING.md`.

## Commands

Security-focused commands:

```sh
carton exec prove -lr t/06-identity-web.t t/43-moderation-web.t t/44-admin-web.t t/48-browser-security.t t/50-security-hardening.t
script/perlcritic --severity 5
script/perltidy-check
```

Result:

* security-focused test set passed: 6 files, 413 tests;
* `script/perlcritic --severity 5` passed;
* `script/perltidy-check` passed.

Full baseline commands:

```sh
carton exec prove -lr t
script/architecture-check
script/query-plan-check
```

Result:

* full test suite passed: 55 files, 2767 tests;
* `script/architecture-check` passed;
* `script/query-plan-check` passed with 23 indexed query plans, 0 `OFFSET`
  violations, and DB-backed evidence activation when a DSN is configured;
* `git diff --check` passed.

`script/query-budget --check` now passes when pointed at the local Postgres.app
evidence database with synchronized budget rows.

## Negative Coverage Added

The security hardening test suite now covers:

* anonymous valid-CSRF requests to authenticated-only forum, notification,
  admin, and moderation POST routes;
* missing-CSRF requests to every current POST route;
* normal-user denial across admin and moderation boundaries;
* expired-session denial for protected notification reads;
* moderator-looking sessions without explicit permission denied on suspension
  queues and suspension writes;
* hidden fixture content excluded from public Atom, sitemap, and search
  surfaces;
* duplicate registration responses that do not disclose whether the username or
  email already exists;
* login/register rate limiting;
* PostgreSQL rate-limit fallback behavior and audit rows for blocked requests;
* report duplicate blocking without duplicate domain events;
* mention fanout limiting with audit rows;
* login/logout audit hook invocation;
* session-fixation regression through login marker rotation;
* cookie `HttpOnly`, `SameSite`, and production `Secure` flags.

## Sensitive Audit Behavior

`GPForum::Service::Identity::SecurityAudit` records login/logout audit rows
without storing raw identifiers or request addresses. Login identifiers and
request addresses are SHA-256 hashed before entering audit metadata.

## Residual Risks

* Email verification is still not implemented; registration creates accounts
  that can authenticate before a verification workflow is added.
* Local fallback rate limiting is still process-local and is acceptable only as
  degraded mode.
* DB-backed security evidence requires migration `016_security_abuse_hardening`
  and has been smoke-tested against the local Postgres.app evidence database.
* Raw post body rendering in `templates/forum/thread.html.ep` assumes the
  `PostComposer`/`post_bodies.body_rendered_safe` sanitizer boundary. That
  invariant is tested, but a future richer renderer must keep the same contract.
* Audit hash-chain fields exist, but external checkpoint notarization is not yet
  implemented.

## Next Security Priorities

1. Add email verification and account activation policy on top of the existing
   identity schema.
2. Run PostgreSQL-backed abuse tests on a seeded database and archive evidence.
3. Add explicit audit rows for failed credential verification with careful
   anti-enumeration and rate-limit behavior.
