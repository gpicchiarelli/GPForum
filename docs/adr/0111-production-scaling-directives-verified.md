# ADR 0111: Production Scaling Directives, Verified Against the Code

## Status

Accepted. Records the owner's four production-scaling directives of
2026-09-26 as ADR 0087 asks of a prompt, with each premise checked against
the code. Amends ADR 0006 (realtime fanout), ADR 0048 (L2 failure handling)
and ADR 0062 (search cost bounds); follows ADR 0102 and ADR 0110.

## Context

The owner set four "constitutions" for running GPForum at production scale:

1. Remove the pessimistic `FOR UPDATE` on `threads` used to allocate a
   reply's position; allocate optimistically and retry the unique violation
   with exponential backoff, so that no HTTP client waits on a row lock.
2. Stateless websocket nodes, replicated horizontally: each node `LISTEN`s on
   PostgreSQL and fans out only to its own clients, with no shared presence
   registry; a client of a failed node reconnects elsewhere and stays
   consistent.
3. Isolate search compute: `/search` and `/search/autocomplete` read only a
   replica or a separate search store, because GIN maintenance on the primary
   is said to saturate CPU and slow replies.
4. Prevent cache stampedes on the L2: XFetch, a per-node mutex or an advisory
   lock single-flight, and stale-while-revalidate.

Each premise was checked against the code by one analysis and one
adversarial review, citing file and line; the probes that could be run were
run with the project's Perl and PostgreSQL 18. The goals stand. Three of the
four prescribed mechanisms would have broken invariants other ADRs rely on,
and the checks found defects the directives did not name. This ADR records
what was decided for each.

## Decision

### 1. Reply position stays a commit-ordered per-thread ordinal; the lock narrows

*Premise: partly true.* A reply takes a row lock on its thread, held until
the command commits. But the lock is bounded (`lock_timeout` 3 s), a timed
out command is not recorded and may be sent again with the same command id,
and the forum-wide serialisation point is the audit chain's advisory lock
(ADR 0020's residual risk), not the thread lock.

*Rejected mechanisms.* The readers need positions unique and in commit order:
the post keyset (`PostReader`), the read marker's high-water mark
(`ReadState`), "position 1 is the opening post" (`ThreadComposer`,
`ProfileReader`) and the "#N" shown to readers.

- A global or per-thread sequence hands out numbers in start order, not
  commit order: reply A takes 11, B takes 12 and commits first, a reader marks
  read to 12, and A's post is never shown as unread.
- A lock-free `MAX(position)+1` still waits: the unique index check blocks the
  second inserter on the first's transaction, then fails it with 23505 after
  its work is done.
- A backoff loop would sleep inside the command's one open transaction
  (ADR 0110), holding every lock taken so far, against
  `idle_in_transaction_session_timeout`.

Retry is command-id replay, which exists.

*Decided.*

- The lock is `FOR NO KEY UPDATE`. It still orders replies against each
  other and against moderation, which takes `FOR UPDATE`. It no longer blocks
  the `FOR KEY SHARE` that foreign-key checks take, so a reader's first
  read-marker insert does not wait behind a reply.
- Under the lock, the reply re-reads the thread's `locked_at` and moderation
  state, and refuses a thread locked or hidden since the workflow's first
  check. ADR 0061's "locked threads reject replies" was racy before this.
- A PostgreSQL test races concurrent replies to one thread and asserts
  contiguous, unique positions. It closes the go-live item in `docs/MVP.md`.

### 2. Realtime: each process listens and fans out locally, on one queue per handle

*Premise: already the architecture* (ADR 0006, 0055, 0088). There is no
shared presence registry and none is added. The checks found that the claim
"each node LISTENs and fans out locally" was not true in the shipped
configuration.

- The cache invalidation bus and the realtime listener read notifications
  from the same database handle, and each took the other's. A cache purge the
  listener took was dropped as malformed, so that worker served a hidden post
  from L1 until the TTL. This reopened quality program 8.1 at random.
- A `LISTEN` lost to a reconnect was never re-issued by the listener.
- Every worker recycle or deploy replayed the outbox backstop from its oldest
  retained row: up to seven days of events.
- Badge updates from a web request reached only the sockets of the process
  that served it.

*Decided.*

- There is one notification queue per process handle
  (`Infrastructure::PgNotifications`), which routes by channel. Connection
  identity is the backend PID. After a reconnect it re-`LISTEN`s every
  channel and reports a gap. On a gap, the cache bus clears L1 and the
  listener re-sends badge snapshots.
- The outbox backstop runs only while the process has sockets. It starts at
  the head, and reads rows only once they have settled for 5 seconds.
- Every badge goes through `NOTIFY`, so every process and node sees it. One
  builder makes the frame.
- A client that reconnects refetches canonical state; hints are id-only and
  idempotent. There is no server-side replay log (ADR 0110 removed it).
  Connection quotas are a per-process memory bound; the cross-node control is
  the PostgreSQL-backed connect rate limit.

### 3. Search stays on the primary; its cost is bounded instead

*Premise: partly true, and wrong about the mechanism.* GIN maintenance never
runs in a reply's transaction: the search handler indexes asynchronously
through the outbox. What does grow with the forum:

- ranking a common word scores every match (quality program 8.10);
- a large thread's reindex (a move, a title edit) ran as one outbox message
  ahead of realtime, notifications and cache purges;
- removing a large thread took one advisory lock per post in one
  transaction, which can exhaust the shared lock table;
- the dispatcher slept 5 seconds between batches even with a backlog.

*Rejected.* A separate search database, or logical replication, breaks
ADR 0102 stage 2: a category turning private leaves search at once, by a live
join on the same database. It would also break the indexer's
lock-and-read in one transaction and the live author join. And it doubles
migrations, backup and PITR. A streaming replica moves the CPU without
bounding it, and still replays the primary's GIN work. It stays an opt-in
for later, behind measurement, and must take category and space readability
from the primary.

*Decided.*

- A search runs under its own statement timeout.
- Ranking considers the newest N matches, walked by an index; the page says
  when it did.
- The unused partial indexes are dropped once proved unusable.
- A large thread is reindexed in bounded continuation messages, and removed
  in bounded batches.
- The dispatcher drains a backlog without sleeping.

### 4. The L2 stays fail-open; no stampede machinery; its real defects are fixed

*Premise: false as stated.* An L2 failure falls back to L1 and to the
database, and never closes the site. Since 8.2 the public cache is looked up
before a page's queries. So an L2 outage multiplies recomputes by at most the
number of web processes times nodes, per key and TTL: the fail-open cost ADR
0048 accepts, not a runaway.

*Rejected.*

- A per-process lock is never contended by synchronous handlers.
- A per-node or advisory-lock single-flight swaps recomputes for blocked
  workers and a database round trip per miss.
- Stale-while-revalidate past the TTL breaks the TTL bound ADR 0067 names as
  the recovery for a lost invalidation, and ADR 0102's moderation purge.

*Decided.* The checks found these instead, and each is fixed:

- **Tag invalidation used a read-modify-write member list.** Two concurrent
  fills lost members, so a moderation purge could miss a page that still
  showed a hidden post. Tags are now tokens: invalidating a tag erases one
  key, and an entry whose token changed is a miss.
- **Erasing an absent key counted as a failure** and dropped a healthy
  connection, on almost every post event. GlifiStore outcomes are now
  classified.
- **A failing L2 is skipped for a fixed cool-down**, so a hung store does not
  stall every request.
- **L1 refilled from L2 with a fresh TTL**, which doubled the staleness bound.
  It now inherits the entry's remaining lifetime.
- **The anonymous category list** could not be encoded for L2, and is stored
  as plain columns.
- **A page miss looks its key up once.**

## Consequences

- The goals of all four directives hold. What was rejected was the mechanism
  where it contradicted another accepted ADR, and each rejection is argued
  above from the code.
- **Follow-ups outside this ADR's changes.**
  - The audit chain's forum-wide advisory lock is the real write
    serialisation point. Moving audit linking out of request transactions
    needs its own ADR amending 0020.
  - `thread_counter_shards` is written on a constant shard and read by
    nothing.
  - Edits of a thread's title and of a post do not re-check `locked_at` under
    a lock.
- **Verification.** Each decision is pinned by a test, on PostgreSQL where
  the behaviour is PostgreSQL's (the reply race, the lock mode, the
  notification routing, the search plans). `docs/QUALITY_PROGRAM.md` records
  the outcome.

## Alignment

ADR 0005 (stores own the transaction), 0006 and 0055 (realtime fanout),
0020 (audit chain), 0048 (L2), 0061 (invariants), 0062 (search), 0063
(scaling), 0067 (PostgreSQL is not a broker), 0087 (prompts become ADRs),
0088 (connection discipline), 0102 (effective visibility), 0110 (one
transaction per command).
