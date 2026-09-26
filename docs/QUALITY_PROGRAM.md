# GPForum Quality Program

The objective is 10/10 on every engineering index, with absolute priority on
Perl software-engineering craft, system-administrator ergonomics, and the
aesthetics proper to each technology involved.

This document is the audit verdict and the work plan derived from it. It is
adversarial by design: every claim below is anchored to a file and a line that
was read, and the severe ones were reproduced against a live PostgreSQL 18
instance rather than argued.

## Method

Fourteen dimensions were audited independently, each by a reviewer briefed to
judge against the best of the Perl and PostgreSQL world rather than against
average practice. Every finding was then handed to a separate adversarial
verifier instructed to refute it by reading the source, defaulting to *refuted*
when it could not confirm the claim first-hand. Nine findings were refuted and
are not recorded here. What remains survived that pass.

Measurements were taken with the project's own toolchain
(`script/gpforum-carton exec …`, MacPorts perl 5.42.2) against a real
PostgreSQL 18 database with migrations applied and the benchmark dataset
seeded, and the running application was driven through a browser.

## Verdict

| Dimension | Today | Principal gap |
| --- | --- | --- |
| Security | 6.0 → 8.5 | 2.8 done: ADR 0102's effective visibility is enforced on every surface — lists, pages, search, syndication, profiles, notifications and their inbox, mentions, bookmarks, feed, attachments, realtime and the public cache — and on the write path, and survived two adversarial reviews (15 defects found and fixed). 2.2's antivirus stands. Left: moderation writes ignore scoped role bindings (an owner decision), and `pending` accounts count as members |
| Database | 5.5 → 9.0 | 8.9 and 8.6 done: search uses its GIN and trigram indexes (128 → 14 ms at 100k documents), a signed-in category page is no longer a sequential scan (39 → 0.3 ms at 100k threads), and the retention purge, which had never run against PostgreSQL, now does. The query-plan gate EXPLAINs the application's own statements (8.5), and the Result classes are checked against the migrated schema (5.6) |
| Architecture | 5.0 → 7.0 | 4.5 and 4.9 done: `max_mccabe` is 12, and the layers are declared from the code (ADR 0107) and checked over all 402 modules. ADR 0110 maps each of ADR 0091's mandatory interfaces to the module that implements it and removes five methods nothing called; `Controller::Forum` is still the largest controller |
| Docs & DX | 5.0 → 7.0 | 10.2, 10.3, 10.4, 10.6 and 10.8 done: the quick start creates the database, the ADR set is indexed, the CHANGELOG has Keep-a-Changelog sections with operator actions first, ADR 0109 records that GPForum is an application, and production installs without the develop tools. No release tag yet (10.5), and `prompt/` still contradicts ADR 0087 (10.1) |
| Frontend | 5.0 → 8.5 | 7.1–7.6 done: login links on protected pages, localized error pages, a system font stack that is actually rendered, a header that fits a phone, and the walkthrough defects. No asset pipeline yet (7.7), and the logo's wordmark is live text |
| Performance | 5.0 → 7.0 | 8.1, 8.6, 8.9 and 8.3's eviction cliff done (960× → 1.5×; search and signed-in category pages off the sequential scan). 8.5 done: the plan gate EXPLAINs the statements the application runs and catches a query no index can answer at any size; it no longer fails a correct plan on a small dataset. Ranking a word most documents hold still scores every match (8.10). 8.7 done: a feed item reaches any number of subscribers in one statement. 8.2 done: the page cache is keyed by language and theme, ignores junk parameters and answers before any query; it still has no byte bound |
| Perl craft | 5.0 → 7.0 | 4.1, 4.4 and 4.5 done: 4,681 signatures, 9,311 lines net removed, one row reader in place of 41, `permits` in place of `can`. 4.3 attribute contracts and 4.6's POD remain |
| Perl tooling | 5.0 → 8.0 | 4.2, 4.5, 4.8, 5.3, 8.5 and 10.7 done: no gate can pass without running its tool, coverage is gated at a measured floor, and the query-plan gate EXPLAINs the application's own statements against the schema that exists. 4.7's ratchet is still a flat baseline |
| Correctness | 4.0 → 8.0 | **Phase 1 complete**, plus 4.4's three latent defects: the empty-list column reader, the `can` override, and unique-conflict misclassification |
| Admin console | 4.0 → 8.5 | 6.6 done: the counters, the shared command id and the borrowed audit text are fixed, the four destructive staff actions ask for confirmation, and the audit viewer filters and pages as ADR 0079 requires. 6.5: dead letters replay from the console and the shell (ADR 0056), and the jobs page shows search lag, rebuilds the index through the outbox and purges the page cache; settings and SMTP test-send remain |
| i18n & content | 4.0 → 8.0 | 9.1, 9.3 (time zones), 9.4 and 9.5's renderer defect done: members read times in their own zone, named on the page. Translations are still a Perl literal rather than gettext (9.2), relative time waits on a client-side enhancement, and the markup language has no documentation or preview |
| Testing | 4.0 → 6.5 | 5.0 and 5.1 done; the doubles now also model DBI's "0E0", rollback of row columns, a signed clock offset, and DBIx::Class's list-context `search` — four infidelities that each hid a real defect. CI runs the whole integration tier on PostgreSQL 16–18; its coverage of the correctness invariants (5.2) is still thin |
| Operations | 3.5 → 9.0 | 3.1–3.8 done except the last of 3.5: readiness warns before the partition horizon runs out, and the FreeBSD rc script loads its environment and supervises a foreground Hypnotoad (not yet run on FreeBSD). No replication |
| Admin CLI | 3.0 → 8.5 | 6.1, 6.2, 6.3, 6.4 and 6.7 done: one front door listing 24 commands, `--help` succeeds everywhere, a published exit-code contract, `make help`. `Getopt::Long` deliberately not adopted |

Unweighted mean at the audit: **4.6 / 10**. Now: **7.9 / 10**.

On 2026-09-26 the scores were recalibrated against the measurable criteria in
[What 10 means](#what-10-means). They had been the program's own judgement,
and they had drifted above what the code shows. For example, Perl craft stood
at 9.0, yet no module declares `use v5.40`, 246 `eval` blocks remain, and 312
dependencies may be `undef`. The mean fell from 8.5 to 7.9. No code got
worse; the ruler got honest.

Phases 1 and 2 are closed. What remains is concentrated in the dimensions
the operator and the reader touch — the admin console, the presentation
layer, documentation and i18n. Perl craft, correctness, the database and the
admin CLI are no longer among them.

The distribution matters more than the mean. Security and the database are the
strongest dimensions; the weakest are the two the operator actually touches.
The project has been engineered inward — invariants, ADRs, event contracts —
and not outward, toward the person who has to run it.

## What 10 means

A 10 is not a grade the program gives itself. For each dimension it is a set
of criteria, each checked by an automated gate or by an outside party. A
dimension reaches 10 only when every one of its criteria holds and its gate
runs in CI. The counts below were measured on 2026-09-26.

### Perl craft and tooling

A Perl expert reads any module and finds nothing to rewrite.

| Criterion | Today | Gate |
| --- | --- | --- |
| Errors are exceptions (`GPForum::X::*`), caught with `try`/`catch` | 246 `eval` blocks | no `eval {` outside one adapter module |
| `use v5.40` in every module | 0 of 425 | a test that reads every module's preamble |
| Required dependencies are required at construction | 312 `has … => undef` | no `undef` default for a dependency |
| Roles with `requires` instead of probing with `can` | 208 `->can(` | the architecture check forbids `can('dbh'\|'all'\|'rows'\|'storage')` in `lib/` |
| One utility module | 37 `_trim`, 40 `_column`, 25 `_rows` | no private copy of a shared utility |
| `return undef` under a stated policy, instead of `my $undefined` | 420 | perlcritic, with the policy's reason in `.perlcriticrc` |
| Critic baseline at zero; each remaining exemption a `## no critic` with its reason on the line | 857 baseline lines | the critic gate with no baseline file |
| POD on every public API | 262 modules lack a full POD | `Pod::Coverage` over `Service/` and `Web/` |

### Architecture and maintainability

A change touches one or two modules.

| Criterion | Today | Gate |
| --- | --- | --- |
| A domain model: `Thread`, `Post` and `Membership` hold their own rules (may be edited, is locked, is visible) | the rules live in services | the rule has one definition, and a test proves it |
| The service graph is built once, per application or per request, and injected | helpers call `->new` per use | the layer check |
| No god module | 65 modules over 400 lines; `PostStore` over 1,000 | a module-size gate |
| Tools are not the application | 8,577 lines in `Command/`, benchmarks included | benchmarks move to `tools/` |
| Ceremony proportional to code | 110 ADRs; docs are 33% of `lib/`'s lines (30,805 against 93,993) | live ADRs consolidated, superseded ones archived; docs under 10% of code |

### Testing

Tests break only when behaviour breaks.

| Criterion | Today | Gate |
| --- | --- | --- |
| Tests run on PostgreSQL, each in a transaction rolled back at the end, with a template database per `prove -j` worker | 17,667 lines of doubles in `t/lib` | the doubles are gone, and so is the fidelity test that watches them |
| Concurrency tests on every invariant: edit against lock, delete, counters | a few cases in `postgres-concurrency.t` | one race test per invariant |
| Mutation testing on permissions, visibility and idempotency | none | a mutation-score floor |
| Test files organised by module | chronological numbering | — |

### Database and performance

Numbers measured on a realistic dataset, with a gate that fails when they get
worse.

| Criterion | Today | Gate |
| --- | --- | --- |
| A reference dataset of 1M threads, 20M posts and 200k users, with a hot thread of 50k posts | at most 30 threads × 120 posts in the load benchmark; 100k threads in the plan tests | the dataset is built by one command |
| p95 within the project's own budget at the expected concurrency, scaling with workers | 3.5–4.7 s at 1,000 clients | the load gate |
| A query budget per request | done: 15 pages, anonymous and signed in, each within a measured budget (1–8 statements) and none growing with its rows | `t/integration/postgres-query-budget.t` |
| EXPLAIN on deep pages and on signed-in pages | first pages only | the plan gate |
| No query regresses 20% | — | a `pg_stat_statements` comparison in CI |
| Indexes built `CONCURRENTLY`; `LISTEN` on a dedicated connection so PgBouncer works | not yet | the migration check |
| Keyset pages start the index scan at the cursor | done: `Infrastructure::Keyset` bounds the sort column on every paged list; page 800 of a 50,000-post thread went from 39,008 rows read to 5 | the plan gate on deep pages (to add) |

### Security and correctness

An outside review finds nothing serious.

| Criterion | Today | Gate |
| --- | --- | --- |
| Login is not replayable; no token in `command_log` | done (migration 045) | `postgres-login-replay.t` |
| Logins throttled per account and per address; `trusted_proxies` explicit; unknown accounts cost an Argon2 verification; session checks fail closed | done | `t/203`, `t/53`, `t/111`, `t/177` |
| A reply re-checks the thread's lock and state under its row lock | done (ADR 0111) | `postgres-concurrency.t` |
| A post edit re-checks the post and the thread's lock under its row lock | not yet | a PostgreSQL race test |
| A written threat model, and a penetration test by someone outside | none | — |

### What only reality can certify

- **CI must actually run.** The Actions jobs do not start (the account's
  budget), so every gate is local today, and no 10 can be verified.
- **A tagged release** (10.5), a real FreeBSD deployment, and a restore drill
  that was run, not only written.
- **Real traffic.** People using the forum find what no internal audit does.

### In order

1. Defects and security.
2. PostgreSQL-backed tests in place of the doubles. This comes before the
   refactoring, because it is what makes the refactoring safe.
3. Craft: exceptions, contracts, roles, idioms.
4. Architecture: the domain model, the service graph built once, god
   modules split.
5. Performance at scale: the large dataset, the fixes, the regression gates.
6. Pruning of documentation, ADRs and `prompt/`; CI running; a release; an
   outside review.

Steps 1–4 lead to about 8.5–9. The last point and a half comes only from
steps 5 and 6: measurements at real scale, and someone outside trying to
take it apart.

## Already repaired in this pass

Five changes landed on `main`, because the foundation has to be trustworthy
before anything is built on it. Phases 1.1, 1.2 and 5.0 below are three of
them and are marked DONE in place.

**`make check` was red.** `t/24-advanced-community.t` captured a
transaction-count baseline and then asserted the absolute counter instead of
the delta, and its hand-written plan was one ahead of the assertions the file
runs. Independently, five test files were not perltidy-clean, so the `tidy`
gate failed on its own. Sixteen macOS `<name> 2.<ext>` duplicates were tracked
in git, three of them orphan `.t` files that `prove` was executing as part of
the suite. All six gates now pass: 183 files, 9203 tests.

**The CI entrypoint references were broken.** Five `script/` wrappers had been
renamed to satisfy the `docs/ENTRYPOINTS.md` prefix rule; thirteen callers were
not updated. `release.yml:94` invoked `script/gpforum-os-preflight`, so no `v*`
tag could ever produce an artifact, and the same path broke all three platform
gates. `ops-drills`, `deploy-units` and `postgres-matrix` were equally broken,
the Makefile's `evidence-validate` target ran a second non-existent script, and
`script/gpforum-evidence-archive-check` exited 1 on every run. All thirteen are
repointed, and `script/architecture-check` now carries
`check_entrypoint_references`, which fails when a workflow, the Makefile or
another entrypoint names a repository-relative `script/` or `bin/` path that
does not exist. Reintroducing the `release.yml` breakage was confirmed to trip
it.

## Phase 1 — Correctness and data integrity

Nothing else is worth doing while a write path can silently fail in production.

**1.1 Route every unique-conflict recovery through a savepoint. — DONE.** This
was the single most serious defect in the codebase, and it was proven, not
inferred.

`GPForum::Infrastructure::UniqueConflict::attempt` is the correct primitive: it
wraps the attempt in `svp_begin` / `svp_rollback` / `svp_release`. Twelve
modules use it. Twenty-six others — including `Service::Forum::PostStore`,
`Service::Forum::ThreadStore`, `Service::Attachment::Store`,
`Service::Identity::SessionStore` and `Service::Identity::CredentialStore` —
instead run a bare `eval` inside an open `txn_do` and then keep issuing
statements. `ThreadStore.pm:103` and `PostStore.pm:101` are the canonical
examples.

On real PostgreSQL, any error inside a transaction leaves it aborted until
`ROLLBACK` or `ROLLBACK TO SAVEPOINT`. The recovery code after those `eval`s
cannot execute. Reproduced against PostgreSQL 18 with both patterns side by
side on the same schema:

```
A) bare eval inside txn_do  — the ThreadStore/PostStore pattern
   duplicate insert failed as expected: yes
   RECOVERY READ FAILED: ERROR: current transaction is aborted,
     commands ignored until end of transaction block
   => outcome: ROLLED BACK

B) UniqueConflict->attempt  — savepoint
   duplicate insert failed as expected: yes
   recovery read succeeded
   => outcome: COMMITTED
```

The entire conflict-recovery branch of twenty-six stores is unreachable code in
production. The suite is green because the in-memory doubles in `t/lib/` do not
model aborted-transaction semantics.

86 sites across 28 modules now go through `attempt`. Four defensive evals that
only probe for a storage layer were left alone; they never feed conflict
recovery. Twenty-six modules lost a `use English` import that no longer had a
reader, each removal verified by recompiling under strict.

Two of the twenty-eight were hybrids already using `attempt` in some paths and
a bare eval in others — `Infrastructure::EventRecorder`, on the write path of
every domain event, and `Privacy::DeletionWorkflow`. Enumerating by module
missed both; the invariant below found them.

`script/architecture-check` now enforces that invariant. It does not ban `eval`
— defensive evals are legitimate — it bans `$EVAL_ERROR` and `$@` from reaching
a `*_after_conflict` helper or `UniqueConflict->rethrow`/`is_conflict`. That was
78 violations before and is zero after; reintroducing one was confirmed to fail
the check.

**1.2 Fix `UniqueConflict->attempt` itself before relying on it. — DONE.** It
used a single constant savepoint name and did not release it after a rollback.
DBIx::Class's `svp_rollback` deliberately keeps the named savepoint on its stack
("a rollback doesn't remove the named savepoint, only everything after it"), so
each conflict leaked one subtransaction and a later `svp_release` matched an
inner leftover rather than its own savepoint. Measured against PostgreSQL 18
with a nested pair of conflicting attempts, the stack depth was 2 after the
inner attempt and still 2 after the outer one, where it should be 1 and 0.

`attempt` now lets DBIx::Class mint the name, captures it, and releases it on
both the success and the rollback path, with the teardown guarded so it can
never replace the caller's error with its own. Depths are now 1 and 0.

This had to be corrected before 1.1, which multiplies its blast radius from
twelve call sites to thirty-eight. The unit doubles have no storage layer, so
the regression test lives in `t/integration/postgres-concurrency.t`; it was
confirmed to fail against the previous implementation.

**1.3 Make the audit hash chain affordable. — DONE; the fork half of the
finding did not hold.** The chain cannot fork: `_lock_audit_chain` takes
`pg_advisory_xact_lock` before reading the tip, and `t/159` already pins that
the lock is taken inside the transaction rather than released at statement end.
The tie-break on `audit_id DESC` also makes the tip deterministic for a given
set of rows.

The cost half was real and worse than stated. `audit_log` is partitioned on
`created_at` and carried only a BRIN index there, which cannot answer an
`ORDER BY ... LIMIT`. Measured against 200,000 rows on PostgreSQL 18, reading
the tip was a parallel sequential scan of every partition plus a top-N
heapsort, touching **3,543 shared buffers** — and that ran on every auditable
write while holding the global lock, so every thread creation, moderation
action and privacy request paid it serially.

Migration 039 adds a btree on `(created_at DESC, audit_id DESC)`, matching the
ORDER BY exactly. The same read is now a Merge Append of per-partition index
scans touching **8 buffers**. The integration test asserts the index exists and
that the plan contains no `Seq Scan on audit_log`; dropping the index was
confirmed to fail it.

**1.4 Give worker handler idempotency real mutual exclusion. — DONE, and the
finding was exactly right.** `IdempotentJobRunner::run` asked
`is_done`, ran the side effect, then inserted the key. Nothing held the key in
between. Two workers handed the same event both passed the check, both ran the
side effect, and the loser's primary-key conflict was swallowed by
`EventIdempotencyStore::_accept_conflict` and reported as success. `begin` and
`mark_failed` were bodies that returned their argument.

Measured on PostgreSQL 18 with eight forked workers racing one event:
**eight side effects, three runs out of three.** The mechanism named
idempotency delivered the work eight times and reported that it had not.

The row is now a claim taken *before* the side effect, so the primary key
provides the exclusion: the first inserter owns the event and every other
worker is told to skip. `completed_at` (migration 040) separates "claimed"
from "finished", which one timestamp could not express, and `mark_failed`
deletes the claim so a transient failure stays retryable instead of
suppressing the event forever. A claim is a lease, not a tombstone: a worker
killed mid-flight leaves a row that another worker may take over once it is
older than the lease, reclaimed with a single conditional UPDATE so the
database arbitrates both the expiry and the race. Same measurement after the
change: **one side effect, three runs out of three.**

Migration 040 backfills `completed_at = created_at`. Rows written before it
were inserted only after their side effect had run, so they are complete by
construction; without the backfill every previously handled event would have
looked like an abandoned claim and run a second time on deploy.

Three defects in the fix itself were caught only by running it, and are worth
recording because the unit tier passed through all three:

* `ResultSet::update` returns DBI's `"0E0"` when it matches no rows — zero,
  but **true** in boolean context. `$updated ? 1 : 0` therefore told every
  worker that lost the insert race that it had taken the claim over, and the
  measurement stayed at eight side effects. The comparison is now numeric.
* `event_id` is a `uuid` column, and the claim was deriving it by parsing the
  key's suffix. That works only while every key happens to end in a UUID. The
  event id is now threaded explicitly from the payload through the runner.
* `GPForum::Test::OutboxClock::epoch_plus_iso8601` returned its `future`
  timestamp for *any* non-zero offset, including a negative one. A caller
  asking for "now minus a lease" got a time after now, so every claim looked
  expired — the double would have hidden the duplicate execution it was
  supposed to expose.

The doubles were then taught the behaviour that hid the first defect:
`search(...)->update(...)` returns `"0E0"` rather than `0`, so reintroducing
the trap now fails three unit assertions instead of passing and failing
against a real database.

Not claimed: atomicity between the side effect and the claim. The side effect
is the handler's, some of it is external (mail), and no in-process mechanism
can make an SMTP send and a row commit together. The claim narrows the window
to a crash between the work and `mark_done`, where the lease governs the
retry.

**1.5 Make outbox failure bookkeeping atomic, and stop reporting
acknowledgements that were never verified. — DONE; both halves were real.**

*The failure record was not atomic.* `Dispatcher::_mark_failed` ran
`$message->update(...)` and then `_record_dead_letter(...)` as two separate
writes. A crash between them left a message marked `cancelled` — terminal,
never retried — with no dead letter recording why, so the failure left no
trace anywhere an operator looks. Both writes are now one `txn_do`, and the
test makes the dead-letter insert throw and asserts the status update goes
with it.

*The acknowledgement count was fiction.* `_mark_done_batch_postgresql` issued
`UPDATE ... WHERE outbox_id IN (...) AND locked_by = ? AND status = ?`, threw
the affected count away, stamped `status => done` on every in-memory message
regardless, and returned `scalar @messages` straight into
`$summary{acknowledged}`. The guard exists precisely because the statement can
match fewer rows than it was given — a message whose lease expired and was
re-claimed by another worker is no longer this worker's to acknowledge — so
the dispatcher could report a message as acknowledged while another worker was
still processing it. The statement now ends in `RETURNING outbox_id`, and only
the rows the database named are stamped and counted.

Confirmed against PostgreSQL 18 with the statement the dispatcher issues: two
ids submitted, one still held by this worker, `RETURNING` reports exactly that
one. The old path reported two.

This exposed a fidelity gap in the doubles worth recording, because it is the
same class of problem as 5.0. `GPForum::Test::OutboxSchema` rolled a
transaction back by restoring the row *set*, which is a shallow copy holding
the same row objects, so every column change made by the failed attempt
survived the rollback. A test could not distinguish a rollback from a commit
— exactly what a transactional defect looks like. The snapshot now captures
each row's own columns too, and the atomicity assertion fails without it.

## Phase 2 — Security

**2.1 Make the server-side session token authenticate something. — DONE.**
`SessionStore::_session_row` minted a 32-byte token, hashed it into
`sessions.session_hash`, and let the lexical go out of scope. No caller ever
received it, no cookie ever carried it, and `validate_session` never compared
it — while `Service::SessionToken`'s POD said raw tokens go to cookies.
Authentication rested entirely on the Mojolicious signed cookie.

The token is now load-bearing. It travels out of the store, through the login
result's explicit whitelist, into the signed cookie, and back on every request,
where `validate_session` compares its SHA-256 against the stored digest with a
comparison that has no early exit. A forged or replayed cookie is no longer
sufficient on its own, and `revoked_at` is now enforced against a caller that
must also hold the session's secret.

Verified end to end against the running application: login issues a cookie
carrying the token and `/settings` returns 200; replacing the stored digest so
the cookie's token no longer matches turns the same request into a 302.

**Deploying this ends every existing session.** Rows created before it hold the
digest of a token nobody has, and validation now requires one. That is a
one-time re-login, and it is the correct direction for a session-security
change.

**2.2 Scan uploads for malware. — DONE (ADR 0108).** The audit said uploads
were stamped clean by a scanner that did not exist. That was wrong about the
mechanism and right about the gap: `scan_status` was a content-consistency
check (the stored bytes still sniff to the declared media type), its
`infected` value meant a media mismatch, and nothing inspected a file for
malware, while ADR 0053 made antivirus scanning a MUST. Implementing it found
something the earlier reading of the code missed: the upload marked every file
`clean` synchronously, so the attachment worker meant to re-check the stored
bytes found a finished verdict and returned without reading anything. In the
normal flow the second check never ran.

The owner decided how: assume the free antivirus the operating system's
package manager installs, and bundle nothing. ClamAV is that antivirus on
every supported system, and the OS layer knows where each package puts its
daemon's socket — verified against the packages themselves: Debian's
`/var/run/clamav/clamd.ctl`, the FreeBSD port's `/var/run/clamav/clamd.sock`,
MacPorts' `/opt/local/var/run/clamav/clamd.socket`.

- `clamd` (default in staging and production) is scanned over `INSTREAM`
  inside the upload request; `command` runs any system scanner that follows
  ClamAV's exit convention, for servers that will not keep a 1 GB daemon;
  `none` is explicit and recorded as `format-check`.
- No new upload is served until something has decided. An antivirus that
  cannot answer leaves the upload `pending`; the worker retries through the
  outbox, and the hourly scheduled jobs rescan what is still pending once it
  answers. Files from before stay served until an hourly backfill has put
  them through the antivirus.
- Verdicts only tighten, enforced in the `UPDATE` itself: nothing becomes
  clean over infected or failed, even when two scans race.
- Every verdict records the engine and signature database that reached it,
  and the signature found (migration 043). A media mismatch is now `failed`,
  not `infected`.
- Readiness reports the antivirus `degraded`, never `fail`;
  `bin/gpforum-antivirus-check` proves detection with the EICAR test file.

Tests drive a real UNIX socket speaking clamd's protocol (chunk framing checked
byte for byte, a mid-stream size-limit hang-up, a timeout) and a real scanner
process; `t/integration/clamav.t` runs against a real clamd, which CI starts
from Ubuntu's `clamav-daemon` package with an EICAR-only signature database.
The upload tests fail in fourteen places against the old code.

An adversarial review of the change before it was committed, by independent
reviewers each reproducing their findings, found thirteen defects, all now
fixed and each pinned by a test that fails without the fix. The worst: a
scanner command killed by a signal -- the OOM killer, or a crash on a crafted
file -- has an exit byte of 0, and was recorded as clean. Also: a slow clean
verdict could overwrite a fast infected one; files from before the change
would never have been scanned; a clamd that stops reading could block a
write, and with it the outbox, past any timeout on systems with small socket
buffers; and one file that always failed held back the whole rescan.

Testing the verdict rules against PostgreSQL, rather than the doubles, then
found that **attachment uploads had never worked on a real database**.
Recording a verdict put the scanner's name (`local-sniffer`) into
`event_log.actor_id`, a `uuid` column; PostgreSQL rejected the insert, and the
upload failed. The doubles accept any string, and no integration test had ever
uploaded a file. Verified on the tree before this change. A verdict is now a
system action with a NULL actor and a `scanned_by` field, and
`t/integration/postgres-attachment-scan.t` uploads end to end.

**2.3 Push the search permission filter into SQL. — DONE.** `search_visibility_for`
returned `public, members, private` for any authenticated actor, so the WHERE
clause admitted every private document; the real check ran in Perl *after*
PostgreSQL had applied `LIMIT`.

The consequence, measured against PostgreSQL 18 with 30 private documents
outranking 5 public ones: an anonymous visitor saw **5** results, a signed-in
member saw **0**. Signing in made search strictly worse.

`PermissionEngine` now owns both forms of its rule — `can()` for one row and
`search_condition()` for the query — deliberately side by side, because two
copies of an authorization rule in two modules drift. All four branches were
verified against a live database: public visible, own private visible,
ACL-granted private visible, other people's private never returned.

Writing the wiring surfaced 4.4 in the wild: `$engine->can('search_condition')`
hit `PermissionEngine`'s own `can($actor, $action, …)` rather than
`UNIVERSAL::can`, silently taking the compatibility path. The call site now
says `UNIVERSAL::can` and explains why.

Honest limitation: the integration fixture built to pin this did not reproduce
the ordering in the harness database — its inserted rows never landed, so it
passed for reasons unrelated to the fix. It was removed rather than shipped as
a test that appears to assert something it does not. The unit assertion in
`t/19-search.t` — that the permission predicate is in the WHERE clause and
honours ACL grants — is real and replaced an assertion that pinned the defect.

**2.4 Revoke sibling sessions on password change. — DONE; the session-management
route is still open.** `_apply_reset_password` called
`session_store->revoke_user_sessions`; `_rotate_password` did not. A user who
changed their password because they suspected a compromise left every other
device signed in — which is the one moment the eviction matters most.

`revoke_user_sessions` gained an optional session to keep, and the change path
passes the caller's current `session_id`, so the other devices are evicted while
the browser the user is typing in stays signed in. A reset passes nothing,
because there is no session to keep. The count of revoked sessions is recorded
on the `identity.password.changed` audit action, so the eviction is visible
afterwards rather than silent.

Still open: there is no route where a user can see and end their own sessions.

**2.5 Stream attachment download and give it a bucket. — DONE, and the
finding was partly wrong.** "Authenticate" was the wrong word, and this is the
fourth audit item whose wording did not survive reading the code.
`GPForum::Service::Attachment::DownloadAccess` is thorough: it refuses a
deleted, non-`available` or non-`clean` object, an unlinked object to anyone
but its owner, a profile-linked object to anyone but its owner, and otherwise
requires the target to be moderation-visible *and* the visibility rule to
allow the viewer — public to all, members to any signed-in viewer, private to
the author, else the attachment owner. An anonymous viewer downloading a
public attachment is a public forum working correctly, not a hole. Nothing
needed adding there.

The other two halves were real.

*The bytes were slurped.* `Delivery::download` called
`storage->read_object` and the controller passed the result to
`render(data => ...)`. A 20 MB attachment — the ceiling
`deploy/nginx/gpforum.conf` sets — was pinned in a worker for the life of the
request, once in the scalar and again in the response buffer, multiplied by
concurrency. Delivery now returns `object_path` and reads nothing; the
controller serves it with `reply->asset`, which streams and answers Range
requests. `render(data => ...)` survives only for a backend that cannot name a
path, and no shipped backend takes that branch.

*Download had no bucket.* `_rate_limited_user_id` guarded uploads through
`write_user_id`; `download` called `current_user_id` directly and was the one
attachment route with no limit at all. It now consults
`attachment.download` (120/60s) before doing any work, keyed on the viewer or,
while anonymous, on the peer address — the same `tx->remote_address` idiom
`Controller::Identity::Base` and `Controller::Forum::Base` already use.

Two smaller things fell out of reading this code. The nginx sample has shipped
an internal `/internal-attachments/` alias, and a test has asserted it is kept,
since before anything emitted the header for it — and
`GPForum::OS::RuntimeEvidence` recorded `x_accel_redirect_implemented => 0`
next to it, as a constant. The controller now emits `X-Accel-Redirect` when
`GPFORUM_ATTACHMENT_ACCEL_REDIRECT` is set, so an authorized download behind
nginx never passes through Perl at all, and the evidence field reports what the
running process would do instead of a hardcoded zero. Empty stays the default,
because a proxy that does not understand the header would forward it to the
client. Separately, the store root was hardcoded `var/attachments` while the
nginx comment told operators to point the alias at `/srv/gpforum/attachments`;
it is now `GPFORUM_ATTACHMENT_ROOT`.

The tests were checked against the pre-fix tree rather than trusted: the
streaming assertions fail without the change, and removing the gate alone
fails the three throttle assertions. The double previously returned `content`
for every download, so the unit tier could not have noticed any of this.

Still open: `Range` is served by Mojolicious rather than proven under load,
and no benchmark yet materializes the difference —
`materialized_in_benchmark` stays 0 and honest.

**2.8 Implement effective visibility (ADR 0102). — DONE.** Found while
mapping ADR 0091's interfaces: ADR 0102 is *Accepted* and its own Repository
note says none of it exists on `main`. Verified against PostgreSQL on
2026-09-26 with the seeded forum: after `UPDATE categories SET visibility =
'private'`, an anonymous `GET /categories` lists the category, `/c/:id`
answers 200, and so does a thread inside it. Every reader filters only
`threads.visibility = 'public'` and `posts.visibility = 'public'`; space and
category visibility are never read, and a `members` or `private` thread is
404 to everyone, its author included. The notification and mention leak, the
search, sitemap, feed, cache and attachment rows of ADR 0102's enforcement
table follow from the same absence. Staged: the core readers and the public
cache first, then search and the syndication surfaces, then notifications,
mentions, realtime and attachments, then the write path.

Stage 1 closed the reading surfaces a visitor meets first. A viewer is
resolved once per signed-in request in one statement -- the account's status,
an active suspension, and the scopes of its `category.read` grants -- and
every category list, category page, thread list, thread page and post lookup
filters in SQL before `LIMIT` or checks the single row, on the space, the
category, the thread and the post. Unknown or missing values count as
private. Members now read members-only categories and threads, authors their
own private threads, and grant holders private categories; anonymous and
suspended readers read public content only, and a denied read is 404.
`t/integration/postgres-effective-visibility.t` checks five kinds of reader
against the real application: 8 of its assertions fail on the code before
this change. The query-plan gate shows no new violation; the four it reports
on a local medium dataset (the signed-in category union, post bodies, and two
search statements) fail identically before the change and are recorded for
their own investigation.

Stages 2 and 3 so far: search and autocomplete, the sitemap and feed,
profiles and page metadata, notifications, mentions and attachment downloads
judge the same rule. An adversarial review of stage 1 confirmed nine
distinct defects, all fixed with tests that fail on the old code; the worst
was the thread's second page (`?after=`) showing private replies to any
signed-in reader, and the attachment check served a private category's files
to anonymous visitors. Still open: the notification inbox and unread counts
at read time, realtime channels, bookmarks and the personal feed, thread
creation's visibility inheritance and the public cache fingerprint.

Stage 3 then closed the lists and realtime: the inbox, unread count and
badge, mentions, bookmarks and feed filter in SQL, and realtime thread
channels re-authorise at subscribe and at every broadcast. Measured on the
medium dataset, the feed and inbox pages went from 0.02–0.04 ms to 0.13–0.26
ms, with no sequential scan and no new plan violation; the first, uncorrelated
form of the filter scanned every thread and was replaced. The integration
tier caught a regression the unit doubles could not: the mention store still
called the notification-only `can_notify`, and every mention was dropped.
The write path followed: new threads and replies inherit the effective
visibility of their category or thread and may not ask for a broader one, so
members-only writing stays members-only if an administrator later opens the
category. Last, the public HTTP cache: instead of a render-time fingerprint,
the outbox's cache handler now purges the public pages that events change.
It had never invalidated a thread's public page, and ignored post
moderation entirely, so hidden content stayed on cached anonymous pages for
up to a minute.

## Phase 3 — Operability

This is where the project scores worst, and where the fixes are cheapest.

**3.1 Stop discarding the production log. — DONE.** `Mojo::Server::daemonize`
(`Mojo/Server.pm:40-42`) reopens `STDOUT` and `STDERR` on `/dev/null`.
Hypnotoad daemonizes. Mojolicious's default logger writes to `STDERR`, and
`GPForum::Log::configure` sets only the *level* — never a path and never a
handle. The repository ships no `log/` directory and none of the three service
units set `StandardOutput=`. Under `deploy/systemd/gpforum.service`, the
FreeBSD rc script and the launchd plist, every application log line is
discarded. There is no way to debug a production incident.

`GPForum::Config` gained `log_path` from `GPFORUM_LOG_PATH`, and
`GPForum::Log::configure` points the logger at it. All seven shipped units —
four systemd services, the FreeBSD rc script and both launchd plists — now name
a destination, with `LogsDirectory=` creating and owning it on systemd. The
deploy contract requires the line, so a unit that drops it fails
`t/166-deploy-contract.t`.

Leaving `log_path` empty keeps the logger on STDERR, which is right for a
foreground process under a supervisor that captures it.

Not done, and deliberately: the units still use `Type=forking` with Hypnotoad
daemonizing. Running in the foreground under `Type=notify` would route logs to
journald and fix 3.3 at the same time, but systemd cannot be exercised on the
development host, so restructuring the process model on untested reasoning was
not worth the risk. Structured output with the correlation id is also still
open.

**3.2 Ship a reverse-proxy sample that terminates TLS. — DONE, and the finding
was overstated.** The Caddyfile was always fine: Caddy provisions TLS
automatically for a named site, so `forum.example.com { ... }` is already HTTPS.
Only the two nginx samples listened on port 80 alone.

That mattered because `Bootstrap::Security` sets `sessions->secure(1)` whenever
`requires_secure_transport` is true, which covers staging and both production
profiles. A browser will not send a `Secure` cookie back over plain HTTP, so the
documented nginx deployment could not keep anyone logged in.

Both samples now redirect port 80 to HTTPS with an ACME challenge passthrough,
and terminate TLS 1.2/1.3 on 443 with HTTP/2. HSTS is deliberately not repeated
at the proxy: `Security::BrowserHeaders` already sets it, and two
`Strict-Transport-Security` headers is a misconfiguration. The deploy contract
requires the TLS listener, the certificate and the redirect, and removing any of
them was confirmed to fail `t/166-deploy-contract.t`.

Not verified here: nginx is not installed on the development host, so the
sample's syntax has not been through `nginx -t`.

**3.3 Fix `systemctl reload`. — DONE, and the fix this plan proposed was
wrong.** The diagnosis held: `ExecReload` was byte-identical to `ExecStart`,
running hypnotoad against a live instance is its hot-deploy path, and under
`Type=forking` with `PIDFile=` systemd kept tracking the manager it read at
start. The reload handed the service to a process systemd no longer supervised.

But `ExecReload=/bin/kill -USR2 $MAINPID` does not fix it. `USR2` **is** the
hot deploy — `Mojo::Server::Hypnotoad`'s own documentation says the new manager
sends `QUIT` to the old one and takes over — so the manager moves either way.
Hypnotoad has no reload-in-place signal at all: `INT`/`TERM` and `QUIT` stop it,
`TTIN`/`TTOU` resize the pool, `USR2` replaces the manager.

There is therefore nothing honest to put in `ExecReload=`, and it is gone.
`systemctl reload` now fails with "operation not supported" instead of stopping
the forum, `systemctl restart` is the supported path, and `TTIN`/`TTOU` resize
workers without moving the pid. `docs/ops/reload-and-restart.md` says all of
this, the units carry the reasoning inline, and `t/166` fails if an
`ExecReload` reappears.

The durable fix remains `HYPNOTOAD_FOREGROUND=1` under `Type=notify`, which is
the same restructuring 3.1 left open and still cannot be exercised here.

**3.4 Make the FreeBSD unit able to start. — DONE in the script; not yet run on FreeBSD.** The rc script exports only
`GPFORUM_ENV` and `MOJO_MODE`; rc.conf variables are never exported, so there
is no FreeBSD analogue of `EnvironmentFile=` and a production start dies in
config validation. `daemon(8)` also cannot track the double-forking Hypnotoad
manager.

Both halves were as described. The rc script now exports
`/usr/local/etc/gpforum/gpforum.env` (`gpforum_env_file`) into the service --
the counterpart of `EnvironmentFile=` -- and refuses to start when the file
is not root's, is readable by others or writable by its group, since it holds
the database password and the session secret. Hypnotoad runs in the
foreground (`-f`) under daemon(8) with separate pidfiles for the supervisor
(`-P`, what rc tracks through `procname=/usr/sbin/daemon`) and the manager
(`-p`, what the stop sends Hypnotoad's graceful QUIT to). `t/18` pins each
part and fails eight ways on the old script. What is not proven: a start on a
FreeBSD host. The `platform-freebsd` workflow would run it, and CI is blocked
by the Actions budget.

**3.5 Make the migration runner safe. — Two of four done; the third is blocked
by a constraint worth recording.**

Two hosts migrating at once was not theoretical. Racing two processes against
an empty database, the second died on `duplicate key value violates unique
constraint "pg_type_typname_nsp_index"` — both had read an empty
`schema_versions` and proceeded. `apply_pending` now holds one session-level
advisory lock across the whole run; session-level and not transaction-level,
because the migration files open and commit their own transactions and an xact
lock would be released by the first `COMMIT`. Re-raced: one worker applies 38,
the other waits and finds nothing pending, zero duplicate versions.

Checksums were stored and never compared, which makes the column a comment.
`verify_applied` now runs before every apply and rejects a migration whose file
changed after it was recorded.

The version row still cannot be made atomic with the DDL, and the reason is
structural: 36 of the 38 migration files carry their own `BEGIN;`/`COMMIT;`, so
the runner cannot own the transaction without rewriting them — and rewriting
them changes their checksums, which every existing deployment has recorded and
which the runner now verifies. The two changes are mutually exclusive unless the
historical checksums are migrated too. None of the files contain a statement
that cannot run inside a transaction, so the refactor is possible; it is a
deliberate schema-history decision, not a defect fix.

The fabricated `migration_safety` metadata is also still open.

**3.6 Delete or implement `etc/*.conf`. — DONE: deleted.** Nothing opened
them — no `open`, no `do`, no slurp, anywhere in `lib/`, `bin/` or `script/` —
while ADR 0077 listed them under **Code** and
`docs/architecture/operational-profiles.md` called them the source of the
profile values. An operator editing one got silence, and the documentation told
them it should have worked.

They were removed rather than wired up. The environment is already the
configuration mechanism, it is documented, and a second one with undocumented
precedence against it is worse than none. ADR 0077 and the architecture doc now
say where the values actually live — the `%PROFILES` constant in
`Service::Operations::Profile` — and ADR 0077's stale claim that attachment
storage is hard-wired to `var/attachments` is corrected, since 2.5 made it
`GPFORUM_ATTACHMENT_ROOT`.

**3.7 Extend the partition horizon and alert on it. — DONE for the alert;
extending stays the monthly command.** Partitions exist only
through 2027-01-01; extending them is a manual operator task and nothing warns
when the horizon approaches.

`bin/gpforum-partition-maintenance --apply` already extends the horizon and
must stay a deliberate, windowed operation: `CREATE TABLE ... PARTITION OF`
takes `ACCESS EXCLUSIVE` on `audit_log`, which every audited write waits on,
so it was not moved into the hourly job. What was missing was the warning.
`/readyz` now has a `partition_horizon` check: one catalog query for each
table's last range bound and one `EXISTS` per DEFAULT partition, degraded
when less than 45 days remain (a missed monthly run at the default lookahead)
or when rows have already spilled into DEFAULT. Degraded, not failed -- writes
still land. `t/integration/postgres-partition-horizon.t` reads the real
catalog: 97 days today, a warning on 1 December, and a row dated past the
horizon caught in `audit_log_default`. On this repository's own schedule the
check first warns around 17 November 2026.

**3.8 Document and test a restore. — DONE, and the finding was half wrong.**
`script/staging-drill` **is** a restore drill: it dumps a migrated database,
restores it into a throwaway one and asserts the row counts match. That half of
the claim does not hold.

The half that held is sharper than the original wording. **ADR 0050 line 225
requires operators to run PostgreSQL with replication, WAL archiving and
PITR**, and the repository shipped nothing to meet it — `wal_level`,
`archive_command` and `recovery_target` appeared nowhere outside that ADR. The
same shape as ADR 0053's antivirus MUST in 2.2: a requirement placed on an
operator with no means of meeting it and no way to find out whether it works.

`script/pitr-drill` rehearses it end to end against a throwaway cluster it
builds itself. It applies the configuration the runbook documents, takes a base
backup, writes rows on either side of a recovery target, restores to that
target, and checks that the rows before it came back and the rows after it did
not — because the failure worth catching is a restore that silently lands on
the wrong instant, and row counts alone would not catch it.

Verified on PostgreSQL 18: three rows before the incident, two recovered, the
row written after the target correctly absent. Also verified in the failure
case operators actually hit — archiving that discards WAL, where the base
backup is fine but recovery cannot reach the target — which now reports
`status=fail reason=recovery-did-not-start` instead of a bare `pg_ctl` error.

`docs/ops/backup-and-restore.md` is the runbook: what the two recovery stories
cover, why a nightly dump alone costs a day of posts, the archive
configuration and why `archive_command` must fail loudly, the restore
procedure, and the warning that **attachments are in neither backup** — the
database keeps only object keys, so a restore without the blob tree gives a
forum whose attachments all 404.

Still open: replication. ADR 0050 asks for that too and nothing here sets up a
standby, so this is a recovery story and not an availability one — recovering
means downtime for however long the replay takes. Said plainly in the runbook
rather than left to be discovered.

## Phase 4 — Perl craft

This is the dimension the owner weights highest, and the gap is structural
rather than cosmetic.

**What is already good and must be preserved:** one object system used
consistently (`Mojo::Base -base` across 238 of 377 modules, zero Moo/Moose/
Object::Pad drift); no dynamic-Perl abuse anywhere — zero `no strict`, zero
string `eval`, zero `AUTOLOAD`, zero symbolic references; real Carp discipline;
`Const::Fast` used pervasively instead of bare literals; SPDX headers and
`our $VERSION` on 100% of modules.

**4.1 Write the Perl the project claims to require. — DONE.** `cpanfile:1`
required perl 5.038.0 and the tree was Perl 5.16: zero of 377 modules used
signatures, `use feature`, or `builtin::`. `Mojo::Base` pins the feature bundle
at `:5.16`, so the later features were not merely unused — they were switched
off.

All 378 modules now enable signatures (`-signatures` on the `Mojo::Base`
import for 356, the plain `feature` pragma for the 22 that do not use it), and
**4,681 subroutines carry a signature**. The diff is 5,075 insertions against
14,386 deletions: **9,311 lines net removed**, almost all of it the
`my ( $self, ... ) = @_;` prologue and its trailing blank line.

The conversion was mechanical and conservative by construction. A PPI pass
rewrote a subroutine only where it could prove the prologue was the first
statement, the parameter list was simple, and nothing else in the body touched
`@_`, bare `shift` or `goto`. 4,681 of 4,977 subroutines qualified; the other
296 are untouched and still use `@_` — 43 because they genuinely need the
argument list, 253 because they take no arguments.

**What it found.** Signatures enforce arity, so every call site that had been
passing the wrong number of arguments now dies instead of silently binding
`undef`. Thirty-nine subroutines had a trailing parameter that some caller
omitted; each now says so with `= undef`, which turns implicit optionality
into a declaration. In three cases the body already contained
`defined $status ? ... : $DEFAULT`, so the signature now states what the code
already implied.

Two were real defects rather than optional parameters:

* `OS::CpuCount::_probe_sysconf` took `($self)` while the other three entries
  in the `%PROBE_FOR` dispatch table took `($self, $source)` and the table
  calls every one of them as `$probe->( $self, $source )`. The extra argument
  used to be discarded; under a signature the call died, `_probe` swallowed it
  in an `eval`, and the CPU count silently fell back to 1. A dispatch table
  whose members disagree about arity is a latent bug that nothing had surfaced.
* `Command::PartitionMaintenance::_print_error` and `_usage` were called both
  with and without their last argument from different paths.

Finding those needed a tool, because this codebase catches exceptions into
result hashes: an arity failure inside `eval` never reaches the test output.
A `$SIG{__DIE__}` hook — which fires even for exceptions an enclosing `eval`
will catch — was run over the whole suite, holding a dup of fd 2 taken at load
time because some tests localize `*STDERR` to an in-memory scalar and would
otherwise swallow the report as well. It was verified by reintroducing a fixed
defect and watching it fire. The suite is green with zero arity failures
anywhere, swallowed or visible.

**What the unit suite could not see.** Arity is a contract with the caller,
and some callers are not in this repository. Two such contracts broke and the
unit tier stayed green, because it never runs the caller; the PostgreSQL tier
found both on its next run.

* `DbQueryStats::query_start` is DBIx::Class's debug callback, called as
  `query_start($sql, @bind)`. A two-argument signature made every query with a
  bind value die inside DBI — the home page returned 500.
* The JSON column codecs are called as `->($value, $row)`. A one-argument
  signature made every JSON column write die.

Both now take the extra arguments explicitly, and both unit tests call them
the way the framework does and were confirmed to fail without the fix. The
other framework-facing subroutines — plugin `register`, command `run`, `has`
defaults, the `\&` dispatch tables — were checked by hand and are correct.

The same run exposed a family that predates signatures. DBIx::Class's `search`
returns a resultset in scalar context and every row in list context, and five
call sites passed it straight into a helper, and one more returned it to a
caller in list context. Before signatures each helper silently bound the first
row. Checked against a checkout of the tree as it was before 4.1:

* **The retention purge had never worked against PostgreSQL.**
  `bin/gpforum-scheduled-jobs` died on its first job with
  `Can't locate object method "all" via package "…::Session"` — sessions,
  identity tokens, rate-limit windows, outbox rows and dead letters were never
  purged by it. No test had run a purge against a database.
* A public profile reported **0** threads for an author with 3.

Every one of the 102 calls in `lib/` is now `search_rs`, which returns a
resultset in every context. `t/191-resultset-context.t` rejects a bare
`->search(` in `lib/`, and `t/integration/postgres-retention.t` and the profile
checks in `t/integration/postgres.t` pin both defects at the tier that can see
them; each was confirmed to fail on the old code. The doubles had hidden the
whole family, because they return the same object in any context.

**The cost, stated plainly.** PPI 1.291 has no signature support: it tokenizes
`sub f ($self, $x)` as a `PPI::Token::Prototype`. So
`Subroutines::ProhibitSubroutinePrototypes` (severity 5) and
`ValuesAndExpressions::RequireInterpolationOfMetachars` fire on every
signature, and neither offers a way to exempt them. Both are disabled.

The severity-5 one is replaced rather than dropped: `script/architecture-check`
now bans real prototypes directly, and can be exact because a prototype
contains only sigils and punctuation while every signature here names at least
one variable. The tree contains no real prototypes, and the guard was confirmed
to fail when one is added. The interpolation policy — severity 1, and its own
message says a string *may* require interpolation — is a genuine small loss.

Not done, deliberately: `use strict; use warnings;` stays, although
`Mojo::Base` makes both redundant. Removing them would mean reconfiguring the
two critic policies that check for them by name, trading a real signal for a
line count.

**4.2 Make the declared dependency set true. — DONE.** `Type::Tiny` and
`Syntax::Keyword::Try` are declared as hard runtime dependencies in `cpanfile`
and have **zero** call sites anywhere in the repository — verified across
`lib/`, `bin/`, `script/` and `t/`. Eight declared dependencies are unused in
total. Both are gone, along with `Log::Any`, `Log::Any::Adapter`,
`DateTime::Format::Pg` (nothing loads `InflateColumn::DateTime`, so DBIC never
inflates a timestamp) and three unused `develop` test modules.

The more serious half was the inverse. `Service::Identity::Mailer` requires
`Email::Simple`, which the manifest never named — the deployment worked only
because `Email::Sender` happens to install it. `Email::MIME` was declared and
loaded by nothing. They are now swapped. `GlifiStore::Client` is still required
by a production path and named in no manifest; it is recorded as a known
exception rather than quietly ignored.

`t/182-dependency-declaration.t` enforces it: every module `lib/` and `bin/`
load must be core, `GPForum::`, or provided by a distribution in
`cpanfile.snapshot`, with a documented allowlist for anything loaded through a
mechanism a static reader cannot see. Introducing an undeclared module was
confirmed to fail it.

**4.3 Introduce attribute contracts.** There are 271 mandatory collaborators
declared as `has X => undef;`, three `sub new` overrides in 377 modules, and a
constructor that silently accepts misspelled keys. A missing collaborator
should die at construction, not forty frames deep.

**4.4 Remove the three latent defects a Perl reviewer flags on sight. —
DONE; all three were real, and the second was worse than reported.**

*`sub can` overriding `UNIVERSAL::can`.* Two authorization classes,
`Search::PermissionEngine` and `Realtime::SubscriptionPolicy`, defined
`sub can`, so `$object->can('some_method')` asked an authorization question
instead of reporting whether the method exists. This bit for real earlier in
this pass: the capability probe for `search_condition` called the
authorization method. Both are now `permits`, all six call sites follow, and
`$engine->can('new')` returns a code reference again.

*The `_column` sprawl.* The audit said 39 copies with three return semantics.
There were **41, in thirteen distinct spellings**, and six ended in a bare
`return;`. In list context that is the empty LIST, not undef — and every one
of those six is called from inside a hash literal:

    calculated_at => _column( $row, 'calculated_at' ),
    score         => _column( $row, 'score' ),

Reproduced with a row that was not found: `calculated_at` takes the value
`'score'`, `trust_level` takes `'user_id'`, and the user id becomes a key.
Perl reports only "Odd number of elements in hash assignment". Forty-five call
sites across five modules were exposed to this.

`GPForum::Infrastructure::Row->column` is now the one reader, returning undef
in either context. The 33 copies whose semantics it reproduces exactly
delegate to it, including all six buggy ones. Eight are deliberately different
— one croaks, two use a column accessor, two delegate to an object reader, one
returns the empty string — and were left alone rather than silently
harmonised. `t/183` pins the behaviour and carries the old body as a negative
control, so the assertion cannot pass vacuously.

*Unique-conflict classification.* `_matches_unique` matched the five digits of
SQLSTATE `23505` **anywhere** in the error text, so `deadlock detected at byte
offset 123505` classified as a duplicate key — and the recovery path swallows
whatever it classifies, discarding the real error. The match is now delimited
by non-digits. The English fallbacks (`duplicate key`, `unique constraint`)
remain, but `lc_messages = 'C'` is pinned at connect: under any other locale a
real unique violation would have read as an unknown error and savepoint
recovery would have rethrown it. `t/01-config.t` pins the connect contract, so
dropping the setting fails.

Two guards were added to `script/architecture-check`, both confirmed to fail
when the defect is reintroduced: `sub can` in `lib/` or `t/` is refused, and a
column reader ending in a bare `return;` is refused.

**4.5 Raise `max_mccabe` from 5 to 12. — DONE, and the number is now
measured rather than argued.** Complexity was measured across all 3,333
subroutines in `lib/` before changing anything:

| | median | p90 | p95 | p99 | max |
| --- | --- | --- | --- | --- | --- |
| McCabe | 2 | 4 | **5** | 9 | 17 |

The old limit of 5 sat exactly on the 95th percentile. A limit there does not
mark exceptional complexity; it marks the ordinary tail of a distribution the
limit itself produced. What it bought was not simple code but shredded code:
`PostStore.pm` is 1,348 lines and 96 subroutines, 92 private, **64 of them
called from exactly one place**, and the same shape repeats across 36 modules.
It also manufactured **442** `my $undefined` declarations — whose only purpose
is to return undef from a subroutine too small to say so — and six separate
`%seen` reimplementations of `uniq`.

At 12, seven subroutines remain flagged (0.21%), each a genuine dispatch or
classification function: `EvidenceValidate::_detect_type` (17),
`Bootstrap::UI::_register_presentation_helpers` (15),
`DeadLetterCheck::_row_matches` and `RuntimeEvidence::_probe_socket_option`
(14), and three at 13. Perl::Critic's own default for this policy is 20. The
measurement is recorded in `.perlcriticrc` beside the number so the next person
does not have to re-derive it.

`force = 1` is also gone. It told Perl::Critic to ignore every `## no critic`
marker, and the tree carries ten of them, each naming one policy, none of which
had any effect. The only way to accept a violation was the free-form baseline,
which records no reason and cannot be reviewed. That is backwards: a reviewed
annotation at the site of the code is better evidence than a line in a list.
This is the precondition for 4.7.

**4.5a The critic gate was not running. — FIXED.** Found while doing the
above, and it invalidates every "critic green" claim made from this host,
including the ones recorded earlier in this pass.

`script/perlcritic` chose its runner with `command -v carton`. On this host —
the documented setup, where dependencies are vendored in `local/` and reached
through `script/gpforum-carton` because Carton itself is not installed — that
test failed, the runner stayed the bare name `perlcritic`, which is not on
`PATH`, and `xargs` exited with "No such file or directory". The gate then
grepped an error message for violation lines, found none, computed zero new
violations against the baseline, printed **`status=ok new_violations=0`** and
exited 0. `make check` ran it and believed it.

The only visible symptom was every baseline entry reported as "not observed in
this environment", which reads like good news and appears after the status
line.

Three changes: the runner is `script/gpforum-carton exec perlcritic` when
`local/` exists, matching what `script/perltidy-check` already did; a
non-zero analyser exit with no parseable output now fails; and "no violations
at all while the baseline is not empty" now fails, because that is what a gate
that did not run looks like. Both guards were confirmed by breaking the runner
on purpose — it reports "the analyser did not run (exit 127)" instead of
success — and a deliberately introduced violation now fails the gate with exit
1, where before it passed.

Running it for the first time on this host found **877** violations, not the
694 the baseline recorded. The baseline is regenerated from that run, so the
ratchet is now anchored to a measurement rather than to an environment nobody
here has. The number going up is not new debt; it is debt that was invisible.

Of the 289 initially outside the baseline, 17 were in files touched during this
pass — written blind, because the gate was not checking. They are fixed rather
than baselined. One of them was a real bug that the tests could not see:
`chr 13 . chr 10 . 'X-Injected: 1'` parses as
`chr( 13 . chr( 10 . 'X-Injected: 1' ) )`, because named unary operators bind
looser than concatenation, so the header-injection fixture was a bare CR with
the header silently dropped. The test still passed, because a lone CR fails the
same whitelist. perlcritic caught it; nothing else would have.

**4.6 Document the 223 modules that have no POD,** and delete the
`RequirePodSections` boilerplate from the 154 that do — "None known." appears
136 times and is not documentation.

**4.7 Retire the perlcritic baseline.** `etc/perlcritic-baseline.txt`
grandfathers 694 violations at `severity = brutal`, of which 138 are magic
numbers and 118 are excess complexity. Replace the free-form baseline with a
per-policy `.perlcriticrc` plus a countdown ratchet that can only decrease, and
targeted `## no critic` annotations that each carry a justification.

**4.8 Commit a `.perltidyrc`. — DONE.** The format of 93,000 lines was defined by Perl::Tidy's
implicit default, so an upgrade would have rewritten the tree at once. The
profile writes those defaults down and `script/perltidy-check` passes it
explicitly; the tree is byte-identical under it, which is the evidence it
describes the existing style rather than imposing a new one.

`perltidy-check` now also selects the Perl programs under `script/` by shebang,
which `script/perlcritic` already read and the formatter did not. That found one
file, `script/cpan-license-check`, that had never been formatted.

**4.9 Make the declared layering the real one. — DONE.** The audit found the
declared layering "0.3% real": `ARCHITECTURE.md` listed `Domain`,
`Application`, `Query` and the other namespaces ADR 0052 and ADR 0064
recommend as future boundaries, and they held two modules out of 402. The
MUST in ADR 0064 — explicit layers, dependencies flowing inward — was checked
by nothing.

Measured, the real graph was nearly layered already; seven dependencies
pointed up. A service ran two CLI commands, a service used a worker's module,
the event recorder in `Infrastructure` used two services, and two commands
built the application class themselves. ADR 0107 declares the layers the code
has — foundation, service, presentation, adapter, composition — in
`Application::LayerMap`, and `t/192-layering.t` checks every module in `lib/`
against it: every module must be in a layer, and no `use`, `require`,
superclass or `Class->method` may point above its own. The seven edges are gone
(`Service::Id` is `Infrastructure::Id` across 45 files, the outbox builder and
the handler-idempotency module moved down a layer, the drill applies migrations
through `Migration::Runner` and is handed its seed step, the commands are
handed the application by their entry points), and the unused
`Query::ReadModel` stub is deleted. The test and `script/architecture-check`
both fail on the old tree, naming all seven.

ADR 0107 is explicit that this is layered, not hexagonal: services use
DBIx::Class directly, so ADR 0064's recommendation of infrastructure-independent
business logic is not met, and the ADR says so instead of claiming it.

## Phase 5 — Testing honesty

The suite runs 9,203 assertions in 14 seconds without a database. That speed is
purchased by testing hand-written in-memory doubles, and the doubles are where
the bugs hide.

**5.0 Teach the doubles PostgreSQL's aborted-transaction rule. — DONE.** This
was the structural reason 1.1 survived: `GPForum::Test::Schema` exposed no
storage layer, so `UniqueConflict->attempt` degraded to a plain eval and the
unit tier could not tell a savepoint-guarded recovery from one that aborts the
transaction on a real database.

`GPForum::Test::Storage` now provides the savepoint surface the application
depends on — `svp_begin`/`svp_rollback`/`svp_release` over a named stack, with
`svp_rollback` keeping its own savepoint the way DBIx::Class does — and
`GPForum::Test::Dbh` a blessed handle carrying `AutoCommit`. A conflict inside
`txn_do` now marks the transaction aborted, every later read is refused with
PostgreSQL's own 25P02 wording, and only a rollback to a savepoint clears it.

The effect is the point: with the pre-fix `ThreadStore` in place,
`t/11-forum-thread.t` now fails in 0.15 seconds with no database, reporting
exactly the error the real server produced. It passed before. The whole suite
was re-run against this: one file, `t/12-forum-post.t`, failed — and it failed
honestly, because `PostStoreLockStorage` lacked the savepoint surface, which is
itself the same defect one level down. `t/176-test-double-fidelity.t` pins the
new semantics.

**5.1 Roll the transactional base out to every double. — DONE, with a caveat
about how it landed.** `GPForum::Test::TransactionalSchema` now holds the
transaction depth, aborted flag, snapshot/restore and savepoint-capable storage,
and nine doubles inherit it: Schema, AuditChainSchema and PostStoreLockSchema
via Schema, plus Attachment, Community, Moderation, Notification, Outbox,
ReadState and Search. Their resultsets guard every read with the 25P02 rule and
mark the transaction aborted on a unique conflict. The suite is green at 9211
assertions.

Three doubles declared `has storage => undef`, which made
`UniqueConflict::_savepoint_storage` bail out — so conflict recovery degraded to
a plain eval and no savepoint was ever taken, even where the production code was
correct. That is now fixed.

The caveat: this rollout was committed by accident inside `e10316a`, whose
message describes only the Accept-Language fix. `git add -A` ran while the
agents were still writing. The history is not rewritten because the branch is
shared and already pushed; this entry is the record.

Still open in this area: `GPForum::Test::CommunityRow::update` has no abort
guard, so an UPDATE after a failed INSERT still succeeds in that double where
PostgreSQL would refuse it. Three resultset-backed schemas each carry their own
copy of the row-set snapshot, which wants a shared helper. And `.perlcriticrc`
sets `force = 1`, which makes Perl::Critic ignore `## no critic` annotations, so
the rethrow shape these doubles now share needs either baseline entries or that
setting dropped.

**5.2 Fix the doubles that invalidate their own tests.** The search double
matches every document unconditionally, so the entire search and ranking
feature has zero behavioural coverage. One query double ignores the `WHERE`
clause entirely. `t/176-test-double-fidelity.t` pins 3 of the 10 query engines
in `t/lib/` and misses both of the broken ones. Twenty-two of the twenty-five
schema doubles still declare no storage at all and should adopt
`GPForum::Test::Storage` the way `GPForum::Test::Schema` now does.

**5.2 Make the integration tier real and mandatory. — Mandatory: DONE. Real:
in progress.** Search results now have behavioural coverage on PostgreSQL
(`t/integration/postgres-search-results.t`): title against body ranking, the
AND of two words, typos by trigram, and the autocomplete prefix. Its first
run found autocomplete suggesting a thread's title once per reply (post
documents carry their thread's title), now limited to threads, and recorded
that the fuzzy arm compares the whole query with each title, so a two-word
query also finds titles sharing either word (by 8.9's design; ranked by
similarity). Six integration tests pass against PostgreSQL 18 (307
assertions). Twice now the tier has found what the unit suite could not — the
search indexes the query could never use (8.9), and the call contracts and
list-context defects recorded under 4.1 — and both times only because someone
happened to run it.

Both CI workflows used to run it as a list of four file names, so the two
newest files never ran on PostgreSQL 16, 17 or 18. They now run
`make integration`, which runs the directory and — because without a DSN every
test skips, and an all-skipped tier has not passed — refuses to run at all
without `GPFORUM_DATABASE_DSN`. `t/190-gate-honesty.t` fails if either
workflow names a single integration file again, or if the target stops
refusing; it was confirmed to fail on the old workflows. Every invariant in `docs/ENGINEERING_CORRECTNESS.md`
that is about SQL, constraints or locks needs a test at that tier — starting
with the conflict-recovery paths from Phase 1, which are green today precisely
because no double can express the failure.

**5.3 Make the coverage gate a gate. — DONE.** Both halves held.
`script/coverage` ran the suite under Devel::Cover, printed a table and exited
0: no threshold of any kind, so the CI step named "Run coverage gate" could not
fail. And it selected `^(lib/GPForum|t)/`, putting the test files — which
execute almost entirely — into its own denominator.

It now reports `lib/` only and hands the verdict to `script/coverage-check`,
which reads the totals from the coverage database with `Devel::Cover::DB`
rather than scraping the report, and compares them with `etc/coverage-floor`.

Measured over the 402 files in `lib/`, test files excluded:

| Criterion | Coverage | Floor |
| --- | --- | --- |
| statement | 88.7% | 88.5 |
| subroutine | 93.3% | 93.0 |
| branch | 68.2% | reported, not gated |
| condition | 47.1% | reported, not gated |

The floor is a ratchet: raised when coverage improves, never lowered to make a
build pass, and the check says when a criterion sits a point or more above it.
It sits a few tenths below the measurement to absorb run-to-run variation, not
to leave room for regressions. Confirmed both ways: it passes at the recorded
floor and fails with `status=fail` when the floor exceeds the measurement.

Branch and condition coverage are the honest weak spot — a codebase that
tested every subroutine and two thirds of its branches — and gating them is
the next ratchet, not this one.

**5.4 Test behaviour, not shape.** 132 assertions pin the DBIC query hashref
and even raw SQL text rather than the rows returned. `t/102-web-guard.t:34`
asserts the *payload* says `unauthorized` — and passes — while the rendered page
is broken (see 7.2).

**5.5 Eliminate the hand-counted plan.** 60 files carry a manual
`plan tests => N` against a schema mutated over hundreds of lines; 123 already
use `done_testing`. The mixed convention is what broke `t/24`. Standardise on
`done_testing`, and restructure `t/` into `t/unit/`, `t/integration/` and `xt/`
instead of 186 numerically-prefixed flat files.

**5.6 Compare the Result classes with the schema the migrations build. —
DONE.** Two descriptions of one schema — the migrations and the 60
DBIx::Class Result classes — and nothing compared them.
`t/integration/postgres-schema-drift.t` migrates a fresh database and checks
every table, column, type, nullability, primary key and unique key against the
Result classes. Types and primary keys already agreed everywhere; the check
found three kinds of drift, all now fixed:

* **Two unique keys declared broader than the database enforces.**
  `credentials.user_id` is unique only among active passwords and a role
  binding's scope only among unrevoked bindings — partial indexes, which
  DBIx::Class cannot express. Declared as plain unique keys, they would let
  `find()` treat those columns as a unique key and return a revoked row.
  No code does that today; the declarations are gone, with a comment where
  each was saying why. A partial index is accepted only when its predicate is
  its own columns being `NOT NULL`, which changes nothing for a lookup by
  value.
* **Three unique keys under names the database does not use**, among them the
  moderation command key. Each now carries the index's real name.
* **One nullability disagreement.** `search_documents.title_normalized` is
  generated from a `NOT NULL` title and can never be null, but the column did
  not say so. Migration 042 adds the constraint.

The check was confirmed to fail on the old tree, naming each defect.

## Phase 6 — System-administrator ergonomics

**6.1 Give the operator one front door. — DONE.** `bin/gpforum` started
`Mojolicious::Commands` without registering a command namespace, so it printed
stock Mojolicious help — including `cpanify`, "Upload distribution to CPAN" —
and listed **none** of the project's 22 operational commands.

`GPForum::CLI::*` now holds one thin `Mojolicious::Command` adapter per
command, and the app registers the namespace. `gpforum` lists all 22 with
descriptions, `gpforum help migrate` prints the command's real usage text, and
`gpforum migrate --plan` runs it. `Mojolicious::Command::Author` is dropped
from the namespaces: an operator front door should not offer to upload the
application to CPAN. `daemon`, `prefork`, `psgi`, `cgi`, `get`, `routes`,
`eval` and `version` stay, because those are things an operator does use.

The adapters are adapters, not reimplementations — the work stays in
`GPForum::Command::*`, and `usage_text` is exposed publicly so the front door
shows the same text `--help` prints rather than a second copy that drifts. The
existing `bin/gpforum-*` entrypoints and their `script/` wrappers are
untouched, so nothing that scripted against them breaks.

`t/184` holds the contract: every command has an adapter, every adapter has a
description and a usage, the project namespace comes first, and the author
namespace is absent.

Writing this caught two lone-`$` signatures — `sub usage_text ($)` and
`sub program ($)` — through the prototype guard added in 4.1. A one-element
signature containing only a sigil is the one shape Perl itself cannot
distinguish from a prototype, so the guard is right to refuse it and the
invocants are named.

**6.2 Make `--help` succeed. — DONE.** It was a fatal error on eight of the
24 entrypoints: `croak _usage()` died, so the operator got the usage text with
` at bin/... line 17.` glued to the end and exit status **255**. Asking a
program how to use it is not an error, and 255 is what Perl reports for an
uncaught exception, not a status anyone can branch on.

All 24 now exit **0** on `--help`, print to stdout, and leak no `at FILE line
N`. Five also named the wrong program — `bin/gpforum-bench-hypnotoad --help`
answered `Usage: script/bench-hypnotoad`, and `gpforum-seed-benchmark` claimed
to be `script/seed-performance-data`. Both entrypoints exist (`script/` is a
shell wrapper that `exec`s the `bin/` one), so the name is taken from `$0`
rather than hardcoded: whichever was typed, the answer is truthful and
runnable.

**6.3 Publish an exit-code contract. — DONE for the codes; `Getopt::Long`
deliberately not adopted.** `GPForum::Command::Usage` names the contract —
**0** success, **1** failure, **2** usage error — and provides `help`, `error`,
`trimmed`, `wants_help`, `is_usage` and `program`. Sixteen commands route
through it. A usage croak becomes exit 2 with the text on stderr; anything
that is *not* a usage message is rethrown, so a real failure is never
relabelled as misuse.

`Getopt::Long` was not adopted. The hand-rolled parsers are already covered by
tests that assert their exact behaviour, and swapping the parser under them
would have changed what those tests mean without changing what an operator
sees. The operator-visible contract — help succeeds, misuse exits 2, the text
is clean — is what 6.3 was for, and it is now met. This is recorded as a
deliberate deviation rather than a completed sub-item.

**6.4 Add `make help`. — DONE.** Every target carries a `## ` description and
`make help` lists them. Fixing this surfaced a second defect: `make check` ran
`script/perlcritic --severity 5` while the profile declares `severity = brutal`
and the baseline was recorded at that level, so the gate compared a severity-5
run against a severity-1 baseline. It could not catch any new violation below
severity 5 and reported most of the baseline as "not observed" on every run.
The override is gone.

**6.5 Close the CLI/console asymmetry. — PARTLY DONE: dead-letter replay.**
The CLI can dispatch the outbox, run scheduled jobs and maintain partitions.
The admin console — 8 templates against 106 routes — can do none of it.

The audit's "no outbox or dead-letter inspection" was half wrong: `/admin/jobs`
already listed both. What neither surface could do was the other half of ADR
0056's requirement, *replay*: the runbook told the operator to re-emit the
work "from a canonical write", which for a failed notification means nothing
an operator can do. Replay now exists on both sides, over one service
(`Service::Outbox::DeadLetterReplay`): a Replay button per dead letter on
`/admin/jobs`, and `script/dead-letter-replay --list | --id ID` on the host.
It keeps the runbook's two rules — a cancelled message is never revived and
`dead_letters` stays append-only — by enqueueing a **new** message for the
same envelope under the key `dead-letter-replay:<id>`, and it records the
replay in the audit log with its actor, or `via: cli`. The audit row, not the
message, is what makes a dead letter replay once: retention purges a
delivered message after seven days and keeps the dead letter for thirty.
Built from the dead letter's own copy of the envelope, the replay works for
all thirty. `t/integration/postgres-dead-letter-replay.t` drives it from a
real dispatcher failure to a real redelivery.

An adversarial review of the change before it was committed confirmed six
defects, each now pinned by a test that failed first. The first version keyed
"replayed once" on the replay message, which retention forgets on day eight.
The uuid guard's `[[:xdigit:]]` also matched fullwidth digits, which
PostgreSQL rejects. The runbook claimed every handler is idempotent per
event; identity mail is not. And the one that is not the replay's alone:
`Admin::Workflow` caught a store's exception *inside* the command's
transaction, which then committed whatever the store had written before
failing — here a replay message without its audit row — and stored "failed"
as the command id's answer for good. The exception now reaches the
transaction and rolls it back.

The sweep that followed found the same shape in **all eight** workflows that
run under a command id -- Privacy, Identity, Attachment, Notification, Forum
posting and reads, Community, Moderation -- 37 call paths, 19 of them rated
high confidence by the analysis. Each catches its store's exception and
returns "failed" from inside `CommandIdempotency->run`'s transaction. The fix
is where the defect is common: `CommandIdempotency` no longer commits a failed
result. It abandons the transaction, so nothing written before the failure
survives and no answer is stored, and hands the failure back uncommitted
(`rolled_back`), so every workflow still answers "failed" and a retry with the
same command id runs again. `t/integration/postgres-command-failure.t` fails
without it on both shapes -- a caught Perl exception after a write, and a
database error inside a savepoint -- and on the retry. Of its two side
findings, the export bundle's one-bind-per-post read -- which libpq refuses
past 65,535 parameters, failing a long-time member's export outright -- now
reads post bodies in batches of 10,000; mention recording degrading silently
is by design and stays.

Three defects outside the replay surfaced on the way. The query statistics
object inherited DBIx::Class's printer, so every nested transaction in
production wrote `SAVEPOINT savepoint_0` and its release to STDERR.
`t/153` stubbed the identity store but not the sign-in audit, which reached
for the configured database — a developer's own at `127.0.0.1:5432` — and
wrote to it when it was up. And the new command's misuse test found that an
unknown option died with 255 instead of the usage and 2.

**Search reindex and cache purge — DONE 2026-09-26.** `/admin/jobs` gained a
maintenance section: whether search is behind (the outbox messages not yet
delivered, and since when) and how the last console rebuild went, with a
button to rebuild the index and one to purge the public page cache, each
under a command id and audited. A rebuild that runs minutes cannot live in
a web request, and Minion is optional, so it runs where every installation
already runs work: through the outbox, one batch of 500 per message, each
step recording the next once (`Search::RebuildRun`), closed by an event with
the run's totals. `t/integration/postgres-search-rebuild-run.t` drains a run
through the real dispatcher, transport and handler, from an emptied index
with an orphan to a complete one.

The adversarial review of the shell rebuild, run alongside, confirmed that
a rebuild racing the live search handler could write an older document over
a newer one — a hidden post searchable again — now prevented by a lock per
document; that `--entity thread` left a dead thread's posts searchable; and
that the prune decided from one snapshot, so a post restored meanwhile could
be dropped: candidates are now checked again, each under its lock. It also
found that `bin/gpforum` exited 0 on misuse for every command (Mojolicious
ignores a command's return value), fixed for all 25 adapters.

**Still open in 6.5:** no settings surface, no SMTP test-send, no rate-limit
tuning, no bans, no plugin management, no import/export UI.

**6.6 Fix the admin console defects that mislead the operator. — DONE.**

*The dashboard counters were fiction.* The template printed
`scalar @{ $summary->{async}{dead_letters} }` over a list the reader had
already truncated to `$DASHBOARD_LIMIT`, which is **10**. Queue depth and the
dead-letter total therefore read the same for eleven rows and for fifty
thousand — and that is the one number an operator reads to judge whether the
system is healthy. `ConsoleReader` now returns `dead_letter_total` and
`outbox_message_total` from real `count` queries, and the dashboard prints
those.

*Two moderation actions shared one command id.* A thread report renders a
hide form and a lock form **at the same time**, and both carried
`$report->{command_id}`. `CommandIdempotency::_command_key` returns the
command id *alone* — no action, no route — so the second submission found the
first command's row and replayed its stored response without running the lock.
Reproduced directly against the service: two different actions submitted under
one id, and only `thread.hide` executed. The moderator saw success and the
thread stayed unlocked. The lock form now carries its own `lock_command_id`.

The equivalent forms in `actions.html.ep` also share an id, and that one is
**not** a defect: they are mutually exclusive on `target_type`/`action_type`,
so at most one renders per row. Recorded because it looks identical at a
glance.

*The audit trail recorded the reporter's words as the moderator's.* Four
reason fields were pre-filled with `value="<%= $report->{reason} %>"` —
attacker-controlled text — and submitted verbatim as the staff actor's audited
justification. The pre-fill is gone and the field is labelled
`moderation.staff_reason`, "Your reason (recorded in the audit log)". The
reporter's claim is still shown, above, where it belongs.

`t/185` pins all three, and carries the shared-id reproduction as a negative
control so the assertion cannot pass vacuously.

*Destructive staff actions looked like any other button.* "Suspend user" was
pixel-identical to "Filter", and a single click ran it. The four actions that
cannot be taken back by the person who took them — revoking a role binding,
suspending a user, approving an erasure and running an erasure job — now sit
in a danger band that states the consequence, with a red button the form will
not submit until the operator ticks "I understand what this does". The
controllers refuse the write with 400 unless the request carries `confirm=1`,
so the check does not depend on the browser
(`GPForum::Web::DangerConfirmation`). The danger
colours are contrast-checked in both themes by `t/188`.

*The audit viewer could not answer an investigation.* ADR 0079 requires
filtering by actor, action, time and correlation id, and paging past the first
screen; the viewer had a target filter and the newest 50 rows. It now filters
by all six fields and a UTC date window, and pages with a keyset cursor on
`(created_at, audit_id)` — stable across rows that share a timestamp, which
`OFFSET` is not on a table that grows while it is read. A correlation id links
to every entry of the same request. Invalid input is a 400 with the field
marked, and the query never runs: before this, a target id that was not a
UUID reached PostgreSQL and came back as a 500.
`t/integration/postgres-audit-viewer.t` pins each filter, the paging and the
index each filter uses on the partitioned table.

**6.7 Document `bin/gpforum-partition-maintenance`. — DONE.** It was an
orphan: zero mentions in `docs/`, the README, the Makefile or `deploy/`, for a
command that takes `ACCESS EXCLUSIVE` locks on `audit_log` — which blocks every
auditable write, because the event recorder reads the hash-chain tip on each
one. `docs/ops/partition-maintenance.md` covers the cadence, the lock
behaviour, the maintenance-window requirement, what `default_partition_overlap`
means and why `bin/gpforum-scheduled-jobs` is not a substitute. Linked from
`docs/README.md` and reachable as `make partition-maintenance`.

## Phase 7 — Frontend, accessibility and aesthetics

Judged by driving the running application, not by reading the templates.

**7.1 Meet the contrast target the README claims. — DONE, and there was a
fourth failure the audit missed.** Measured rather than eyeballed:

| | Before | After | Needs |
| --- | --- | --- | --- |
| light border on surface | 1.57:1 | **3.37:1** | 3:1 |
| light border on alternate surface | 1.40:1 | **3.00:1** | 3:1 |
| dark border on surface | 3.30:1 | **3.58:1** | 3:1 |
| dark border on **alternate** surface | 2.78:1 | **3.01:1** | 3:1 |
| text inside `mark`, dark theme | 1.28:1 | **4.51:1** | 4.5:1 |

The audit reported one number, 1.45:1, for what is two surfaces with different
ratios, and it missed the dark border against the alternate surface entirely —
that one passed against the main surface and failed against the other, which is
exactly the case an eye does not catch.

`mark` was a hardcoded light-theme hex with no dark variant, so the dark
foreground landed on a light highlight at **1.28:1** — unreadable. It is a
token now, `--color-mark`, with a value per theme.

The replacements keep the hue and saturation of the originals and move only
lightness, so the palette still looks like itself.

`t/188` computes the ratios from the stylesheet with the WCAG relative-
luminance formula and asserts the two thresholds the README's "WCAG 2.2 AA"
claim implies: 3:1 for a component boundary (1.4.11) and 4.5:1 for text
(1.4.3). Seven of its ten assertions fail against the previous palette, and it
names the offending ratio in the failure message, so the next colour change is
checked rather than hoped about.

**7.2 Restore the login affordance on protected pages. — DONE.** `Web::Responder::error`
splices the payload and then passes `status => $input->{status}` after it, so the
HTTP 401 overwrites the payload's semantic `status => 'unauthorized'`. The
template's `(stash('status') || q{}) eq 'unauthorized'` branch is therefore never
taken and the login and register links never render. Visiting `/admin`
unauthenticated yields a dead end whose only link is "back to categories". The
translation keys `forum.login_to_continue` and `forum.create_account` exist in
both locales and are unreachable. No test asserts the link.

**7.3 Translate the error pages. — DONE for the error page (see 7.2).** `Web::ErrorPayload` returns hardcoded English
`title` and `error` strings that never pass through `t()`, so on an
Italian-locale site `/admin` renders "Authentication required" as the heading and
the raw internal code "authentication required" as the body — the same message
twice, in the wrong language, one of them a leaked internal token.

**7.2 and 7.3, as done.** The audit was exact about 7.2, and the cause is
structural rather than a typo: `status` is Mojolicious's reserved stash key for
the HTTP code, so the payload's semantic status could never reach a template
under that name. `Web::Responder::error` now hands the page an `error_page`
built by `Web::ErrorPayload->page`: a kind (`unauthorized`, `csrf`,
`not_found`, ...), a localized title and message for it, and the payload's
error as *detail* only when it is specific to the request ("already replayed
as outbox ...") rather than one of the generic internal strings. A stale form
is its own kind, "Form expired", instead of a permission failure reading
"Bad CSRF token". The JSON payloads keep their stable English strings for API
clients. The existing test for the login links passed vacuously -- the
header's own `/login` link satisfied its unscoped selector -- and the tests
now look inside the error section. Still English: validation field messages,
which come from the services, and the plain-text answers of the identity
endpoints (`Web::IdentityAccess`).

**7.4 Ship the typeface or stop declaring it. — DONE: stopped declaring it.** `--font-ui-latin: Inter, …` with
no `@font-face` rule and no `assets/fonts/` directory: the product renders in
whatever fallback the visitor happens to have.

The UI now names the platform's own face -- `system-ui, -apple-system,
"Segoe UI", Roboto, "Noto Sans", ...` -- rather than shipping Inter: native
text is crisp at every size, costs no request and no licence file, and the
declared design is now the rendered one. `t/188` fails if the stylesheet
names a family that is neither a system font nor declared by an
`@font-face`. The legacy `site.css` follows. Residual: the logo SVGs set
their wordmark as live text in Inter; it should be outlined to paths from the
original font, which is a design task, not a code one.

**7.5 Fix the header. — DONE, verified in a browser at 375, 800 and 1280px.** On every page the primary nav, the identity nav and two
separate POST forms — each with its own "Applica" button — are flex siblings that
visibly collide at 800px. On a 375px phone the header alone is taller than the
viewport, so the first screen is nothing but navigation; there is no disclosure
pattern.

The header now holds three things -- brand, primary navigation, identity --
in a grid with named areas. The language and theme forms moved to a
"Preferences" group in the footer, where both settings-like controls
conventionally live; the password-reset link left the header for the login
page that already carries it; and the "Signed in as 018f1000-..." label is
gone, since an internal id tells a member nothing (Settings stands for the
account). Below 1100px -- the width where a signed-in member's seven links
stop fitting on one line with the brand and identity -- the header is two
rows: brand and identity, then the navigation as one line that scrolls
sideways, with every link kept whole. Measured on a 375px phone: the header
went from about 630px of the 812px screen to 110px, with no horizontal page
scroll. No JavaScript: the disclosure pattern the audit suggested was not
needed once the header carried only navigation. `t/67` pins the structure and
the narrow-screen rules.

**7.6 Fix the page-level defects visible on a two-minute walkthrough. — DONE.** The
search page prints its description twice, once as the page subtitle and once as
the form's `aria-describedby` target. Thread pages show the breadcrumb
"Home / Categorie" with no category and no thread. `.ui-meta` applies
`text-transform: uppercase` to usernames, so `@perf_user_1` displays as
`@PERF_USER_1` — identity casing destroyed, and a known screen-reader hazard.

All three verified and fixed. The search help is stated once, as the page
description the form's `aria-describedby` names (`page_header` gained a
`description_id`). The breadcrumb ends at the page: "Home › Categories ›
General" on a category, and "Home › Categories › General › Welcome" on a
thread, where the category's title comes from a primary-key join in the
statement that already reads the thread -- no extra query; the "back to"
links the breadcrumb now makes redundant are gone. `.ui-meta` no longer
uppercases, so usernames keep their case. The live tier caught the first
version reading the new column from rows of readers that do not select it;
`ViewModel::Base->loaded_column` reads a join-only column as undef there.

**7.7 Add an asset pipeline.** No fingerprinting, no minification, no cache
policy. `assets/css/site.css` and `assets/js/site.js` are a second, divergent
design system used only by the standalone `index.html`.

## Phase 8 — Caching and performance

Every finding in this dimension survived verification; none was refuted.

**8.1 Invalidate L1 across workers. — DONE.** The cache-invalidation handler ran
in one Hypnotoad worker and `TieredCache::get` short-circuits on L1, so the
other workers kept serving stale HTML for the full TTL after an edit, a delete
or a moderation action. Reproduced with two processes: the invalidator's own
`get` returned undef while its sibling still returned `<p>secret post</p>`.

`GPForum::Service::Operations::CacheInvalidationBus` closes it with PostgreSQL's
own pub/sub rather than new infrastructure. `TieredCache` publishes every
invalidation on `gpforum_cache_invalidation` and absorbs its siblings' before
trusting an L1 hit, so correctness is intrinsic to the cache rather than
something a caller must remember.

Three properties of LISTEN/NOTIFY make this the right mechanism rather than a
workaround. `pg_notify` is transactional — PostgreSQL holds the message until
the sending transaction commits and discards it on rollback — so a peer never
invalidates for a write that did not land. `pg_notifies` reads the libpq buffer,
so draining costs no round trip. And the notification carries the sending
backend's PID, so a worker recognises and skips its own.

`LocalCache` gained the `lookup` contract `SharedCache` already exposed, so the
two tiers are interchangeable instead of `TieredCache` hard-coding which class
may sit underneath.

**8.2 Normalise the public HTML cache key. — DONE, and it was a correctness
bug too.** The key was the raw `path_query`, so every distinct query string
minted an entry: junk parameters evicted every real one. Verifying it found
worse: the key named neither the visitor's language nor theme, so an English
visitor was served the Italian page an earlier visitor had cached. The key is
now the page, the locale, the theme, the path and the effective page size;
`Vary` names `Accept-Language`. A page past the first (with a cursor) is not
cached, and a hit is served before the page's queries run -- it used to spare
only the template. Found on the way: `?after=anything` reached PostgreSQL as a
timestamp and failed the request; a cursor is now a position or timestamp and
a uuid, or the first page. `t/integration/postgres-public-cache.t` pins each
on PostgreSQL, including a hit costing no query. The byte bound is still
open.

**8.3 Fix LocalCache eviction. — DONE for the cliff; the other two claims
were each half right.**

*The cliff was real and worse than reported.* `_evict_oldest` scanned every
key to find the least recently used one, so a write to a full cache was O(n).
Re-measured here with 2,000 entries: **0.005 ms** while filling, **4.375 ms**
once full — a **960×** cliff, against the audit's 510× at the default 512.
It appears only under the load the cache exists to serve, which is why nothing
noticed.

Eviction is now an exact LRU with a recency list threaded through the entries
themselves — each entry carries the key before and after it — so moving one to
the most-recent end and dropping the least-recent one are a fixed number of
hash writes. Same measurement after: 0.0079 ms filling, **0.0115 ms** full,
**1.5×**. And it evicts the right entry: after reading `a`, inserting into a
full cache drops `b`, the true least-recently-used, not `a`. `t/189` pins the
bound at 20× — the old code fails it at 408× — and pins the ordering, the
entry bound, key rewrites and `clear` resetting the list.

*`purge_expired` is reachable one level up from where the audit looked, and
dead one level above that.* `TieredCache::purge_expired` calls it; nothing
calls `TieredCache::purge_expired`. The effect the audit described is correct.
It was **not** wired into `bin/gpforum-scheduled-jobs`, deliberately:
`LocalCache` is per-process, so a oneshot job would purge its *own* empty
cache and report success — the same shape as the config files nothing read and
the antivirus MUST nothing met. Expiry is already lazy on lookup, so a stale
entry is never served; what an unlooked-up expired entry costs is a slot until
LRU pressure reclaims it. The honest in-process fix is a recurring
`Mojo::IOLoop` timer inside the web worker, and that is still open.

*Bounded by entry count, never by bytes* — still true, still open.

**8.4 Render post bodies once.** Thread pages re-render every post body from
Markdown on every request and discard the stored `body_rendered_safe` column:
5.70 ms of pure CPU per page, measured.

**8.5 Make the query-plan gate EXPLAIN the real queries. — DONE.** The
"blocking" gate EXPLAINed hand-transcribed SQL the application never issued.
Checked against the code, the transcriptions were wrong in the ways the audit
said: the category index query filtered by a `space_id` the reader never
sends; the moderation queue read `status IN ('open', 'triaged')` where the
store reads `'open'`; readiness was modelled as `to_regclass` calls when it
reads a row from each table; the metrics count had a different predicate; no
endpoint had a signed-in shape; and the thread and search queries lacked their
joins and ranking.

Each endpoint now names the method in `lib/` that builds its statement —
nine readers and stores gained public `*_resultset` methods that their own
code paths call, so there is one source — and the gate EXPLAINs what DBIx::Class
renders from it. The outbox claim is raw SQL, so it is taken from
`ClaimQuery::sql` with a worker's binds. A thirteenth endpoint covers the
signed-in category page from 8.6. `t/54-query-plan-evidence.t` pins that the
EXPLAINed SQL is the reader's, byte for byte.

Running it exposed a second defect in the gate itself: every row threshold
reads a plan node's estimated output rows, so a sequential scan of 100,000
threads filtered down to 26 passed, and on the seeded CI database every table
is small anyway. With the category indexes dropped, the gate still reported
`status=ok`. It now takes a second plan of each statement with
`SET LOCAL enable_seqscan = off` and fails any sequential scan that survives
— no index can answer the query, at any table size. The same experiment now
fails with `no_usable_index:threads`. The check is a floor: it catches a query
no index can answer, not one answered by the wrong index.

`EXPLAIN ANALYZE` executes its statement and the claim is an `UPDATE`; both
plans are taken inside a transaction that is rolled back.

**Revisited 2026-09-26: the first plan's rule judged the dataset, not the
query.** On the medium dataset the gate failed five endpoints — the four
"pre-existing violations" of 2.8 and search — on plans that were right: a
sequential scan of 120 threads or 1,800 post bodies is cheaper than an index,
and the rule failed any scan returning over 100 rows whatever the table's
size. A sequential scan now fails only on a table above 10,000 live rows;
below it the gate records `seq_scan_small_table`. A relevance-ordered
endpoint (search, autocomplete) must score every match, so a scan returning
at least half of a large table is recorded as `seq_scan_most_rows` — declared
per endpoint, because a latest-first page that reads a whole table to sort it
is exactly a missing index. A nested loop over a single outer row (the one
space a search joins) is no longer "explosive". Measured on 20,000 threads and
60,000 posts: with the indexes, every endpoint passes; with the three thread
indexes dropped, home and both category pages fail (`seq_scan:threads`, and
`no_usable_index:threads` for the signed-in page); on the medium dataset
every endpoint passes with its warnings.

The same run measured search's worst case: the seeded documents all hold the
word the gate searches for, and ranking 20,000 matches takes 100 ms. A word
most documents hold has to be scored everywhere; that cost grows with the
forum, and is tracked as 8.10.

**8.6 Make the partial covering indexes usable by logged-in traffic. — DONE
where it was true.** The viewer predicate `(deleted_at IS NULL OR
author_user_id = ?)` cannot satisfy a `WHERE deleted_at IS NULL` partial index.
Measured on PostgreSQL 18 with sequential scans disabled, that mattered for one
of the two readers that use it, and a third reader had the same kind of defect.

* **Signed-in category pages were a sequential scan** — `Disabled: true`,
  because every index leading with `category_id` is partial on
  `deleted_at IS NULL`. `ThreadReader` now reads the two halves inside one
  statement: the visible threads from the covering category index and the
  viewer's own deleted threads from a new deleted-only partial index, each in
  page order and cut at the page size, with the page taken from their
  `UNION ALL` by key. Both halves are index-only scans. On 100,000 threads in
  one category a signed-in page fell from 39.33 ms to 0.29 ms, same rows.
* **Signed-in thread pages were not.** The unique `(thread_id, position)` key
  serves the same OR in page order with a filter, so `PostReader` is left as
  it is.
* **The profile's thread list** asked for `moderation_state IN ('visible',
  'locked')` from an index built for `= 'visible'`, and walked the site-wide
  activity index filtering by author. Migration 041 rebuilds the index with
  the predicate the query states.

`t/integration/postgres-viewer-plan.t` asserts the plans and the behaviour — the
author sees their deleted thread, another reader and an anonymous one do not —
and fails in four places without migration 041. The readers now expose the
resultsets they execute (`category_threads_resultset`,
`public_threads_resultset`), the seam 8.5 needs. The unit double learned
`IS NOT NULL` and subqueries, so the unit test checks who sees which thread
instead of pinning the shape of the query.

**8.7 Bound feed fan-out. — DONE.** `subscribers_for` materialised every
subscriber as a DBIC row with no `LIMIT`, then ran two queries per recipient
inside a single transaction. A popular thread was an unbounded serialised
write.

The projector now writes every recipient in one statement:
`INSERT ... SELECT FROM unnest(?::uuid[]) ON CONFLICT DO UPDATE ... WHERE
... IS DISTINCT FROM`. The ids travel as one array, so no bind limit applies;
a row already holding the item unchanged is not rewritten, so a retried event
writes nothing; the conflict clause replaces the per-row race handling.
`subscribers_for` reads two columns instead of whole rows. On PostgreSQL,
5,000 subscribers took 10,000 statements before and at most five now
(`t/integration/postgres-feed-projection.t`, confirmed against the old
code); the unit tests that pinned the per-row internals are gone with them.

**8.8 Make the benchmarks mean something.** Every benchmark is a single-client
serial in-process loop, thresholds are 300–600x looser than the measured
values, the baseline-regression code is dead, and `performance.yml` never runs
on a pull request.

**8.9 Let the search query use its indexes. — DONE.** `search_documents` has
a GIN index on `search_vector` and a trigram index on `title_normalized`, and
the search query could use neither. `EXPLAIN` with sequential scans disabled
still chose one — `Seq Scan on search_documents`, `Disabled: true`, the
planner's way of saying there was no alternative. Three rules combined:

* The full-text arm was `search_vector @@ websearch_to_tsquery(me.language, ?)`.
  An index qual's operand may not reference a column of the indexed table, and
  this one read `me.language` from every row.
* The fuzzy arm was `similarity(title_normalized, lower(?)) >= ?`. A function
  call is not an operator, and the trigram index serves only the `%`
  operator.
* The two arms are `OR`ed, and a `BitmapOr` needs every arm indexable. One bad
  arm was enough to condemn both.

The query now binds the text-search configuration the documents are built
with, and uses `%` with the threshold set per connection
(`pg_trgm.similarity_threshold = 0.18`, the value the bind used to carry). The
plan is a `BitmapOr` over both indexes. On 100,000 documents a query with no
match fell from 128.5 ms to 14.3 ms and a misspelling from 145.6 ms to 55.4 ms;
common words gain less, because they match a large share of the table and the
ranking dominates. Sixteen searches returned the same results before and
after.

`t/integration/postgres-search-plan.t` asserts the plan, with sequential scans
disabled, for an anonymous reader and a member, and was confirmed to fail on
the old query. It EXPLAINs the resultset the application executes, which
`Searcher::search_resultset` now exposes — the approach 8.5 needs for the rest
of the gate.

**8.10 Bound the cost of a word most documents hold. — OPEN.** Relevance
order scores every match before the first page is known. When the query word
is in most documents, that is the whole table: 100 ms on 20,000 documents on
the development laptop, linear in the forum's size, and the `simple` text
configuration keeps stop words, so "the" is such a word. Options, in order of
cost: rank only the newest N matches (a candidate cap, with the page saying
so), drop stop words from the configuration the documents are built with
(needs a reindex, which `bin/gpforum-search-rebuild` now provides), or keep a
per-word document frequency and refuse to rank words above a threshold. The
query-plan gate records the case as `seq_scan_most_rows` rather than failing
it.

## Phase 9 — i18n and content

**9.1 Connect the locale formatting layer. — DONE, and it was broken in three
ways, which is what being unused buys you.**

*It could not read the application's own timestamps.* `format_date` and friends
took an epoch, while every timestamp here is an ISO-8601 string — `Clock`
emits `2026-05-23T12:00:00Z` and DBD::Pg renders `timestamptz` as
`2026-05-23 12:00:00+00`. Passing a real one numified it to its leading year:
**every date on the site would have rendered as `1970-01-01`**, with a warning.
Both shapes are accepted now, offsets are converted rather than ignored, and a
value it cannot read returns undef so the caller can show its own placeholder
instead of a date the reader has no reason to distrust.

*It formatted in the server's timezone.* `localtime` over values the database
stores in UTC meant the same row read differently on two machines, with nothing
saying which zone was shown. It is `gmtime` now. Per-user timezones are 9.3;
until then UTC is the one answer that is the same everywhere and matches what
is stored.

*Thousands grouping inserted exactly one separator.* The loop anchored its
match to the end of the string, so once it had written a separator the
separator blocked every later match: `1234567` formatted as `1234,567`.
Now `1,234,567.50` in English and `1.234.567,50` in Italian.

Three template helpers — `dt`, `d` and `num` — connect it, each returning the
raw value unchanged when the formatter cannot parse it, so a surface never
loses information to a shape the formatter did not recognise. Twenty-eight
`<time>` elements across 17 templates now render localised text while keeping
the machine-readable ISO value in the `datetime` attribute, which is what that
attribute is for.

`t/187` pins all of it, and all twelve assertions fail against the previous
formatter.

**9.2 Move translations out of Perl.** 542 keys per locale live in a 1,225-line
Perl literal inside the largest module in the repository. English and Italian are
in exact parity and a `missing_keys` check guards that, which is genuinely good —
but adding a locale requires editing three Perl files and a SQL migration, and no
translator can work in this format. Move to gettext, and add a completeness gate
that can see untranslated *values*, not only missing keys.

**9.3 Add per-user timezones and relative time. — DONE for time zones;
relative time deliberately not.** Everything is formatted in the
server's local timezone.

By this pass the formatter had already moved to UTC, which fixed the
"differs by machine" half. Now a member picks an IANA zone in Settings
(`users.preferred_timezone`, migration 044), stored as NULL for "the forum's
default" -- `GPFORUM_DEFAULT_TIMEZONE`, UTC unless set, validated at boot --
so members who never chose follow the forum if it changes. The session carries
the zone from login; `dt`, `d` and the `ui_*` date helpers pass it to the
formatter, which converts with DateTime::TimeZone and names the zone on every
time it prints ("23/05/2026 14:00 CEST"), so a reader never has to guess which
zone a time is in. The date alone follows the zone across midnight. A stored
name the zone database later drops renders in the forum's default, never as an
error. The export carries the preference. `t/187`, `t/80`, `t/109` and
`t/integration/postgres-user-timezone.t` pin it; each fails without the change.

Relative time ("3 hours ago") is not done, on purpose: public pages are served
from the HTTP cache (8.1), and a relative phrase rendered into cached HTML is
wrong minutes later. It belongs in a small client-side enhancement over the
`<time datetime>` elements the templates already emit.

**9.4 Normalise and screen usernames. — DONE.** The format check was
`/\A [[:lower:]] [[:lower:][:digit:]_]+ \z/`. Under Unicode semantics that
POSIX class matches a lowercase letter in **any** script, so all of these
registered as valid, distinct accounts:

| Username | Codepoint |
| --- | --- |
| `аdmin` | Cyrillic small a, U+0430 |
| `admіn` | Cyrillic byelorussian-ukrainian i, U+0456 |
| `οwner` | Greek small omicron, U+03BF |
| `աdmin` | Armenian ayb, U+0561 |
| `ａdmin` | Fullwidth latin a, U+FF41 |

A username is an identifier — it appears in profile URLs, in mentions and in
moderation records — and a reader has no way to tell two of these apart. They
are now ASCII: `/\A [a-z] [a-z0-9_]+ \z/`. Perl::Critic asks for
`[[:lower:]]` here and that request is precisely the defect, so the
enumeration carries an annotation saying so.

Display names stay Unicode, because a person's name is not an identifier, but
they are NFC-normalised so `e` + U+0301 and U+00E9 are one string rather than
two spellings that compare unequal.

Existing rows are untouched: the check runs at registration, so any
non-ASCII username already stored keeps working. Screening those is an
operator decision, not a migration this should make silently.

**9.5 Fix the inline emphasis pass. — DONE. Documentation and preview still
open.** `_inline` is
`_breaks( _emphasis( _links( xml_escape($raw) ) ) )`, so emphasis ran over the
anchors `_links` had already emitted. A star in a URL was treated as markup:

    [docs](https://example.com/a*b*c)
    → <a href="https://example.com/a<em>b</em>c" ...>docs</a>

HTML tags written into an href, and the URL destroyed. Since `xml_escape` runs
before both passes, any angle bracket left in the string is a tag this
renderer produced, so emphasis is now applied to the text *between* tags and
never inside one. `[*styled*](url)` still emphasises, because the link text is
its own segment.

The cost, stated: an emphasis pair can no longer span a link, so
`*before [x](y) after*` does not emphasise. That is a fair trade against
corrupting the href. A bare URL in prose containing a star is still
emphasised — there is no autolinker, so that text is just text, and Markdown
behaves the same way.

Still open: the markup language has no documentation and no preview.

## Phase 10 — Documentation, governance and release

**10.1 Resolve the `prompt/` contradiction.** ADR 0087 is *Accepted* and declares
`prompt/` deleted and superseded by ADRs 0049–0101. The README, GOVERNANCE.md,
CONTRIBUTING.md, the pull-request template and a CI hygiene check all still treat
it as binding authority. One of the two is wrong, and the answer determines
whether a directory of LLM constitutions remains the project's stated source of
architectural truth.

**10.2 Make clone-to-green achievable. — DONE, with one correction.** `make
check` itself never needed a database — the integration tier skips without a
DSN — so the break was one step earlier: the README's quick start ran
`bin/gpforum-migrate --apply` without ever creating a database, naming the
`gpforum` role, or mentioning `GPFORUM_DATABASE_DSN`. It now creates both,
names the variables, points at the user-space cluster for hosts without a
system server, and says plainly that `make check` needs no database while the
integration tests want one they may create and drop databases on.

Fifty-six documented commands in 18 files called bare `carton exec`, which works
only where Carton landed on `PATH` — on MacPorts it usually does not, which is
why `script/gpforum-carton` exists. All of them now go through the wrapper.
`docs/ENTRYPOINTS.md` still said nine named wrappers called bare `carton`; none
has for some time, and the paragraph now says so.

**10.3 Make the CHANGELOG a changelog. — DONE for the structure; versions
wait on the first tag (10.5).** 73KB, one `## Unreleased` heading, no
versions, no dates, no Keep-a-Changelog categories, and the release workflow
does not consume it. The 351 entries now sit under Keep-a-Changelog sections,
with **Operator action required** first so an upgrading operator reads it
before anything else, and a **Development** section for the 96 entries that
only concern maintainers -- tests, gates, evidence archives, refactors with no
behaviour change -- which had been interleaved with what an operator needs.
The move was checked mechanically: the rebuilt file holds exactly the same
351 entries, byte for byte. The header states the version policy of ADR 0109:
a release section is named after its `v` tag and date.

**10.4 Make the ADR set navigable. — DONE for the index; ADR 0091 is worse
than reported.** `docs/adr/README.md` now carries an index of every ADR, with
title and status, generated by `script/adr-index` from the files themselves.
`script/adr-index --check` fails when the README is stale, and the suite runs
it, so a new ADR cannot land unindexed. Numbers 0103 and 0104 were never
assigned; the index says so rather than renumbering, since other documents
cite ADRs by number.

ADR 0091's Mandatory Interfaces were measured against `lib/`. The audit said
three of six do not exist. The state is: **one of six is complete**
(`SearchIndexer`); `SessionStore` has two of five methods,
`NotificationDispatcher` two of four, `PermissionEngine` one of four;
`EventStore` and `CommandHandler` do not exist as modules. That is recorded in
ADR 0106 rather than silently tolerated. Closing it is Architecture work and is
not done here.

**Closed 2026-09-26 by ADR 0110.** Mapping each of the 26 methods against
`lib/` showed the code mostly has the capability under another name and
shape, for reasons the contract did not foresee, and a facade with the
contract's name would have had no caller. ADR 0110 names the module and
method behind each, removes five methods that describe a design the system
does not use (`fetch_by_aggregate`, `fetch_after`, `emit_events`,
`policies_for`, `dispatch_pending`), and tracks three real gaps: an
operator's `explain` for permission denials, and entry points for search
`rebuild` and `observe_lag`. The one consolidation worth making was made:
`EventRecorder::event_recorded` replaces six copies of the replay lookup,
proven on PostgreSQL by replaying a category whose event was lost.

The search gaps followed: `bin/gpforum-search-rebuild` rebuilds the index
and `--status` reports its lag. The rebuild it wraps had never been run by
anything: it loaded every row into memory and returned them all, skipped
locked threads, never removed documents whose source was deleted or hidden,
and counted as "indexed" the posts of hidden threads it removed again on
every run. It now streams 500 ids at a time, prunes orphans, and a second
run reports nothing to do, on PostgreSQL.

And the command boundary: `CommandIdempotency::result_of` now answers a
workflow command in the shape every workflow returns — the replayed
response, the new result, or an `invalid`/`conflict` refusal. Seven
workflows had carried identical copies of that code (`_command_guard`,
`_guard_result`, `_guard_failure`); 318 lines became 78, and the shared
test double now inherits the real `result_of`, so workflow tests run the
code that shapes their answers.

ADR 0106 is also the first amendment in the set, and it exists because of this
pass: 4.4 renamed `PermissionEngine::can` to `permits`, and ADR 0091 says a
mandatory contract method MUST NOT be removed without an ADR. The rename was
right — `sub can` overrode `UNIVERSAL::can` and bit in practice — but it was
made without the record the contract requires. ADR 0106 is that record, and
ADR 0091 now points at it.

**10.5 Exercise release engineering once.** Zero git tags, zero versioned
CHANGELOG sections, 377 modules frozen at `$VERSION = '0.001'`, no SBOM, no
signed tags. Add `.gitattributes export-ignore` so the tarball ships the
application rather than `prompt/` and `t/`.

**10.6 State in an ADR that GPForum is an application, not a CPAN distribution,**
and what follows from that. **— DONE: ADR 0109.** There is no `Makefile.PL`,
`Build.PL`, `dist.ini` or `META.json`, and the absence is now a decision: the
release version is the git tag `release.yml` already derives it from, the
dependencies are the pinned Carton snapshot, and a module's `$VERSION` -- 413
of them at `0.001` -- is declared only because the critic policy and the POD
section require one, and must not be bumped per module or read to detect
features.

**10.7 Make the gates unable to lie. — DONE.** `script/perlcritic` passing
without running was the case found in practice (4.5a). The rest were audited
for the same shape — a gate that reports success when it examined nothing —
and four more had it:

| Gate | When it passed without checking | Now |
| --- | --- | --- |
| `script/perlcritic` | analyser not on `PATH` | fails: "the analyser did not run" |
| `make critic` | `--severity 5` against a severity-1 baseline | override removed |
| `script/perl-syntax-check` | no Perl files found (wrong directory) | exit 1, "nothing was checked" |
| `script/coverage` | no tests found; no threshold at all | exit 1; floor enforced (5.3) |
| `script/cpan-license-check` | manifests parsed to zero dependencies | exit 1, `no-dependencies-read` |
| `script/query-plan-check` | no DSN: database half skipped, still `status=ok` | CI passes `--require-db`, which fails with `db_evidence=missing-dsn` |
| `script/query-plan-check` | required index dropped by a later migration | checks the schema the migrations leave behind |

The last row was found by the read-only verification pass run alongside this
work, and it is the sharpest of them. The gate's index check regex-matched the
concatenated migration text, so an index created in one migration and dropped
in a later one still satisfied it on the strength of its `CREATE`. Migration
037 retired seven indexes as redundant and the gate went on requiring all seven.
Rebuilding the check to replay `CREATE INDEX` and `DROP INDEX` in migration
order found them at once: two were duplicates of indexes the list already
required (`idx_threads_category_activity_visible_locked`,
`idx_posts_visible_thread_position`), three were strict subsets of
`idx_outbox_messages_claim_ready`, and two had named successors
(`idx_outbox_messages_status_created`, `idx_reports_reporter_target_open_unique`).
The list now names 26 indexes that exist, and requiring a dropped one fails.

`script/perltidy-check`, `script/cpan-audit` and `script/architecture-check`
were already honest: a missing tool fails them. `query-plan-check` still skips
visibly on a laptop without a database, which is the right behaviour there;
what changed is that CI can no longer lose its DSN silently.

`t/190` pins every row it can exercise cheaply — the syntax gate from an empty
directory, `--require-db` without a DSN, the Makefile and CI invocations — and
seven of its assertions fail against the previous scripts.

**10.8 Split the dependency phases. — DONE, with one correction.** 27 of 158
locked distributions are development tooling that `carton install
--deployment` installs on every production host and ships in the release
vendor bundle; `Test::*` prerequisites are misfiled under `develop` instead of
`test`.

`Test::More`, `Test::Exception` and `Test::Fatal` now sit under `on test`,
and `make install-deps-production` (`script/bootstrap-deps --production`)
installs with `--without develop`, which leaves out Perl::Critic, Perl::Tidy,
Devel::Cover, Devel::NYTProf and their dependencies. `--production` refuses
`--update`, which would drop the tools from the shared lock. The correction:
moving the test modules does not keep them off production. Carton has no
`--without test` -- `Carton::Builder` carries a TODO for it -- and Menlo
installs a cpanfile's direct test requirements even under `--notest`, so the
test phase reaches every host. The three modules are small and pure Perl.
The vendor bundle still carries every locked distribution; an offline
production install from it leaves out develop the same way. `t/144` pins the
phases, the flag and the target. Not verified end to end here: Carton is not
installed on this host and CI is blocked by the Actions budget.

## Sequencing

Phases 1 and 3 are independent of each other and should run in parallel: the
first protects data, the second makes failure observable. Nothing in Phases 4
through 10 should start before 1.1 lands, because Phase 4's signature migration
touches every file that Phase 1 must rewrite. 1.2 is already done and was the
precondition for 1.1.

Phases 5.1 and 5.2 are a precondition for trusting any later refactor: the suite
currently cannot tell whether Phase 1 worked. The savepoint fix in 1.2 is the
worked example — the unit doubles have no storage layer, so nothing in `t/`
could observe either the defect or the fix.

Phase 4.5 (`max_mccabe`) should be decided before 4.1 (signatures), because the
complexity limit is what shaped the code that the signature migration will
rewrite.

Phase 8.1 was pulled forward and is done: a moderator hiding a post while eight
workers kept serving it was a governance failure, not a performance one.

## What this plan does not claim

The scores above are judgements, not measurements, and they are deliberately
harsh — the brief was to treat "good" as a finding.

Three claims from the source audit were corrected during verification and are
stated here only in their corrected form. `script/gpforum-evidence-archive-check`
failed loudly with exit 1 rather than passing silently. The missing `Inter`
typeface falls back to Avenir Next on macOS rather than to Arial. And the
`docs/` index is in fact organised by task rather than being the undifferentiated
pile the audit called it — the navigable-ADR finding in 10.4 stands, the wider
claim about `docs/` does not. Nine further findings were refuted outright during
verification and are absent entirely.

Every finding recorded above passed adversarial verification by a reviewer whose
instruction was to refute it. The ones quoted with measurements — the aborted
transaction, the savepoint depths, the Perl feature census, the broken CI
references, the `/dev/null` logging chain, the dead `etc/*.conf` profiles and the
rendered-page defects — were additionally reproduced first-hand rather than taken
from the audit record.
