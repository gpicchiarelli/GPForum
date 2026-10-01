# Realtime Architecture

GPForum realtime is an enhancement boundary. PostgreSQL, event logs, outbox
messages, SSR pages, and polling endpoints remain authoritative.

## Flow

```text
Domain event
  -> outbox_messages
  -> outbox dispatcher / domain event transport
  -> PostgreSQL NOTIFY gpforum_domain_events
  -> GPForum::Infrastructure::PgNotifications (one queue per process handle)
  -> GPForum::Service::Realtime::PgListener
  -> GPForum::Service::Realtime::ListenerSupervisor
  -> GPForum::Service::Realtime::Hub
  -> authenticated websocket subscribers of this process
```

Every web process LISTENs and fans out only to its own sockets (ADR 0006,
0055, 0111). There is no shared presence or subscription registry, and no node
affinity: any node accepts any client.

Notification badges take the same road. The notification dispatcher NOTIFYs a
`notification.badge` whenever an unread count changes -- from a web request
(mark read, mark all read, a mention) or from the worker's fanout -- so every
process and node sees it, including the one that made the change. The
outbox mapper does not build badges.

If a NOTIFY is lost, writes still succeed and PostgreSQL stays authoritative:

- thread and moderation hints are read back by the outbox backstop (below);
- badges are rebuilt by snapshot: a `notifications:<user_id>` subscription is
  answered with the current count, and after a gap in the notification queue
  each local subscriber is sent its count again. Counts come from
  `notification_inbox`, filtered and capped as the inbox is (ADR 0102);
- clients refetch canonical state when they (re)connect (see
  [Reconnect Contract](#reconnect-contract)).

### One notification queue per handle

The realtime listener and the L1 cache invalidation bus
(`gpforum_cache_invalidation`) LISTEN on the same database handle of the web
process. `Infrastructure::PgNotifications` owns that handle's notification
buffer: it reads it whole and files each notification under its channel, so
neither consumer takes the other's. A notification on a channel nobody
registered is counted as `dropped`.

A LISTEN lives on one PostgreSQL backend. The queue knows the connection by
its backend PID and by the handle itself, because a PID can come back (a
PostgreSQL restarted in a fresh container hands out the same PIDs again) but
DBIx::Class replaces the handle on every reconnect. When the connection
changes (a reconnect after a PostgreSQL restart, a failover, a killed idle
connection), the queue LISTENs on every channel again and reports a gap:

- the cache bus clears the process's L1 once, because the invalidations sent
  meanwhile are gone;
- the listener re-sends badge snapshots to its local notifications
  subscribers, reading each user's count once.

A LISTEN that fails (a standby refuses it) reports a gap on every take until
one succeeds, and on the take that issues it. The cache bus therefore clears
L1 on every read while it cannot hear invalidations, and serves from L2 and
the database instead; the listener waits until its LISTEN is in effect and
re-sends the badges once. A channel registered when no LISTEN could be
issued -- the database unreachable at a worker's first cache read, or a
transaction open -- reports a gap on the take that finally issues it, so L1
drops what it filled from L2 while nobody was listening.

Each channel's queue holds at most 1000 notifications; an overflow drops the
oldest and reports a gap the same way.

### Outbox backstop

The listener also reads completed outbox rows through a cursor, for NOTIFYs
that never arrived:

- it runs only while the process has websocket connections; with none it
  sends no query and drops its cursor;
- a new cursor starts at the head of the outbox, not at the oldest retained
  row, so a deploy or a recycled worker replays nothing;
- it reads a row only once its `next_attempt_at` is five seconds old by the
  database's clock, so a row committed a moment after a later one is not
  skipped. The dispatcher stamps that column with its own host's clock, so
  the five seconds also cover that clock's offset from the database's: keep
  every host on NTP;
- a reconnect keeps the cursor, so what was missed during a database outage
  is read once; a query that fails leaves the cursor where it was, and the
  next poll asks again.

Event ids from both paths are de-duplicated with a bounded memory (1000 ids
per process). Badges come only by NOTIFY and take no place in it, so the
badges of a large fanout do not push out the hints the backstop is about to
read again.

## Listener Lifecycle

The listener is supervised inside each Mojolicious web process. This is
intentional: websocket connections live in web workers, so a standalone listener
process without those connections could observe notifications but could not
deliver websocket fanout.

Enable the lifecycle hook with:

```sh
GPFORUM_REALTIME_LISTENER_ENABLED=1
```

Optional tuning:

```sh
GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS=1
GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS=5
GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS=30
```

The bootstrap hook starts the supervisor lazily on request dispatch and then
keeps polling through the process IOLoop. Starts are idempotent, reconnects use
a bounded backoff timer, and the supervisor registers IOLoop finish cleanup so
shutdown removes timers before unlistening.

## Websocket Contract

`GET /realtime` upgrades to websocket only for authenticated sessions.
Origin matching, payload size, and subscribe-message shape are decided by
`GPForum::Web::RealtimeAccess`. The controller still owns rate limits, hub
registration, telemetry, and error frames.

Client subscribe message:

```json
{ "type": "subscribe", "channel": "thread:<thread_id>" }
```

Server control messages stay stable:

```json
{ "type": "realtime.connected", "connection_id": "...", "fallback": {} }
{ "type": "subscribed", "channel": "thread:<thread_id>" }
{ "type": "error", "reason": "forbidden" }
```

A `notifications:<user_id>` subscription is answered with `subscribed` and
then a badge snapshot. Every badge, snapshot or change, has one shape:

```json
{
  "type": "notification.badge",
  "aggregate_type": "user",
  "aggregate_id": "<user_id>",
  "payload": { "unread_count": 3 },
  "metadata": { "channel_type": "notifications" }
}
```

The count is in `payload.unread_count` only; earlier releases also copied it
to a top-level `unread_count` on some frames.

## Reconnect Contract

Sockets drop: an idle timeout, a deploy, a node that failed. A client that
receives `realtime.connected` or `subscribed` refetches the canonical
fragments from the `fallback.endpoints` it was given, then applies hints.
Thread and moderation hints carry ids only and are idempotent, so a duplicate
or a late one is harmless. Badges carry an absolute count.

There is no server-side replay log (ADR 0110 removed it): events sent while a
client was disconnected are not resent.

## Channels

Supported channel families are explicit:

| Family | Shape | Authorization |
| --- | --- | --- |
| thread | `thread:<thread_id>` | visible thread/category, visible moderation state, active authenticated actor, owner or ACL for private resources |
| notifications | `notifications:<user_id>` | own user id only |
| moderation | `moderation:<scope>` | moderation permission |
| admin | `admin:<scope>` | admin permission |
| feed | `feed:<user_id|personal>` | own feed only |

There is no presence family. Nothing was ever published to it, and a presence
shared across nodes would need the shared registry this design rules out
(ADR 0067, 0111). `presence:<scope>` is denied as `unknown_channel`.

Unknown and malformed channels are denied by default. Denial reasons are
structured: `malformed_channel`, `unknown_channel`, `authentication_required`,
`wrong_recipient`, `invisible_resource`, and `forbidden`.

## Event Envelope

Realtime fanout uses `GPForum::Service::Realtime::EventEnvelope`.

Required fields:

- `event_id`
- `type`
- `schema_version`
- `occurred_at`
- `payload`

Supported metadata fields include:

- `correlation_id`
- `causation_id`
- `aggregate_type`
- `aggregate_id`
- `actor_id`
- `metadata`

Payloads are JSON-only, bounded in size, and never contain DBIx::Class result
objects. Evolution is additive: new consumers must ignore unknown fields.

## Operational Metrics

`/metrics` includes realtime hub counters:

- active websocket `connections`
- `subscriptions`
- `broadcasts`
- delivered messages
- broadcast failures
- malformed realtime events
- configured connection/subscription quotas

`PgNotifier` and `PgListener` expose snapshots for notify failures, degraded
transport, invalid payloads, malformed payloads, duplicate event suppression,
`listen_notify_received`, outbox polling receives, reconnect count, delivered
events, `gaps` and the `badge_snapshots` re-sent after them. The hub counts
every badge snapshot it sends in `badge_snapshots`.

`realtime_listener.listener.notifications` is the process's notification
queue: `received`, `dropped` (unregistered channel), `overflowed`, `gaps`
(per channel and take), `relistens`, `listen_failures` (per attempt),
`unavailable`, the current `backend_pid`, and per channel whether it is
`listening` and how many are `queued`. The cache bus snapshot
(`local_caches[].bus`) counts its own `gaps`: each is one L1 clear. A
`listen_failures` that keeps rising means the process cannot LISTEN, and
its L1 is being cleared on every read.

`ListenerSupervisor` exposes enabled/running state, scheduled polls, poll
failures, reconnects and heartbeats.

## Security Model

The websocket handshake validates:

- authenticated session;
- same-origin `Origin` when present, via `Web::RealtimeAccess`;
- JSON payload size against the realtime byte limit;
- PostgreSQL-backed rate limit for `realtime.connect` (30 per 60 seconds per
  user), using the `user`-scope hash from `Web::RealtimeAccess`. It holds
  across every process and node, and is the cross-node control;
- a connection quota of 8 per user, counted per process: a memory bound on
  one worker, not a cluster-wide limit. A user may hold that many sockets on
  each worker of each node. Counting across nodes would need a shared
  presence table, which ADR 0067 rules out.

Subscriptions validate:

- structured channel syntax;
- PostgreSQL-backed rate limit for `realtime.subscribe`, using the
  `user`-scope hash from `Web::RealtimeAccess`;
- policy-backed resource access; the account check fails closed, so a
  suspension store that errors denies the subscription;
- per-connection subscription quota.

Suspicious denials are recorded through `SecurityTelemetry` without storing raw
message bodies or private resource contents.

## Degraded Modes

| Failure | Behavior |
| --- | --- |
| NOTIFY unavailable | notifier returns `degraded`, outbox dispatch can continue, polling remains source of truth |
| LISTEN unavailable | listener status becomes `polling`; the outbox backstop is the only path while the process has sockets; every poll tries the LISTEN again |
| database reconnect | the notification queue LISTENs again on the new connection and reports a gap: L1 is cleared once, badge snapshots are re-sent, the backstop cursor is kept |
| LISTEN refused (standby) | each take reports a gap: L1 is cleared on every read until a LISTEN succeeds; badge snapshots are re-sent once it does |
| supervisor start failure | reconnect is scheduled after bounded backoff; SSR and polling continue |
| malformed NOTIFY payload | listener rejects payload and increments invalid counters |
| duplicate NOTIFY payload | listener suppresses recent duplicate event ids with bounded best-effort memory |
| websocket send failure | hub records failed delivery and does not affect canonical writes |
| readability query fails at a broadcast | that event counts as a broadcast failure and is left to the outbox backstop; the rest of the poll, and a gap's badge snapshots, still go out |
| process restart | websocket state is lost; the new process's backstop starts at the head of the outbox; clients reconnect and refetch canonical state |

## Scaling Guidance

Websocket state is process-local and disposable. Each web process runs its own
listener supervisor when enabled, and PostgreSQL LISTEN/NOTIFY gives fanout
between processes and nodes while all durable state remains in PostgreSQL
tables. Adding a node adds no connection and no daemon: the listener reads the
handle each web process already holds. Keep the listener enabled on every web
process: badges reach sockets only through it.

Do not use websocket presence, subscriptions, or recent-event caches as
authoritative product state, and do not add a shared presence registry.
