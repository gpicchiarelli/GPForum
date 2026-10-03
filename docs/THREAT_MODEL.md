# Threat Model

What GPForum protects, from whom, where the trust boundaries are, and what
stands at each one. Every mitigation named here is in the code and pinned by
the test next to it. A mitigation without a test is listed as a residual risk,
not as a mitigation.

This model does not certify anything. The quality program's criterion for a
10 in security is this document **and** a penetration test by someone outside
the project; the second has not happened.

Reviewed: 2026-09-30. Review it with any ADR that moves a trust boundary, and
before each release.

## Assets

| Asset | Why it matters |
| --- | --- |
| Credentials | Argon2id password hashes in `credentials`; a leak must not yield passwords |
| Sessions | a session is the account: the cookie, the `sessions` row, its revocation |
| Restricted content | private and members-only spaces, categories, threads and posts (ADR 0102) |
| Hidden and deleted content | moderation decisions must hold on every surface, caches included |
| Uploads | files other members download; must not carry malware to them |
| Personal data | e-mail addresses, profiles, privacy exports and erasure (ADR 0074) |
| The audit chain | who did what in the console and in moderation, tamper-evident |
| Availability | the forum stays up under abuse, and degrades rather than fails |

## Actors

| Actor | Can | Wants |
| --- | --- | --- |
| Anonymous visitor or scraper | send any HTTP request, from many addresses | read restricted content, enumerate accounts, exhaust resources |
| Member | sign in, post, upload, subscribe, open websockets | read beyond their grants, act as another member, abuse other members |
| Pending account | register; cannot sign in until the e-mail is confirmed | the same, before proving the address |
| Suspended member | hold an old session | keep participating |
| Moderator or admin | the console, moderation writes | exceed their scope (see residual risks) |
| Operator | the shell, the configuration, the database | — trusted; mistakes are the threat |
| Network attacker | observe or alter traffic outside TLS | steal sessions |
| Supply chain | a compromised CPAN distribution | code execution in the application |

## Trust boundaries

```
browser ──TLS──▶ nginx / Caddy ──▶ Hypnotoad (GPForum) ──▶ PostgreSQL
                                     │   │   └──▶ GlifiStore (L2 cache, 127.0.0.1)
                                     │   └──────▶ clamd (UNIX socket)
                                     └──────────▶ SMTP relay
operator ──▶ bin/ commands ──▶ PostgreSQL        outbox workers ──▶ PostgreSQL
```

PostgreSQL is the only source of truth. GlifiStore and each process's own
cache are disposable copies of it; an unreachable L2 degrades, it never
decides.

## Threats and what stands against them

### The reverse proxy and the HTTP boundary

| Threat | Mitigation | Evidence |
| --- | --- | --- |
| Client names its own address in `X-Forwarded-For` to dodge rate limits | Hypnotoad believes the header only from `GPFORUM_RUNTIME_TRUSTED_PROXIES` (loopback by default) | `t/53-os-runtime-policy.t`, `t/01-config.t` |
| Session theft over plain HTTP | HSTS and `Secure` cookies wherever transport must be secure; the app listens on loopback | `t/48-browser-security.t` |
| Clickjacking, MIME sniffing, injected scripts | `X-Frame-Options: DENY`, `frame-ancestors 'none'`, `nosniff`, a same-origin CSP with no inline script | `t/48-browser-security.t` |
| Cross-site request forgery | every state-changing form carries a CSRF token checked before the action; session cookies are `SameSite=Lax` | `t/06-identity-web.t`, `t/50-security-hardening.t` |
| Junk query strings filling the page cache | the cache key names only locale, theme, path and page size | `t/integration/postgres-public-cache.t` |
| A malformed cursor reaching SQL | cursors are a position or timestamp plus a uuid, or the first page | `t/21-forum-pagination.t` |
| Anonymous clients reading the deployment's internals from the health endpoints (failing checks and their errors, replication slot names, environment, process counts, sockets, OS limits) | `/health/ready` and `/health` render their full report only with the `/metrics` token (Bearer or `X-GPForum-Metrics-Token`, rotation list included); anyone else, a wrong token included, reads the status alone, and the readiness code stays 200/503 either way; `/health/live` holds status, check and time | `t/300-health-report-access.t`, `t/integration/postgres-health-access.t`, `t/138-web-operations-access.t` |

### Identity and sessions

| Threat | Mitigation | Evidence |
| --- | --- | --- |
| Replaying a login without the password | logins are not idempotent commands; no token is stored in `command_log`; stored ones were scrubbed and their sessions revoked (migration 045) | `t/integration/postgres-login-replay.t` |
| Account enumeration by timing | an unknown or deleted account pays the same Argon2 verification as a wrong password | `t/111-identity-auth-store.t`, `t/04-services.t` |
| Password guessing | per address (10 / 5 min) and per account (20 / 5 min, every address together) | `t/203-login-account-limit.t` |
| A revoked session acting while the database hiccups | a session that cannot be validated gets 503, not its user | `t/177-session-validation-resilience.t` |
| Session fixation | login rotates the session and overwrites pre-authentication markers | `t/06-identity-web.t` |
| Offline cracking after a database leak | Argon2id with a per-password salt | `t/04-services.t` |

### Authorization and visibility (ADR 0102)

| Threat | Mitigation | Evidence |
| --- | --- | --- |
| Reading restricted content through any surface | one readability rule, applied to pages, lists, search, feeds, notifications, mentions, bookmarks, attachments, realtime and caches | `t/integration/postgres-effective-visibility.t`, `t/200-readable-lists.t` |
| A pending or suspended account reading as a member | only `active` accounts without a suspension in force are members; resolution failures read as anonymous | `t/integration/postgres-effective-visibility.t` |
| Replying into, or editing in, a thread locked or hidden meanwhile | replies and an author's post edits, deletes, restores and title edits re-check the thread (and post) under their row locks | `t/integration/postgres-concurrency.t` |
| Hidden content served from a cache | moderation purges page and category caches in every process; the L2 invalidates by tag token; an L1 copy expires with its L2 entry | `t/89-tiered-cache.t`, `t/integration/postgres-public-cache.t` |
| Console actions without the role | the permission gate on every admin and moderation route, denials logged | `t/44-admin-web.t`, `t/55-security-abuse-hardening.t` |

### Content and uploads

| Threat | Mitigation | Evidence |
| --- | --- | --- |
| Stored XSS through posts | the renderer escapes everything first, then adds a closed set of markup; links only on allowed schemes, with `rel` set | `t/179-forum-body-renderer.t`, `t/186-identity-and-markup-safety.t` |
| Malware in uploads | every upload is scanned by the system's ClamAV before it can be served; an infected or unscanned file is never served (ADR 0108) | `t/integration/clamav.t` (run against Homebrew's clamd 1.5.4 on 2026-09-30) |
| SQL injection | statements go through DBIx::Class or bound placeholders; no SQL is built from request text | code review; `t/191-resultset-context.t` guards the ORM usage |

### Availability

| Threat | Mitigation | Evidence |
| --- | --- | --- |
| A page that costs more queries as it grows (N+1) | each page's statements are budgeted and must not grow with its rows | `t/integration/postgres-query-budget.t` |
| Deep pages scanning whole threads | every keyset bounds its sort column | `t/integration/postgres-query-budget.t`, plan tests |
| A hung L2 stalling every request | a failing GlifiStore is skipped for 15 s | `t/89-tiered-cache.t` |
| A common-word search holding workers | search runs under its own statement timeout and ranks a capped candidate set (quality program 8.10) | `t/204-search-bounded-ranking.t`, `t/integration/postgres-search-plan.t` |
| Removing a huge thread exhausting the lock table | search documents are removed in bounded batches | `t/integration/postgres-search-remove-thread.t` |

### Supply chain

| Threat | Mitigation | Evidence |
| --- | --- | --- |
| A vulnerable CPAN dependency | the lock is audited against CPAN security advisories; every exclusion carries its reason | `script/cpan-audit`, `etc/cpan-audit-ignore.txt` |
| A dependency nothing uses widening the surface | the `cpanfile` declares what the code loads; unused distributions leave the lock | `t/182-dependency-declaration.t` |
| Tampered distributions | Carton installs from `cpanfile.snapshot` over HTTPS only | `script/bootstrap-deps` |

## Residual risks

- **No outside review.** Nobody outside the project has tried to break it.
  Until someone does, this model is the project's own reading.
- **Moderation writes ignore scoped role bindings.** A moderator bound to one
  category can act beyond it through the console's write paths. This is an
  owner decision, recorded in the quality program.
- **Category and space readability, and a move's target category,** are
  checked in the workflow, not again under the row lock: a visibility change
  committed between the two lets the write through (reads still apply
  effective visibility, so nothing leaks).
- **The audit chain's forum-wide advisory lock** serialises every audited
  write; under load it is an availability risk (ADR 0020, ADR 0111).
- **Per-process realtime quotas.** The per-user connection limit is a memory
  bound per process; the cross-node control is the connect rate limit.
- **Degraded rate limiting.** When PostgreSQL is unavailable the limiter falls
  back to process-local memory.
- **`img-src data:`** is allowed by the CSP.
- **CI does not run** (the account's Actions budget), so every gate above is
  run locally, by hand.
