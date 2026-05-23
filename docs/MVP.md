# GPForum MVP HTTP Surface

This document describes what is currently wired as a traversable forum surface.
It is intentionally narrower than the full architectural contract.

## Available Routes

* `GET /categories` returns visible categories.
* `GET /c/:category_id` returns one category and a keyset-paginated thread list.
* `GET /t/:thread_id` returns one visible thread and keyset-paginated posts.
* `GET /new-thread` returns the thread form shape and a CSRF token.
* `POST /threads` creates a thread for an authenticated session user.
* `POST /t/:thread_id/replies` creates a reply for an authenticated session user.
* `GET /search?q=...` queries the PostgreSQL-native search boundary.

The current forum endpoints return JSON. SSR templates can be layered over the
same controller/service path without changing the command/read boundaries.

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

`/health/ready` now performs a real lightweight DB readiness check and verifies
that event, outbox, and projection resultsets are reachable.

## Local Limits

Realtime websocket fanout remains process-local. Multi-process fanout still
needs PostgreSQL `LISTEN/NOTIFY` or outbox polling.

The rate limiter remains process-local. It is acceptable as a fallback and test
boundary, but a PostgreSQL-backed limiter is the next production-grade step.

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

Start workers after Minion configuration is present:

```sh
carton exec perl -Ilib bin/gpforum minion worker
```
