# GPForum MVP HTTP Surface

This document describes what is currently wired as a traversable forum surface.
It is intentionally narrower than the full architectural contract.

## Available Routes

* `GET /categories` renders visible categories.
* `GET /c/:category_id` renders one category and a keyset-paginated thread list.
* `GET /t/:thread_id` renders one visible thread and keyset-paginated posts.
* `GET /new-thread` renders the thread form with a CSRF token.
* `POST /threads` creates a thread for an authenticated session user.
* `POST /t/:thread_id/replies` creates a reply for an authenticated session user.
* `POST /t/:thread_id/read` records per-user thread reading progress.
* `GET /search?q=...` renders PostgreSQL-native search results.

Read endpoints render semantic SSR by default. They also return JSON when the
client sends `Accept: application/json` or `?format=json`, using the same
controller/service path without changing the command/read boundaries.

Forum form submissions are SSR-friendly: successful thread creation redirects
to the new thread, and successful reply creation redirects to the created post
anchor. API-style clients still receive JSON by sending `Accept:
application/json`.

Authenticated thread pages include read-continuity metadata: last read position,
first unread post anchor, unread count for the current page, and a CSRF-protected
form to mark visible posts as read. The read marker model is compressed to one
row per `(user_id, thread_id)` plus a coalescable delta table for future
asynchronous consolidation.

## What Works

The HTTP forum path now follows:

```text
route -> Forum controller -> reader/composer/store service -> DBIx::Class
```

Thread creation and reply creation still delegate persistence to `ThreadStore`
and `PostStore`, so event log, audit log, outbox messages, post bodies,
revisions, and counter deltas remain in the existing transaction boundary.

Thread and post lists use keyset pagination through `PageWindow`; no forum route
uses `OFFSET`.

The SSR forum templates use semantic landmarks, labelled forms, stable post
anchors, accessible pagination navigation, and no JavaScript requirement for
core forum reading.

`/health/ready` now performs a real lightweight DB readiness check and verifies
that event, outbox, and projection resultsets are reachable.

## Local Limits

Realtime websocket fanout remains process-local. Multi-process fanout still
needs PostgreSQL `LISTEN/NOTIFY` or outbox polling.

The rate limiter remains process-local. It is acceptable as a fallback and test
boundary, but a PostgreSQL-backed limiter is the next production-grade step.

The local cache remains process-local and disposable. It is TTL bounded,
max-entry bounded, namespace-aware, tag-invalidatable, and visible through
`/metrics`. It is currently used only for read-mostly category lists. Cache
invalidation workers derive tags from authoritative domain events; cached data
is never authoritative and is safe to discard.

Reply position allocation currently uses the latest visible database position
and increments it. The unique `(thread_id, position)` constraint protects data
integrity, but a hot production thread should move to advisory locking or a
dedicated sequence allocator.

Search depends on the `search_documents` projection. If the projection is empty
or unavailable, the HTTP route returns an explicit degraded empty result rather
than using OpenSearch or an external service.

## Commands

Run the full test suite:

```sh
script/test
```

Run Perl::Critic:

```sh
script/perlcritic
```

Run coverage:

```sh
script/coverage
```

Profile a route:

```sh
script/profile-route /categories
nytprofhtml -f var/profile/route-nytprof.out.*
```

Profile an existing Perl command:

```sh
script/profile -Ilib t/32-forum-web.t
```

Apply migrations:

```sh
carton exec perl -Ilib bin/gpforum-migrate --plan
carton exec perl -Ilib bin/gpforum-migrate --apply
```

Start the app:

```sh
carton exec morbo bin/gpforum
```

OS-level tuning flags default to conservative `auto` and are observable through
`/health` and `/metrics`:

```sh
GPFORUM_OS_REUSEPORT=auto
GPFORUM_OS_SENDFILE=auto
GPFORUM_OS_WORKER_PRIORITY=auto
GPFORUM_OS_STATIC_XSENDFILE=auto
GPFORUM_OS_AFFINITY=off
```

Local generated files and disposable cache artifacts should use
`GPForum::OS::Filesystem->write_atomic`, which writes a temporary file in the
same filesystem and promotes it with `rename`.

Socket and process behavior is centralized in `GPForum::OS::Socket` and
`GPForum::OS::Process`. `/health`, `/metrics`, and `script/system-preflight`
surface reuseport/sendfile posture, process-class scheduling recommendations,
event backend, and recommended worker count without making OS-specific tuning
mandatory. `GPForum::Service::Operations::OSPreflight` converts that posture
into ok/degraded/fail checks for readiness and operational metrics. The
thresholds `GPFORUM_OS_MIN_RECOMMENDED_WORKERS` and
`GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS` let deployments make host-capacity
expectations explicit without hard-coding OS assumptions.

Endpoint query budgets are represented by
`GPForum::Service::Operations::QueryBudget` and surfaced through `/metrics`.
They currently cover home, category lists, category thread pages, thread view,
thread/reply creation, and search. They are release-gate contracts for future
instrumented observations rather than runtime query counters. The same service
can synchronize the catalog into `endpoint_query_budgets` and report drift if
the database contract diverges from the executable catalog. The CLI entry point
is `carton exec bin/gpforum-query-budget --print|--sync|--check`. Metrics
expose both the catalog and, when a schema is configured, the drift report used
by readiness. `carton exec bin/gpforum-platform-check` aggregates OS preflight
and optional DB-backed query budget drift into a single CI/deploy check.

Start workers after Minion configuration is present:

```sh
carton exec perl -Ilib bin/gpforum minion worker
```
