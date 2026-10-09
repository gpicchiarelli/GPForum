# ADR 0114: The Audit Chain Is Linked After Commit, Without a Forum-Wide Lock

## Status

Proposed. The implementation follows in its own batch, in the steps below.
Amends ADR 0020 (the chain is no longer built in `EventRecorder`) and the
audit bullet of ADR 0116 (a caller's audit id is locked on its own, not
under the chain lock). Closes the follow-up ADR 0111 left open; keeps
ADR 0110 (one transaction per command) and ADR 0067 (PostgreSQL is not a
broker).

## Context

`EventRecorder::record_audit` takes `pg_advisory_xact_lock(2026060210)`,
reads the newest `audit_log` row (`ORDER BY created_at DESC, audit_id DESC
LIMIT 1`), and stores that row's `record_hash` as the new row's
`previous_hash`. The lock is a transaction lock taken in the command's
transaction, so it is held from the audit insert to the commit, fsync
included. ADR 0111 and `docs/THREAT_MODEL.md` name it the forum's real write
serialisation point. Checked against the code and PostgreSQL 18 on
2026-10-03, the chain it protects is in a worse state than they describe.

- **The chain forks with a single writer.** `created_at` has one-second
  resolution (`AuditRecord::now_iso8601`), and `Infrastructure::Id::uuid`
  builds the UUIDv7 timestamp from core `time`, which is whole seconds, so
  every id minted in one second carries the same 48-bit prefix and a random
  tail. The "newest row" is a random row of the current second. Twelve
  sequential `record_audit` calls, each in its own transaction: rows 3 to 9
  all point at row 3, rows 10 to 12 at row 9; three parents have more than
  one child and 9 of the 12 rows have no successor. A deleted leaf leaves no
  trace. `QUALITY_PROGRAM.md` 1.3 ("the chain cannot fork") and
  `docs/audit/failure-modes.md` FM-010 are wrong.
- **A caller's `created_at` in the past forks it too:** the row sorts below
  the tip and the next row links past it. Several stores pass their
  command's time, and the report and role-binding replays pass an old row's.
- **A stored row never verifies.** `record_hash` covers the caller's input:
  `created_at` as `2026-10-03T10:22:14Z`, `metadata` as a Perl hash,
  `schema_version` as a number. Read back, PostgreSQL returns
  `2026-10-03 12:22:14+02` in the session time zone, `metadata` as jsonb
  text, `schema_version` as a string. `verify_audit_record` is 1 on the hash
  kept in memory and 0 on the persisted row.
- **Nothing verifies the chain.** No command, console page or job walks
  `previous_hash`; `verify_audit_record` is called only by tests.
- **A caller can supply the link.** `AuditRecord::_previous_hash` keeps a
  non-blank `previous_hash` from the input. Every caller in `lib/` passes
  `undef`, but the interface allows it.
- **Anyone can drive the lock.** `Identity::SecurityAudit` audits every login
  request and `RateLimiter` every block, so unauthenticated traffic takes the
  forum-wide lock.
- **The lock is head-of-line blocking.** Measured on PostgreSQL 18 with the
  real recorder: a transaction that audits and then stays open 1.5 s made a
  second audited write wait 1,257 ms; without the lock and the tip read it
  took 18 ms. With 3 ms of work after the audit, 1 writer did 126
  transactions/s and 8 writers 123/s (fully serialised); without the lock,
  154/s and 1,117/s. Any audited transaction that stalls after its audit
  (a row-lock wait, a slow statement) stalls every audited write behind it
  until `lock_timeout`.
- **ADR 0116 leans on the lock.** A caller-supplied `audit_id` is looked up
  in every partition "under the chain lock every audit write already holds",
  so that two writers of one id cannot both miss each other. Removing the
  lock reopens that race unless the id gets a lock of its own.

Two designs were drafted and compared: linking asynchronously after commit
(this ADR), and 64 synchronous chains claimed with `FOR UPDATE SKIP LOCKED`
(rejected below). They were scored, 1 to 5, against six criteria:

| Criterion | After commit | 64 synchronous chains |
| --- | --- | --- |
| Tamper evidence and completeness | 4 | 3 |
| Request-path serialisation removed | 5 | 4 |
| ADR 0110 and ADR 0067 | 5 | 3 |
| Operational simplicity | 3 | 2 |
| Migration risk for existing rows | 4 | 2 |
| Testability on PostgreSQL | 5 | 4 |
| **Total** | **26** | **18** |

## Decision

### 1. A request writes its audit row unlinked

`record_audit` inserts the row and does nothing else: no chain lock, no tip
read. `previous_hash` stays NULL on every new row, and `AuditRecord::build`
no longer reads it from the input or takes a chained hash. `record_hash` is
still written, as the input digest it always was; it is declared
non-authoritative. The chain's own hash (section 4) is the authoritative one.

A `BEFORE INSERT` row trigger on `audit_log`, `audit_log_stamp()`, sets two
columns and overrides anything the caller sent:

- `writer_xid := pg_current_xact_id()`, the writing transaction's top-level
  id (inside a savepoint too, which `UniqueConflict->attempt` uses);
- `ingest_id := nextval('audit_log_ingest_seq')`, the insertion order within
  that transaction.

Both checked on PostgreSQL 18: a forged `writer_xid` is overwritten, and a
row inserted in a savepoint carries the top-level id.

### 2. A caller's audit id is locked on its own (amends ADR 0116)

When the caller passes `audit_id`, `record_audit` takes
`pg_advisory_xact_lock(2026100311, hashtext(audit_id))` before the lookup in
every partition, in the caller's transaction or one it opens, exactly as
`record_event` does for an event id (class 2026100310). An id minted by the
recorder is neither locked nor looked up. No caller in `lib/` passes one
today, so ordinary audits take no advisory lock at all. The lock-ordering
note in ADR 0116 (the event id's lock before the chain's) no longer applies.

### 3. A linker appends each row to `audit_chain` once it is final

A row is final when no transaction that could still add a row before it is
running. The linker reads, in one statement,

```sql
WHERE writer_xid IS NOT NULL
  AND (writer_xid, ingest_id) > ($cursor_xid, $cursor_ingest_id)
  AND writer_xid < pg_snapshot_xmin(pg_current_snapshot())
ORDER BY writer_xid, ingest_id
LIMIT 500
```

Every transaction id below the snapshot's xmin has finished, and the
statement's snapshot shows their committed rows; a transaction that writes
later gets an id above it. Checked on PostgreSQL 18: with A open after its
insert and B committed after A's insert, neither is returned; once A
commits, both are, A first.

Each batch is one transaction of its own:

1. `SET LOCAL lock_timeout = '2s', statement_timeout = '30s'`.
2. `pg_try_advisory_xact_lock(2026100314)`, or return `busy`; then the state
   row `FOR UPDATE`. Only the linker takes either, never a request.
3. Refuse when the stored cursor is at or above the current snapshot's xmax
   (a logical restore; section 8).
4. Select the batch (above), digest each row's stored form, compute the
   links, insert them into `audit_chain` in one statement, advance the state
   row, commit.
5. After a commit that linked rows, log `audit_chain.tip` with `epoch`, `seq`
   and `link_hash` as one structured info line: the external anchor, once
   logs leave the host.

The linker never writes an audit row, so it cannot feed itself.

**Hosting.**

- `Command::OutboxDispatch::_run` calls the linker once per iteration; a full
  linker batch counts as "not drained", like a full dispatch batch.
- A scheduled job `audit_chain` links any backlog and runs an incremental
  verification, hourly with the other jobs.
- `bin/gpforum-audit-chain link --loop` is there for an install that wants
  its own process.

### 4. Data model and hashes

Migration `050_audit_chain.sql` (the next free number; it moves if another
migration lands first):

- `ALTER TABLE audit_log ADD COLUMN writer_xid xid8, ADD COLUMN ingest_id
  bigint`, both nullable with no default: a catalog change, no rewrite.
- `CREATE SEQUENCE audit_log_ingest_seq CACHE 32`. The cache is safe: order
  matters only within one transaction, which runs on one backend.
- The trigger function and the `BEFORE INSERT ... FOR EACH ROW` trigger on
  the partitioned parent. PostgreSQL clones it onto every partition and onto
  each month partition maintenance attaches later.
- `CREATE INDEX idx_audit_log_link_order ON audit_log (writer_xid,
  ingest_id) WHERE writer_xid IS NOT NULL`. Partial, so existing rows add
  nothing, but the build takes a SHARE lock on `audit_log` while it scans:
  the same maintenance-window note as migration 039.
- `audit_chain`, not partitioned, insert-only:
  `chain_seq bigint PRIMARY KEY CHECK (chain_seq > 0)`, `epoch smallint NOT
  NULL`, `audit_id uuid NOT NULL`, `audit_created_at timestamptz NOT NULL`,
  `content_hash text NOT NULL`, `previous_link_hash text NOT NULL`,
  `link_hash text NOT NULL`, `digest_version smallint NOT NULL DEFAULT 1`,
  `linked_at timestamptz NOT NULL DEFAULT now()`, and `UNIQUE (audit_id,
  audit_created_at)`. No foreign key to `audit_log`: it would block
  detaching a month. Completeness is the verifier's job.
- `audit_chain_state`, one row: `last_seq`, `last_link_hash` (64 zeros at
  genesis), `epoch`, the legacy cursor (`legacy_done`,
  `legacy_cursor_created_at`, `legacy_cursor_audit_id`), the xid cursor
  (`cursor_xid xid8`, `cursor_ingest_id`), the verification checkpoint
  (`verified_through_seq`, `verified_link_hash`, `verified_at`,
  `verify_ok`), `updated_at`.
- `idx_audit_log_chain_tip` (migration 039) stays: the audit console pages
  newest first on it. Its comment, which says it serves the tip read, is
  corrected in 050.

**Stored-form digest, version 1.** One projection, defined once in
`Infrastructure::AuditChain` and used by both linker and verifier, reads every
column as text in SQL: `audit_id::text`, `action`, `schema_version::text`,
`actor_id::text`, `target_type`, `target_id::text`, `correlation_id::text`,
`previous_hash`, `record_hash`, `metadata::text`,
`to_char(created_at AT TIME ZONE 'UTC',
'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`, `writer_xid::text`, `ingest_id::text`.
`content_hash` is the SHA-256 of that object's canonical JSON. Every value is
text or JSON null, so NULL and `''` stay distinct, and the session time zone
does not matter (the draft measured identical digests under Europe/Rome and
America/Los_Angeles, with non-ASCII metadata).

**Link.** `link_hash` of row *n* is the SHA-256 of the canonical JSON of
`{v, epoch, seq, previous, audit_id, audit_created_at, content_hash}`, all as
text, where `previous` is row *n-1*'s `link_hash` (64 zeros for the first).

### 5. Order

- Chain order is `chain_seq`. For new rows it is `(writer_xid, ingest_id)`:
  the order in which transactions began writing, then insertion order within
  each. It is reproducible from stored columns, and verified.
- It is not commit order and not `created_at` order; the console's timeline
  stays by `created_at`. Nothing in a request reads chain order.
- No clock is involved, so neither the one-second resolution nor a caller's
  past `created_at` can fork it. Callers keep passing `created_at` as they do
  today; ADR 0116's reasons for it stand.

### 6. Existing rows are adopted as found

Rows written before migration 050 have no `writer_xid`. They are a closed set:
`ADD COLUMN` took `ACCESS EXCLUSIVE`, so every earlier writer had finished,
and every later insert is stamped by the trigger, old code included.

The linker links them first, once, as epoch 1, seq 1 to L, in `(created_at,
audit_id)` order. Their stored form is digested as it is, old `previous_hash`
and `record_hash` included, so from adoption on each one is protected like a
new row. What happened to them before adoption cannot be vouched for; nothing
could vouch for it today either. Their old links are kept, and not used for
order. No audit row is rewritten.

### 7. What the verifier checks

`Service::Operations::AuditChainVerifier`, run by `bin/gpforum-audit-chain
verify [--full | --from-seq N] [--anchor EPOCH:SEQ:HASH] [--json]`, by the
scheduled job (incremental) and shown in the console. It walks `audit_chain`
by `chain_seq` in keyset batches and checks:

1. `chain_seq` is dense from 1, or from the anchor;
2. each `previous_link_hash` is the prior row's `link_hash`, and each
   `link_hash` recomputes;
3. the referenced `audit_log` row exists and its stored-form digest is
   `content_hash`, or it lies in a month `partition_registry` marks
   `detached`, `archived` or `dropped` (reported as retired, not missing);
4. within an epoch, `(writer_xid, ingest_id)` strictly increases;
5. the state row's `last_seq` and `last_link_hash` match the last chain row;
6. completeness: per partition, no row at or below the cursor (and, once
   `legacy_done`, no unstamped row) is missing from `audit_chain`, and no
   unlinked row carries a `writer_xid` above the snapshot's xmax;
7. the anchor, when given, lies on the chain.

The incremental run starts from its stored checkpoint; `--full` re-reads
from genesis and is run weekly or on demand. `status` reports lag without
verifying.

| Tampering after linking | Detected by |
| --- | --- |
| A field of an audit row changed | `content_hash` (check 3) |
| An audit row deleted | missing row in a live month (check 3) |
| A row inserted with the trigger disabled | unlinked row below the cursor, or a future xid (check 6) |
| A chain row deleted, edited or reordered | density and links (checks 1, 2) |
| The chain's tail cut and the state row rewritten | only an exported anchor beyond the cut (check 7) |
| The whole chain rewritten consistently | only an exported anchor |

### 8. Failure modes

- **Linker dies mid-batch:** the transaction rolls back; the next run
  produces the same rows bit for bit. `UNIQUE (audit_id, audit_created_at)`
  stops a double link.
- **Two linkers:** the second gets `busy`.
- **Linker stopped, or the dispatcher slow:** requests are unaffected; the
  backlog grows and stays unprotected until it is linked. Readiness turns
  amber when the oldest unlinked row is 5 minutes old, red at an hour or
  when the last verification failed, and names the transaction holding the
  watermark back (`pg_stat_activity.backend_xid`, pid and age).
- **A long write transaction anywhere in the cluster, or a prepared
  transaction:** the xmin is cluster-wide, so linking waits for it. Nothing
  is lost. Read-only transactions, `pg_dump` included, hold no xid and do not
  stall it.
- **An aborted transaction:** its rows never become visible; the cursor
  passes its xid.
- **Partition DDL holding `ACCESS EXCLUSIVE` on `audit_log`:** the linker hits
  `lock_timeout` and tries again next iteration.
- **Restore from `pg_dump`** (transaction ids are not carried over): the
  linker refuses (section 3, step 3). `gpforum-audit-chain rebase`, run with
  the application stopped, links the restored unlinked rows in their stored
  order, opens a new epoch with its cursor at the current xmax, and logs the
  new anchor. Physical replicas, PITR and `pg_upgrade` keep transaction ids,
  and `audit_chain` rolls back with `audit_log` because they share the WAL.
- **Failover to an asynchronous standby, or PITR to an earlier point:** both
  tables roll back together and still verify, but an anchor exported after
  the recovery point names a seq that is gone. The verifier reports "anchor
  beyond the tip", distinct from a broken link; the runbook has the operator
  record the new tip as an anchor, with the reason, in the audit log.
- **A PostgreSQL major upgrade that changes jsonb or `to_char` output:**
  verification fails loudly. The runbook re-verifies after every upgrade;
  `digest_version` allows a second digest from a recorded anchor on.

## Implementation

Four steps, each releasable on its own, in this order.

**Step 1: schema.** Migration `050_audit_chain.sql` as in section 4;
`Schema::Result::AuditLog` gains `writer_xid` and `ingest_id`;
`Schema::Result::AuditChain` and `Schema::Result::AuditChainState` are new.
`EventRecorder` is unchanged and still locks.

**Step 2: linker, verifier, command, hosting.** New
`Infrastructure::AuditChain` (projection SQL, digest, link hash, constants),
`Service::Operations::AuditChainLinker`,
`Service::Operations::AuditChainVerifier`,
`Command::AuditChain` and `bin/gpforum-audit-chain` (`link [--once|--loop]`,
`verify`, `status`, `rebase`, each with `--json`). `Command::OutboxDispatch`
calls the linker; `Service::Operations::ScheduledJobs` adds `audit_chain` to
`@JOB_NAMES` and `%JOB_METHOD`. The legacy rows are adopted on the first run.

**Step 3: the request path.** `EventRecorder` loses `$AUDIT_CHAIN_LOCK_KEY`,
`_lock_audit_chain`, `_latest_audit_hash`, `_latest_persisted_audit_hash`,
`_latest_created_audit_hash`, `_newest_created_hash` and `_row_hash`;
`record_audit` opens a transaction only for a caller-supplied `audit_id`, and
locks that id (section 2). `AuditRecord::build` drops the chained-hash
argument and the input `previous_hash`. Rolling back this step alone puts the
lock back, which is harmless while the linker runs.

**Step 4: console, readiness, documents.** `Service::Admin::AuditReview`
reads the chain status of the page's rows in one extra query
(`audit_chain WHERE (audit_id, audit_created_at) IN (...)`), so the page plan
is unchanged; `templates/admin/audit.html.ep` shows `#seq` or "pending link";
`templates/admin/dashboard.html.ep` shows linked through, pending count,
oldest pending age, last verification and its result (`Bootstrap::Admin`,
`Controller::Admin`). `Service::Operations::Readiness` gains the
`audit_chain` check of section 8. The status here becomes Accepted.

**Files.**

- New: `migrations/050_audit_chain.sql`;
  `lib/GPForum/Infrastructure/AuditChain.pm`;
  `lib/GPForum/Service/Operations/AuditChainLinker.pm`;
  `lib/GPForum/Service/Operations/AuditChainVerifier.pm`;
  `lib/GPForum/Schema/Result/AuditChain.pm`;
  `lib/GPForum/Schema/Result/AuditChainState.pm`;
  `lib/GPForum/Command/AuditChain.pm`; `bin/gpforum-audit-chain`;
  `docs/ops/audit-chain.md` (lag, blocked watermark, rebase, anchors,
  re-verify after an upgrade).
- Changed: `lib/GPForum/Infrastructure/EventRecorder.pm`,
  `lib/GPForum/Infrastructure/AuditRecord.pm`,
  `lib/GPForum/Schema/Result/AuditLog.pm`,
  `lib/GPForum/Command/OutboxDispatch.pm`,
  `lib/GPForum/Service/Operations/ScheduledJobs.pm`,
  `lib/GPForum/Command/ScheduledJobs.pm` (usage, if it lists jobs),
  `lib/GPForum/Service/Operations/Readiness.pm`,
  `lib/GPForum/Service/Admin/AuditReview.pm`, `lib/GPForum/Bootstrap/Admin.pm`,
  `lib/GPForum/Controller/Admin.pm`, `templates/admin/audit.html.ep`,
  `templates/admin/dashboard.html.ep`. The `previous_hash => undef`
  placeholders in the Privacy, Identity, Admin and Outbox `Event.pm`
  modules, `Admin::Maintenance`, `Admin::Diagnostics`, `RateLimiter`,
  `ExportBundleBuilder` and `MentionStore` go.
- Documents: ADR 0020 (status: amended by 0114), ADR 0111 (follow-up
  closed), ADR 0116 (audit bullet), `docs/THREAT_MODEL.md` (the residual risk
  becomes the unlinked window and the need for exported anchors),
  `docs/audit/transactional-correctness.md` AUD-001,
  `docs/audit/failure-modes.md` FM-010, `docs/QUALITY_PROGRAM.md` 1.3,
  `docs/SECURITY_BASELINE.md` (anchors), `docs/ENGINEERING_CORRECTNESS.md`,
  `docs/release/readiness-review.md`, `docs/ops/console-and-cli.md`,
  `docs/ops/scheduled-jobs.md`, `docs/OBSERVABILITY.md`, `CHANGELOG.md`.

**Tests.**

- `t/317-audit-chain-digest.t` (new): golden vectors for the digest and the
  link; NULL against `''`; jsonb key order irrelevant; non-ASCII metadata;
  `digest_version` and `epoch` inside the hash.
- `t/318-audit-chain-verifier.t` (new): each check of section 7 against a
  double, retired months from a registry double included.
- `t/integration/postgres-audit-chain.t` (new):
  - head of line: T1 audits and stays open 2 s, T2's audited write commits in
    under 100 ms;
  - four forked writers: no advisory lock waits in `pg_locks`, then one
    linear chain with every row linked;
  - late committer: A writes and stays open, B commits, nothing is linked;
    A commits, A then B;
  - an aborted transaction is skipped;
  - the linker killed mid-batch with `pg_terminate_backend`, then run again:
    identical hashes;
  - two linkers at once: one `busy`, no duplicate;
  - each tampering case of section 7 detected, a forged row inserted with
    the trigger disabled included;
  - a month attached by partition maintenance carries the trigger;
  - a detached month counts as retired;
  - legacy adoption: forked legacy rows become epoch 1, seq 1 to L, new rows
    follow;
  - linker and verifier in different session time zones agree;
  - the restore guard refuses, `rebase` opens epoch 2, verification passes;
  - a caller-supplied `audit_id` raced by two workers at different times is
    written once (the race beside the sequential
    `_audit_id_at_another_time` of
    `t/integration/postgres-partition-conflicts.t`).
- Changed: `t/75-architecture-foundation.t` (the chain subtests assert
  `previous_hash` is undef); `t/116-infrastructure-audit-record.t` (no
  chained or explicit `previous_hash`); `t/159-concurrency-correctness.t`
  (no advisory lock for a minted id, the caller's transaction reused; the
  per-id lock for a supplied one); `t/lib/GPForum/Test/AuditChainSchema.pm`
  and `AuditChainStorage.pm` reduced to what that needs;
  `t/integration/postgres-concurrency.t` (`_audit_chain_race` becomes
  "concurrent audits do not wait"; the chain-tip index and EXPLAIN checks
  stay as console-plan checks); `t/316-log-ids-across-partitions.t`;
  `t/05-database.t` (columns, tables, trigger); `t/252-command-json.t`
  (`audit-chain`); `t/151-scheduled-jobs.t` (the job);
  `t/214-console-cli-parity.t`;
  `t/176-test-double-fidelity.t` if it lists `AuditLog` columns; the
  readiness tests; `t/216-pod-coverage.t` covers the new public subs.
- After step 3, `t/159` and the PostgreSQL concurrency suites run in full:
  the lock was taken after each store's checks, so it should not have
  protected a check-then-act, but that is an argument to confirm, not a
  proof.

## Consequences

- No audited write waits for another. The request path gains one trigger
  call, one `nextval` and one index entry per audit row, and loses the lock,
  the tip read across every partition and the head-of-line blocking.
  Unauthenticated audit volume now grows the linker's backlog instead of
  every writer's latency; the draft's linker prototype linked about 24,000
  rows a second on one connection.
- A committed row is unprotected until it is linked: normally the
  dispatcher's sleep (at most 5 s) plus the longest write transaction in the
  cluster, unbounded while the linker is down or the watermark is held.
  Readiness makes that window visible. Today every row is unprotected
  forever, since nothing verifies and most rows are leaves.
- "Audited" no longer means "chained at commit". Anything that needs a row
  chained reads `audit_chain`.
- Tamper evidence against someone who can rewrite both tables consistently
  rests on anchors kept outside PostgreSQL: the `audit_chain.tip` log lines,
  if logs are shipped, or an operator's `--anchor`. This is stated, not
  solved, as it is today.
- `audit_chain` grows without bound, about 200 bytes a row plus its keys.
  Pruning it needs anchored segments and is left to the retention decision
  ADR 0113 keeps open. Dropping an audit month does not break the chain:
  its rows read as retired.
- The digest depends on PostgreSQL's text output for jsonb, uuid and
  `to_char`, stable for many releases but not a contract; hence the
  re-verification after a major upgrade.
- The launchd profile has no outbox dispatcher plist, although
  `docs/DEPLOYMENT.md` calls the dispatcher required; there the linker runs
  only from the hourly scheduled jobs until one is added.
- Two hashes coexist: `record_hash` (input digest, compatibility) and
  `content_hash` (authoritative) until `record_hash` is retired by a later
  change.

## Alternatives Rejected

- **64 synchronous chains claimed with `FOR UPDATE SKIP LOCKED`, with
  periodic checkpoints.** It keeps a row linked at commit, which is its real
  advantage, and it removes most of the contention. It was rejected because:
  - the link stays in the request transaction: a claim, a tip update and a
    clock read per audit, and a row lock held to commit; past 64 concurrent
    writers the fallback blocks, and can deadlock;
  - 64 tip rows updated on every audit are the hot-row, vacuum-churning
    pattern ADR 0067 keeps out of PostgreSQL, and need fillfactor and
    autovacuum tuning, and N sized against the connection count;
  - to keep each chain cut cleanly at a month, it takes `created_at` from the
    database clock and moves the caller's time to metadata: about ten call
    sites, and the dead-letter and report replays ADR 0116 relies on change
    meaning;
  - retention must refuse a month without a verified seal, which reaches into
    partition maintenance; cutover needs a stop-and-restart, and a failover
    needs an operator "epoch" step against false tamper alarms;
  - the tail after the last checkpoint is guarded only by a tip row an
    attacker can rewrite, which is the same exposure as the unlinked window
    here, with more moving parts; legacy rows are sealed only as a set.
  Two of its ideas are kept: no caller input in chain fields, and the
  head-of-line regression test. Its failover concern is answered by the
  "anchor beyond the tip" report.
- **A pending-link queue table written in the request transaction.** Survives
  a logical restore, but adds an insert and a delete per audit row on a hot
  table (ADR 0067), and the order cannot be checked from stored data.
- **One outbox message per audit row.** The same cost through more machinery.
- **Per-actor or per-month chains.** Still a lock in the request; the null
  actor of rate limiting and the system jobs would share one.
- **Keep the lock and shorten its hold** (audit last in each command). It
  narrows the window but keeps a forum-wide serialisation point that
  anonymous traffic can reach, and does not fix the fork.
- **The linker writes chain columns onto `audit_log`.** Every link would
  update every index (no HOT update), a partitioned table cannot hold a
  global unique `chain_seq`, and archived months would have to be written.

## Alignment

- ADR 0020 (amended), ADR 0067 (no broker load), ADR 0110 (the request
  transaction is unchanged; the linker's batches are not commands), ADR 0111
  (follow-up closed), ADR 0113 (partitions, retention open), ADR 0116
  (amended: a caller's audit id is locked on its own).
- `lib/GPForum/Infrastructure/EventRecorder.pm`,
  `lib/GPForum/Infrastructure/AuditRecord.pm`, migration 039, the files and
  tests listed under Implementation.
- `docs/THREAT_MODEL.md`, `docs/audit/transactional-correctness.md`,
  `docs/audit/failure-modes.md`, `docs/QUALITY_PROGRAM.md`.
