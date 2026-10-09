# ADR 0126: SQL Lives in PostgreSQL Functions; Perl Binds Parameters and Reads Rows

## Status

Accepted (2026-10-09). This is the owner's decision, in his words:

> Dobbiamo spostare tutte e dico tutte le operazioni SQL su stored procedure
> PostGresQL, ottimizzatissime mi raccomando, e da PERL gestire solo ingresso
> parametri, e raccolta risultati.

Asked whether to measure and pilot first, the owner chose "Tutto subito":
the whole migration, area by area, with this ADR and benchmarks along the
way. He named the reason: "il nostro costo era dovuto a DBIX per la
generazione delle query". And the rule for the work: "chiaramente il tutto
va nelle migrations mi pare di capire! mi raccomando le query sono già
testate cerchiamo di non fare errori."

Phase 0 is this ADR, the inventory and baseline in
`docs/architecture/sql-functions-inventory.md`, and a pilot on two hot paths
(section 13). Phase 1 moves every area in the order of section 12.

It amends ADR 0005 (a store owns its transaction: the transaction is now the
function call the store makes), ADR 0110 (a command runs through
`CommandIdempotency::run`: the command log steps move into the command's
function) and ADR 0118 (the call layer maps two SQLSTATEs to `GPForum::X`
classes). It keeps ADR 0102, 0111, 0113, 0116 and 0119 as they are, inside
the functions. ADR 0114 (proposed) is unaffected in substance: whichever of
the two lands second is written against the other.

## Context

The inventory traced every statement the PostgreSQL integration suite sends
(44,000 statements, 268 operations) and measured the ten hottest operations
on the plan tests' seed, with a 3,008-post thread and a 1,500-thread
category. Per operation, on PostgreSQL 18 over loopback (a `SELECT 1` round
trip is 0.031 ms):

| Operation | Total ms | DBIx::Class ms (share) | DBI execute + fetch ms | Statements | Round trips |
| --- | --: | --: | --: | --: | --: |
| Reply (`POST /t/:id/replies`) | 14.9 | 7.6 (51%) | 4.6 | 23 | 39 |
| New thread (`POST /threads`) | 17.6 | 9.4 (54%) | 5.3 | 25 | 49 |
| Post edit (`POST /p/:id`) | 16.3 | 8.5 (52%) | 5.1 | 25 | 39 |
| Mark read (`POST /t/:id/read`) | 7.0 | 2.6 (37%) | 2.2 | 12 | 16 |
| Notifications inbox | 33.7 | 17.9 (53%) | 2.8 | 4 | 4 |
| Search | 10.5 | 5.4 (51%) | 1.2 | 5 | 7 |
| Home, signed in | 12.8 | 4.2 (33%) | 1.4 | 4 | 4 |
| Category threads, signed in | 13.2 | 3.7 (28%) | 1.5 | 4 | 4 |
| Category index, signed in | 6.2 | 1.5 (25%) | 0.7 | 3 | 3 |
| Thread page, signed in | 12.6 | 0.8 (6%) | 1.8 | 8 | 8 |

DBIx::Class here is SQL::Abstract building the statement, resultset
chaining and storage work, row inflation and column accessors, measured as
exclusive time per bucket and cross-checked with Devel::NYTProf. On every
write and on every page it has not already been removed from, it costs more
than PostgreSQL and the socket together: 1.2 to 1.8 times on the writes,
2.2 to 6.3 times on the reads. The thread page is the exception that proves the
point: `Infrastructure::PreparedQuery` already builds its two statements
once ("the building took seven times what PostgreSQL took"), and DBIx::Class
is 6% of it.

Three more findings shape the decision:

- **Round trips are mostly ceremony.** A reply's 39 round trips are 23
  statements, a `BEGIN` and a `COMMIT`, and seven savepoints with their
  releases: `Infrastructure::UniqueConflict` wraps each insert that may
  collide in a savepoint, two round trips each.
- **Today's statements are planned on every call.** The thread page's post
  statement plans in 0.165 ms and executes in 0.111 ms; PostgreSQL's `auto`
  plan cache mode keeps choosing a custom plan for it, so the planning is
  paid every time.
- **Two releases run side by side.** A deploy applies the migrations and
  then restarts Hypnotoad; the previous release serves meanwhile and its
  workers finish after the restart begins (ADR 0119). Whatever the previous
  release calls must keep working until it is gone.

The tests hold the current behaviour: the golden command and event tests
(`t/325`, `t/329`), the refusal agreement tests (`t/327`, `t/330`), the
concurrency races, the plan and budget gates. The unit tests stand on 135
double modules of DBIx::Class schemas, resultsets, rows and storages in
`t/lib`.

## Decision

### 1. Every statement the application sends is a call to a function in `api`

- A function is created by a numbered migration (052 onward) and is never
  edited after it ships: the runner's checksums refuse an edited migration,
  and a change is a new migration creating the next version (section 2).
- Schema `api` holds the functions and the row types they return, nothing
  else: no tables, no views. Migration 052 creates it and revokes it from
  `PUBLIC`. The tables stay in `public`.
- **Perl prepares the parameters and reads the results.** It validates and
  normalises input, mints ids (UUIDv7, as today), reads the clock, renders
  Markdown, hashes passwords and tokens, finds mentioned names, computes the
  request fingerprint, and maps result codes to words. Everything that
  reads or writes a table, takes a lock, branches on what the database
  holds, or records the command, the event, the outbox row and the audit
  row, is in the function.
- **The queries are transplanted, not redesigned.** For each operation the
  SQL DBIx::Class and the raw DBI code send today is captured on the seeded
  database (the tracer of the inventory, with bound values recorded) and
  copied into the body. Only what the boundary requires changes: parameters
  for bound values, `RETURNING` where Perl read a row back, the sequencing
  and branching Perl did between statements, written in PL/pgSQL, in the
  order the trace shows, so the lock order stays.
- **What is not a function:** the migration runner, which applies the SQL
  files; the connection's session settings (`on_connect_do`) and
  `LISTEN`/`UNLISTEN`, which are session state; PostgreSQL's administrative
  commands run by setup, provisioning and the drills (`CREATE ROLE`,
  `CREATE DATABASE`, `pg_dump`); and the test harness's fixtures. Everything
  else, cold paths included, moves.

### 2. Names and versions, for two releases running side by side

- **Names** are `api.<area>_<operation>_v<N>`: the area of the inventory
  (`forum`, `session`, `identity`, `moderation`, `admin`, `privacy`,
  `community`, `notification`, `attachment`, `search`, `outbox`, `ops`,
  `partition`) and the operation the caller asks for, verb first:
  `api.forum_create_reply_v1`, `api.forum_thread_page_posts_v1`,
  `api.session_validate_v1`. Steps that several functions share are
  `api.core_<step>_v<N>` (`api.core_record_event_v1`,
  `api.core_record_audit_v1`, `api.core_canonical_json_v1`); Perl never
  calls a `core_` function. Row types are `api.<area>_<shape>_v<N>`.
- **A shipped version never changes**: not its body, not its signature,
  not its result type. A change, a bug fix included, is `_v<N+1>`, created
  by a new migration with `CREATE FUNCTION`. Migrations from 052 on never
  write `CREATE OR REPLACE` for an `api` function: replacing the body under
  a name would change what the previous release's workers run in the middle
  of its requests.
- **One place in Perl names the versions a release calls** (the catalogue,
  section 8). A release moves to `_v<N+1>` by changing that line.
- **An old version is dropped by a contract migration in a later release**,
  once no process runs a release that calls it. Never in the release that
  stops calling it: `bin/gpforum-migrate --apply` runs every pending
  migration before the restart, so the previous release would lose its
  function while it still serves (the rule of ADR 0119, section 3).
- **The tables follow expand and contract.** A migration that changes a
  table keeps every version still called working: add first, switch the
  functions in a new version, remove a release later.
- A running worker holds server-side prepared calls. PostgreSQL refuses a
  changed result type for an existing function anyway, and a cached plan
  whose result type changed fails with `cached plan must not change result
  type`; a new name for every change means neither can happen.

### 3. Language per kind, measured

On the 3,008-post thread, 25 rows plus the look-ahead row, 1,000 to 3,000
calls each:

| The thread page's post statement | Median µs |
| --- | --: |
| Prepared statement, as `PreparedQuery` sends it today | 297 |
| `LANGUAGE sql`, inlined (no `SET` clause) | 369 |
| `LANGUAGE sql`, `SET search_path`, plan mode left at `auto` | 320 to 350 |
| `LANGUAGE plpgsql` `RETURN QUERY`, plan mode left at `auto` | 313 to 346 |
| `LANGUAGE sql`, `SET plan_cache_mode = force_generic_plan` | 177 |
| `LANGUAGE plpgsql`, one branch per shape, `force_generic_plan` | 167 |

A primary key lookup (the session) costs 34 µs prepared, 34 µs as an
inlined `LANGUAGE sql` call and 39 to 40 µs as a function with `SET`
clauses: the boundary's own cost is 5 to 6 µs a call. Ten lookups inside
one PL/pgSQL call take 60 µs, where ten round trips take 341 µs.

- **A read that is one statement** is `LANGUAGE sql STABLE`, with the `SET`
  clauses of section 4 and 7. It is not inlined (a `SET` clause prevents
  inlining), and need not be: called at the top of a statement, an inlined
  function is planned like today's statement, every time. PostgreSQL 18
  caches the plans of SQL functions, so a pinned generic plan applies.
- **A read with more than one shape or statement, and every write**, is
  `LANGUAGE plpgsql`: `STABLE` for a read, `VOLATILE` for a write.
- **`IMMUTABLE`** only for pure helpers (`api.core_canonical_json_v1`).
- **A list is `RETURNS TABLE`**, or `RETURNS SETOF` a named row type when
  several functions return the same shape. Perl selects `SELECT * FROM
  api.f(...)`, so the columns arrive as columns (a composite selected as one
  column arrives as text).
- **A page is one call per list it shows, not a document.** Measured for the
  thread page (head and 25 posts): two `RETURNS TABLE` calls 452 µs; one
  `jsonb` document 715 µs plus 59 µs to decode; one `json` document 568 µs
  plus 56 µs. A value that is a document already (an event payload, a
  viewer's grants) is returned as `json` or `jsonb` in its column; where a
  function builds a document only for output, `json` is cheaper than
  `jsonb`.
- **No dynamic SQL from parameters.** `EXECUTE` is used only for partition
  DDL, whose identifiers come from the catalogue and are quoted with
  `format('%I')`, never from a caller.

### 4. Plans: one statement per shape, and each function pins its plan mode

- **Every shape keeps its own statement.** `PreparedQuery` keeps one
  statement per shape (first page or after a cursor, member or anonymous);
  a function keeps the same statements, one `RETURN QUERY` per shape behind
  `IF` branches. Folding shapes into one statement with `p IS NULL OR ...`
  is forbidden: its generic plan cannot use the keyset bound. Measured on
  the 50,000-post thread at position 40,000: 6,920 to 7,023 µs with a
  generic plan, against 123 to 154 µs for one branch per shape. Under
  `auto` the folded statement happened to stay custom (345 µs), which is
  luck, not a plan.
- **Each function declares `SET plan_cache_mode`, never `auto`.** `auto`
  switches to a generic plan after five custom plans if their cost
  allows, so which plan a call runs depends on the values that reached that
  backend first, and two workers can run different plans for the same call.
  - `force_generic_plan` where the plan gate shows the generic plan is the
    custom plan on every fixture: primary key lookups, keyset lists on an
    index, writes by key. Measured, one branch per shape: 95 µs (8-post
    thread), 169 µs (3,008), 136 µs (50,008, first page), 123 µs (50,008,
    position 40,000), against 238 to 339 µs with custom plans. That is the
    0.165 ms of planning today's statement pays on every call.
  - `force_custom_plan` where the best plan depends on the values: search
    ranking, and any list the gate shows changing plan across the skewed
    fixtures.
- **Keyset bounds are transplanted as `Infrastructure::Keyset` writes
  them**: the bound on the sort column alone, which the index answers, and
  the lexicographic `OR`.
- **Partition pruning is kept by keeping the predicate.** Where a statement
  on `event_log`, `audit_log` or `notifications` names the partition key
  today, its function does too. Measured inside a function: a custom plan
  prunes when it is planned (one partition of four scanned), a generic plan
  prunes when the executor starts (`Subplans Removed: 3`). ADR 0116's
  lookups by id stay what they are: they have no key and probe every
  partition, by design.

### 5. Locks and transactions

- **A function runs in its caller's transaction.** A command is one call in
  autocommit, so the statement is its transaction: no `BEGIN` and `COMMIT`
  round trips, and nothing it did survives a failure. A read is one call
  and needs no transaction. During the transition a call made inside a
  DBIx::Class `txn_do` joins that transaction (section 8).
- **ADR 0111's order is the body's order.** A reply takes its thread row
  `FOR NO KEY UPDATE` first; an edit, a delete or a restore takes the
  thread row `FOR KEY SHARE`, then the post row `FOR UPDATE`; the counter
  row comes after them (ADR 0119); the audit chain's advisory lock comes
  last, as the audit is the last write. The workflow's checks before the
  lock and the store's checks under it both stay, in that order: the trace
  shows them, and the refusal agreement tests hold their words.
- **A savepoint becomes an exception block.** `UniqueConflict::attempt`'s
  savepoint and its recovery (look the row up, compare, reuse it or draw a
  new id) become `BEGIN ... EXCEPTION WHEN unique_violation THEN ... END`,
  which is a subtransaction exactly as the savepoint was, without its two
  round trips. The constraint is read with `GET STACKED DIAGNOSTICS`, and a
  partition's index name is mapped to its parent's constraint as
  `X::Conflict->on` does (ADR 0113, 0116), by one shared helper.
- **The command log moves into the command's function (ADR 0110).** In the
  order `CommandIdempotency::run` follows: look the idempotency key up and
  replay the stored response, or answer a conflict (another request hash)
  or in progress; insert the command row, recovering a taken command id as
  today; do the work; store the response, its hash, the status and
  `handled_at`. A refusal is recorded and returned. A failure raises, so
  the statement aborts and nothing is committed, and Perl answers the
  failed, rolled-back result it answers today. Perl passes the request
  hash; the function builds the response from the rows it wrote.
- **One canonical JSON, proven before use.** The command log's
  `response_hash` and the audit chain's `record_hash` are SHA-256 of
  `JSON::MaybeXS` canonical encoding, computed in Perl today; inside a
  function they are `sha256` of `api.core_canonical_json_v1`. No function
  uses it until a test shows it byte for byte equal to `JSON::MaybeXS`
  canonical output on the golden fixtures of `t/325` and `t/329` and on
  generated values: non-ASCII and control characters, numbers and numeric
  strings, booleans, nulls, empty and nested containers. Where Perl's
  encoding of a value depends on how the scalar was last used (a number
  that is sometimes a string), the differential test pins which one the
  stored rows hold.
- **Mentions and notifications stay in the reply's transaction**, each
  inside an exception block, so a failure there degrades the reply as it
  does today and does not abort it. `pg_notify` is sent at commit, as today.

### 6. Errors

- **A refusal is a result value, never an exception** (ADR 0118). A command
  function returns a status (`ok`, `invalid`, `not_found`, `forbidden`,
  `conflict`, and the replay and in-progress answers of the command log)
  and a refusal code (`thread_locked`, `post_deleted`, ...). The words stay
  in Perl, in the `GPForum::Domain` modules, which keep the code to words
  and status table; the differential tests compare status and words for
  every state the agreement tests enumerate.
- **A true error raises with a SQLSTATE.** A function's own contract
  violation (a required parameter missing) raises `22023`
  (`invalid_parameter_value`) naming the parameter; the call layer throws
  it as `GPForum::X::Argument`. A unique violation that escapes a function
  is a `GPForum::X::Conflict`, through `from_error`, as today. Every other
  error (lock and statement timeouts, deadlocks, a lost connection)
  propagates as DBI raises it, and `FailureType` classifies it as today.
- **A malformed id from a URL is not sent.** The call layer checks a uuid
  parameter's spelling before the call (`Id->is_uuid_spelling`), as
  `PreparedQuery` does: no call, no rows, no 500.

### 7. Security

- `SECURITY INVOKER`, the default, always. The application's role owns its
  database and runs the migrations, so it owns the functions; no function
  needs another role's rights.
- `SET search_path = pg_catalog, pg_temp` on every function, and every
  table, function and operator of `public` written schema-qualified in the
  body, so no session setting can redirect a name; `pg_temp` last, so a
  temporary table cannot shadow one.
- Each migration revokes `EXECUTE` on its functions from `PUBLIC`, and
  migration 052 sets the schema's default privileges to do the same. A
  read-only role (reporting, a standby's reader) is granted function by
  function when one exists.
- Parameters are typed (`uuid`, `bigint`, `integer`, `text`, `boolean`,
  `timestamptz`, arrays of these, `jsonb` for event payloads and audit
  metadata), never `anyelement`; the call layer binds them with their
  types.

### 8. How Perl calls them: one call layer, no ORM

- **`GPForum::Infrastructure::SqlFunction`** is, apart from the exceptions
  of section 1, the only code that sends SQL to the application's
  database. It takes a function's catalogue name
  and its parameters and returns plain rows: an array of hashes keyed by the
  function's column names, one hash, one value, or a decoded `json` value.
  The statement text is a constant per function, `SELECT * FROM
  api.<name>_v<N>($1, ...)`, prepared once per handle (`prepare_cached`)
  and executed with the binds. No SQL is generated per call; no row objects,
  no accessors.
- **The catalogue** is one Perl module listing every function the release
  calls: its version and its parameter types. A PostgreSQL test checks it
  against `pg_proc` on a migrated database: every listed function exists
  with those types, and every `api` function is listed, a `core_` helper,
  or a version a later release still drops.
- **Each call is counted** in the storage's query statistics, as
  `CountedQuery` and `PreparedQuery` report theirs, so the budgets see it.
- **The handle.** Until the last area moves, the layer runs on the
  DBIx::Class storage's handle (`dbh_do`), so a call and a statement not
  yet moved share one connection and one transaction. When the last area
  has moved, the layer owns the connection: the same DBI attributes and
  session settings, fork safety (`AutoInactiveDestroy` and a pid check, as
  the storage does for Hypnotoad), and one reconnect for a call outside a
  transaction.
- **DBIx::Class leaves area by area.** `GPForum::Schema` and its result
  classes stay while any runtime path or test uses them. The last wave
  removes them, `PreparedQuery`, `CountedQuery`, and DBIx::Class with
  SQL::Abstract from `cpanfile`.

### 9. The query budget and the plan gate

- **The budget counts client statements, and a call is one.** The target
  is one call per operation; a page is its request prologue and one call per
  list. The commit that moves a page lowers its budget in
  `t/integration/postgres-query-budget.t` and `QueryBudget`'s defaults to
  what it now sends; a budget is never raised to let a move through.
- **The plan gate explains what runs inside.** For each endpoint the test
  harness makes the call with `LOAD 'auto_explain'`,
  `auto_explain.log_min_duration = 0`, `log_nested_statements = on`,
  `log_analyze = on`, `log_format = json` and `client_min_messages = log`,
  and reads the nested plans from the notices. Measured: the nested plan of
  a `RETURN QUERY` reaches the client with its index node. `PlanRules`
  apply to each nested plan as they do to today's statements, after six
  calls, so the plan judged is the one the function's plan mode caches.
- `LOAD` needs a superuser unless `auto_explain` is preloaded. An operator's
  `query-plan-evidence` run that cannot load it reports the endpoint as
  unmeasured, a warning and never a pass.
- The deep-page fixtures of `t/integration/postgres-query-plan-depth.t`
  (3,000 posts, 1,500 threads) and the 50,000-post thread of section 4 run
  against the functions.

### 10. Tests

- **Every existing test passes unchanged** while an area moves; the old
  Perl path stays callable until the area's contract commit.
- **Every function gets a differential test** (`t/640` onward): the old
  Perl path and the function on the same fixtures, with ids and the clock
  scripted, compared on the result, the rows written in every table the
  trace shows written, the events and outbox rows, the audit rows and their
  chain, the command log row, and the refusals and errors.
- **PostgreSQL integration tests call the functions and the stores**; the
  concurrency races run unchanged against the new paths.
- **Unit tests use a double of the call layer**: it records the function
  and the parameters and returns rows the test gives it. An area's ORM
  doubles retire with its contract commit.
- **A migration test** holds sections 2, 4 and 7 for every `api` function in
  migrations 052 onward: `CREATE FUNCTION`, not `OR REPLACE`; `SET
  search_path` and `SET plan_cache_mode`; `REVOKE ... FROM PUBLIC`; a
  version suffix.
- Tests that reach into the old path's internals (the plan-depth test
  replaces `Keyset::after` and a reader's private query) hold the old path
  until its contract commit, which replaces each with the same check
  against a scratch function, in the same commit.
- PL/pgSQL has no coverage report here; the differential tests are its
  coverage, and an area does not close without one for every branch the
  trace shows.

### 11. Migration and rollback

- A function migration is transactional. The no-transaction mode, whose
  splitter refuses `$$` bodies (`t/209`), is for `CONCURRENTLY` indexes
  only. `CREATE FUNCTION` locks no table; the migrations still set
  `lock_timeout` as 049 to 051 do.
- A deploy migrates and then restarts: the new functions exist before the
  code that calls them runs, and the previous release ignores them.
- Rolling the code back is safe: the previous release calls its own
  versions, which are still there. A function is never removed by editing
  a migration; only a contract migration drops a version, a release later.
- Per area: the functions land with their differential tests; the Perl path
  switches to the call in the same commit; the contract commit removes the
  old path and its doubles once the area is whole.

### 12. Phase 1, in order of value

Sizes from the inventory: operations the suite drove, public subs it did
not drive, and the Perl in the modules that reach the database.

| Wave | Area | Operations (+ not driven) | Modules, lines | Why here |
| --: | --- | --- | --- | --- |
| 1 | Shared write steps; sessions and the request prologue | 6 (+4); 4 (+2) | 8, 1,653 | Command log, events and outbox, audit chain, canonical JSON, conflict recovery, under every write; session, viewer, rate limit and participation, under every request |
| 2 | Forum writes | 14 (+3) | 5, 1,915 | Reply, new thread, edits, deletes, restores, moves, read marks: 39 to 49 round trips and 7.6 to 9.4 ms of DBIx::Class each |
| 3 | Forum reads | 15 (+2) | 7, 1,412 | Thread page, category list, home, category index: 1.5 to 4.2 ms of DBIx::Class a page, and the generic plans |
| 4 | Notifications | 23 | 3, 1,196 | The heaviest page (17.9 ms of DBIx::Class), the badge count, read marks, fan-out |
| 5 | Search | 14 (+5) | 5, 1,890 | The search page (5.4 ms), autocomplete, the indexer |
| 6 | Community | 21 (+3) | 7, 1,585 | Feed, bookmarks, mentions, subscriptions, reputation, feed projection |
| 7 | Readiness and metrics | 14 (+14) | 15, 3,601 | `/health/ready` sends 13 statements per probe, `/metrics` 9 |
| 8 | Identity | 26 (+23) | 11, 2,289 | Login, registration, passwords, tokens, preferences, profiles |
| 9 | Outbox and workers | 14 (+22) | 18, 3,402 | Claims and leases, dead letters, idempotency keys, projections, realtime |
| 10 | Moderation; attachments | 30; 21 (+7) | 8, 2,548 | Console writes and the attachment lifecycle |
| 11 | Admin; privacy and portability | 31 (+12); 23 (+7) | 19, 4,978 | Console reads and writes, data rights |
| 12 | Partitions, query budgets and plans, commands | 12 (+16) | 10, 5,955 | Cold paths, then the contract: DBIx::Class out |

### 13. Phase 0's pilot

Two hot paths prove the ground before phase 1 fans out: the thread page's
reads (`api.forum_thread_page_head_v1` and `api.forum_thread_page_posts_v1`:
the hottest page, one branch per shape, generic plans) and the reply
(`api.forum_create_reply_v1` with the shared steps it needs: the hottest
multi-step write, its locks, savepoints, command log, event, outbox and
audit). The pilot lands the call layer, the catalogue and its test, the
migration test, the canonical JSON proof and the plan gate's nested
explain, and measures both paths against the baseline above.

## Consequences

- The Perl cost the owner named goes: the DBIx::Class share of each
  operation in the Context table (51 to 54% of each write, 25 to 53% of each
  page it was not already removed from). A reply drops from 39 round trips
  to its prologue and one call.
- PostgreSQL plans less: a pinned generic plan saves about 0.15 ms per
  keyset read against today's replanned statements.
- The rules of a write live in SQL; the words of a refusal stay in Perl.
  One rule has one home, but the home of the words and the home of the rule
  differ, and the differential tests are what keeps them together.
- Every change to a query is a migration and a version. Old versions live
  one release longer, and `api` grows by a contract migration's worth
  before each drop.
- The audit chain and the command log depend on one SQL canonical JSON,
  which must match Perl's byte for byte; the proof is a gate, not a review.
- The plan gate needs `auto_explain`, so a superuser, in the test harness.
- The 135 ORM double modules retire with their areas; unit tests that
  stood on them use the call layer's double.
- PL/pgSQL has no coverage tool here; the differential tests stand in.

## Alignment

- ADR 0005 and ADR 0110 (amended), ADR 0118 (extended), ADR 0102, ADR 0111,
  ADR 0113, ADR 0116, ADR 0119 (kept, inside the functions), ADR 0114
  (proposed; unaffected in substance).
- `docs/architecture/sql-functions-inventory.md`: the inventory, the method
  and the baseline.
- `lib/GPForum/Infrastructure/PreparedQuery.pm`,
  `lib/GPForum/Infrastructure/CountedQuery.pm`,
  `lib/GPForum/Infrastructure/UniqueConflict.pm`,
  `lib/GPForum/Infrastructure/EventRecorder.pm`,
  `lib/GPForum/Infrastructure/Keyset.pm`,
  `lib/GPForum/Service/Operations/CommandIdempotency.pm`,
  `lib/GPForum/Service/Operations/QueryBudget.pm`,
  `lib/GPForum/Command/QueryPlanEvidence.pm`,
  `lib/GPForum/Benchmark/PlanRules.pm`.
- `t/209-migration-indexes.t`, `t/325-forum-posting-golden.t`,
  `t/329-forum-thread-events-golden.t`,
  `t/327-forum-refusal-agreement.t`,
  `t/330-forum-thread-refusal-agreement.t`,
  `t/integration/postgres-query-budget.t`,
  `t/integration/postgres-query-plan-depth.t`,
  `t/integration/postgres-concurrency.t`.
