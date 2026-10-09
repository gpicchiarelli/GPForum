# SQL Functions Inventory

Every statement GPForum sends to PostgreSQL, by area and operation, and what
each costs today: the ground for ADR 0126, which moves all of them into
PostgreSQL functions. Taken on 2026-10-09 at `9eedee3`, on PostgreSQL 18.6.

The question this inventory answers for each operation is the one the owner
asked: how much Perl CPU goes into DBIx::Class (building SQL with
SQL::Abstract, chaining resultsets, inflating rows, calling accessors)
against the time PostgreSQL and the socket take. The answer, for the ten
hottest operations, is in [the baseline](#baseline-the-hottest-operations);
the rest of the document lists what a function call will replace.

## How it was taken

- **Statements, as sent.** A scratch tracer wrapped DBI's `execute`, `do`,
  `selectrow_*`, `selectall_*`, `selectcol_arrayref`, `begin_work`,
  `commit`, `rollback` and DBD::Pg's savepoint calls, and every public sub
  of the GPForum modules under `Service`, `Worker`, `Infrastructure`,
  `Command`, `Controller`, `Web`, `Migration` and `Benchmark`. It recorded
  each statement with the stack of GPForum calls that sent it. Run over the
  whole PostgreSQL integration suite (76 files, every one passing under the
  tracer), it saw 44,000 statements. An *operation* is the outermost
  service, worker or command call on the stack (an outbox handler's
  `handle` when one is), grouped per call: 268 operations.
- **What the suite does not drive.** A static scan lists the public subs
  that reach the database, directly or through their module's private subs:
  347 in 116 modules. 120 of them were never the outermost call; most ran
  inside another operation and are covered by its row (section
  [Not driven by the suite](#not-driven-by-the-suite)).
- **The hot requests, measured.** A scratch benchmark cloned the plan tests'
  seed (`GPForum::Test::PgDatabase`, `seed => 1`) and added what
  `t/integration/postgres-query-plan-depth.t` adds: 3,000 posts in the first
  seeded thread, this time with bodies so its page renders 25 full posts,
  and 1,500 threads in the first category. A member with 30 notifications
  signed in. Each operation ran through the application (`Test::Mojo`,
  in-process, the page caches emptied before each request), 15 warm-up
  requests, then 200 reads or 100 writes.
  - **Plain**: wall time and process CPU per request.
  - **Buckets**: the same requests with exclusive wall time charged to the
    innermost bucket on the stack: `dbi` (DBI execute, fetch, prepare,
    transaction and savepoint calls: PostgreSQL and the socket), `sqlgen`
    (`DBIx::Class::Storage::DBI::_gen_sql_bind`, which runs SQL::Abstract),
    `rs/storage` (the public resultset, row, schema and storage methods:
    `search`, `find`, `create`, `update`, `txn_do`, `dbh_do`, ...),
    `inflate` (`_construct_results`, `inflate_result`), `accessors`
    (`get_column`, `get_columns`, `get_inflated_column`), and `other`
    (everything else: Mojolicious, the views, GPForum's own Perl). The
    wrappers add 0.4 to 2.4 ms per request; the bucket totals are from the
    instrumented run.
  - **Cross-check**: Devel::NYTProf (subroutines only) over the inbox, the
    reply and the category list. It inflates Perl against XS, as it does,
    and still puts DBIx::Class and SQL::Abstract (Text::Balanced included,
    which SQL::Abstract calls) at 52%, 44% and 25% of the three, the bucket
    figures being 53%, 51% and 28%.
- **Round trips** are statements plus `BEGIN`, `COMMIT` and savepoint
  calls. A `SELECT 1` round trip on this host's loopback takes 0.031 ms.

The scratch tools are not part of the repository. Phase 1 takes each area's
SQL with the same method, recording the bound values too
(`$sth->{ParamValues}`), so the function bodies are the statements as sent.

## Baseline: the hottest operations

Milliseconds per request, signed in unless noted.

| Operation | Plain median | CPU | Instrumented total | DBIx::Class | of which sqlgen / rs+storage / inflate / accessors | DBI | Other | DBIx::Class ÷ DBI | Statements | Round trips |
| --- | --: | --: | --: | --: | --- | --: | --: | --: | --: | --: |
| Reply | 13.5 | 9.8 | 14.9 | **7.6 (51%)** | 2.51 / 4.89 / 0.09 / 0.11 | 4.6 | 2.7 | 1.6 | 23 | 39 |
| New thread | 16.0 | 11.5 | 17.6 | **9.4 (54%)** | 2.95 / 6.24 / 0.07 / 0.15 | 5.3 | 2.9 | 1.8 | 25 | 49 |
| Post edit | 13.9 | 9.9 | 16.3 | **8.5 (52%)** | 2.28 / 5.40 / 0.56 / 0.26 | 5.1 | 2.7 | 1.7 | 25 | 39 |
| Mark read | 6.4 | 4.7 | 7.0 | **2.6 (37%)** | 0.84 / 1.68 / 0.03 / 0.06 | 2.2 | 2.2 | 1.2 | 12 | 16 |
| Notifications inbox | 32.9 | 30.3 | 33.7 | **17.9 (53%)** | 4.86 / 8.79 / 3.69 / 0.55 | 2.8 | 13.0 | 6.3 | 4 | 4 |
| Search | 10.2 | 9.3 | 10.5 | **5.4 (51%)** | 1.45 / 2.35 / 1.59 / 0.01 | 1.2 | 3.9 | 4.4 | 5 | 7 |
| Home | 11.4 | 10.4 | 12.8 | **4.2 (33%)** | 1.11 / 0.81 / 2.04 / 0.22 | 1.4 | 7.2 | 3.0 | 4 | 4 |
| Category threads | 12.2 | 11.1 | 13.2 | **3.7 (28%)** | 1.33 / 0.73 / 1.19 / 0.41 | 1.5 | 8.1 | 2.5 | 4 | 4 |
| Category index | 5.8 | 5.3 | 6.2 | **1.5 (25%)** | 0.42 / 0.42 / 0.68 / 0.02 | 0.7 | 4.0 | 2.2 | 3 | 3 |
| Thread page | 11.7 | 10.2 | 12.6 | **0.8 (6%)** | 0.00 / 0.47 / 0.04 / 0.26 | 1.8 | 10.1 | 0.4 | 8 | 8 |
| Thread page, anonymous | 7.7 | 7.3 | 8.1 | **0.3 (4%)** | 0.00 / 0.17 / 0.03 / 0.10 | 0.8 | 7.0 | 0.4 | 3 | 3 |

What it says:

- **On every write, DBIx::Class costs more than PostgreSQL**: half of each
  request, 1.2 to 1.8 times the DBI time, and the DBI time itself includes
  2 to 22 savepoint round trips per command.
- **On every page it has not been removed from, it costs two to six times
  PostgreSQL.** The inbox spends 17.9 ms in DBIx::Class for 4 statements:
  4.9 ms building two statements with nested readability subqueries, and
  8.8 ms in resultset and storage work around them.
- **Where it has been removed, it is gone.** The thread page's two main
  statements are built once by `Infrastructure::PreparedQuery`; DBIx::Class
  is 6% of that page, and the rest is rendering. The pages' `other` time is
  Mojolicious and the views, outside this work (ADR 0121 caches the
  anonymous pages).
- **PostgreSQL replans today's statements every call.** The thread page's
  post statement plans in 0.165 ms and executes in 0.111 ms; the generic
  plan a function pins halves the call (ADR 0126, section 4).

## The hot requests, statement by statement

`S`, `I`, `U`, `D` are `SELECT`, `INSERT`, `UPDATE`, `DELETE`, followed by
the tables the statement reads or writes, in its order. `FNKU`, `FKS`, `FU`,
`FS` are `FOR NO KEY UPDATE`, `FOR KEY SHARE`, `FOR UPDATE`, `FOR SHARE`;
`+advisory` is an advisory lock. `svp[...]` is what runs under a savepoint,
two extra round trips each; `×n` repeats. The anonymous thread page sends
the thread head, the posts and the attachment links: 3 statements.

**Thread page** (8 statements, 8 round trips):

- `Identity::Store::validate_session`: S sessions
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Forum::ThreadDetailReader::thread_page`: S threads,users,categories,spaces → S posts,post_bodies,users
- `Attachment::Store::attachments_for_posts`: S attachment_links
- `Community::BookmarkStore::status_for_user_target`: S bookmarks
- `Notification::SubscriptionStore::status_for_user_target`: S subscriptions
- `Forum::ReadState::summary_for_page`: S thread_read_state

**Category threads** (4 statements, 4 round trips):

- `Identity::Store::validate_session`: S sessions
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Forum::CategoryReader::find_category`: S categories,spaces
- `Forum::ThreadReader::list_category_threads`: S thread_counters,threads,users

**Home** (4 statements, 4 round trips):

- `Identity::Store::validate_session`: S sessions
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Forum::HomePageReader::home_page`: S categories,spaces → S thread_counters,threads,users,categories,spaces

**Category index** (3 statements, 3 round trips):

- `Identity::Store::validate_session`: S sessions
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Forum::CategoryReader::list_categories`: S categories,spaces

**Notifications inbox** (4 statements, 4 round trips):

- `Identity::Store::validate_session`: S sessions
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Notification::Dispatcher::list_page_for_user`: S posts,threads,notification_inbox,notifications,categories,spaces
- `Notification::Dispatcher::unread_count_for_user`: S notification_inbox,notifications,posts,threads,categories,spaces

**Search** (5 statements, 7 round trips):

- `Identity::Store::validate_session`: S sessions
- `Operations::RateLimiter::check`: I rate_limit_buckets ON CONFLICT
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Search::Searcher::ranked_search`: BEGIN → S set_config → S posts,threads,search_documents,categories,spaces,users → COMMIT

**Reply** (23 statements, 39 round trips):

- `Identity::Store::validate_session`: S sessions
- `Operations::RateLimiter::check`: I rate_limit_buckets ON CONFLICT
- `Moderation::SuspensionStore::can_participate`: S users → S suspensions
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Forum::PostingWorkflow::create_reply`: BEGIN → S command_log → svp[I command_log] → S threads,users,categories,spaces → S threads FNKU → svp[S posts; I posts; svp[I post_bodies]; svp[I post_revisions]; S thread_counters; U thread_counters; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → U command_log → COMMIT

**New thread** (25 statements, 49 round trips):

- `Identity::Store::validate_session`: S sessions
- `Operations::RateLimiter::check`: I rate_limit_buckets ON CONFLICT
- `Moderation::SuspensionStore::can_participate`: S users → S suspensions
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Forum::PostingWorkflow::create_thread`: BEGIN → S command_log → svp[I command_log] → S categories,spaces → svp[I threads; svp[I posts; svp[I post_bodies]; svp[I post_revisions]; svp[I thread_counters]]] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT

**Post edit** (25 statements, 39 round trips):

- `Identity::Store::validate_session`: S sessions
- `Operations::RateLimiter::check`: I rate_limit_buckets ON CONFLICT
- `Moderation::SuspensionStore::can_participate`: S users → S suspensions
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Forum::PostingWorkflow::edit_post`: BEGIN → S command_log → svp[I command_log] → S posts → S threads,users,categories,spaces → S threads FKS → S posts FU → S posts → S post_bodies → svp[S post_revisions; svp[I post_bodies]; I post_revisions; U posts; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → U command_log → COMMIT

**Mark read (first mark of a thread)** (10 statements, 20 round trips):

- `Identity::Store::validate_session`: S sessions
- `Operations::RateLimiter::check`: I rate_limit_buckets ON CONFLICT
- `Forum::ViewerResolver::resolve`: S suspensions,role_bindings,role_permissions,permissions,users
- `Forum::ThreadDetailReader::find_thread`: S threads,users,categories,spaces
- `Forum::ReadWorkflow::mark_thread_read`: BEGIN → S command_log → svp[I command_log] → S thread_read_state → svp[svp[I thread_read_state]; svp[I user_read_marker_deltas]] → U command_log → COMMIT

## What every request and every write repeats

These steps sit under most operations, so phase 1 moves them first (ADR
0126, section 12, wave 1).

| Step | Module | Statements today | Round trips | Locks | In a function |
| --- | --- | --- | --: | --- | --- |
| Connection setup | `GPForum::Config::database_session_settings` (`on_connect_do`) | 5 `SET` and a `DO` block | 6 per connection | none | stays: session state |
| Session check | `Identity::Store::validate_session` | `S sessions`, and `U sessions` when the throttle lets `last_seen_at` move | 1 to 2 | none | `api.session_validate_v1` |
| Viewer | `Forum::ViewerResolver::resolve` | one raw `S users` with suspension and grants subqueries | 1 | none | `api.session_viewer_v1` |
| Rate limit | `Operations::RateLimiter::PostgreSQLStore::check` | `I rate_limit_buckets ON CONFLICT` | 1 | the bucket row | `api.ops_rate_limit_check_v1` |
| Participation | `Moderation::SuspensionStore::can_participate` | `S users`, `S suspensions` | 2 | none | `api.moderation_can_participate_v1` |
| Command log | `Operations::CommandIdempotency::run` | `BEGIN`, `S command_log`, `svp[I command_log]`, the work, `U command_log`, `COMMIT` | 7 + the work | the command row | inside each command's function |
| Event and outbox | `Infrastructure::EventRecorder::record_event` | `S event_log` (every partition, ADR 0116), `svp[I event_log]`, `S outbox_messages`, `svp[I outbox_messages]`; an advisory lock on the id when the caller passed one | 8 | advisory (caller's id) | `api.core_record_event_v1` |
| Audit | `Infrastructure::EventRecorder::record_audit` | `pg_advisory_xact_lock(2026060210)`, `svp[S audit_log tip; I audit_log]` | 5 | advisory (the chain) | `api.core_record_audit_v1` |
| Unique conflict recovery | `Infrastructure::UniqueConflict::attempt` | a savepoint around each insert that may collide | +2 per insert | none | an `EXCEPTION WHEN unique_violation` block |

A reply therefore spends 20 of its 39 round trips on the command log, the
event, the outbox row, the audit row and their savepoints, and 5 on the
request prologue.

## Areas at a glance

Statements and round trips add up each operation's success path once.
*Not driven* counts public subs that reach the database and were never the
outermost call of a traced operation.

| Area | Operations | Hot | Async | Statements | Round trips | Not driven | Modules, lines | Wave |
| --- | --: | --: | --: | --: | --: | --: | --- | --: |
| Sessions | 4 | 3 | 0 | 7 | 14 | 2 | 1, 331 | 1 |
| Shared write steps | 6 | 3 | 0 | 14 | 26 | 4 | 7, 1,322 | 1 |
| Forum writes | 14 | 14 | 0 | 118 | 236 | 3 | 5, 1,915 | 2 |
| Forum reads | 15 | 15 | 0 | 17 | 17 | 2 | 7, 1,412 | 3 |
| Notifications | 23 | 17 | 0 | 65 | 89 | 0 | 3, 1,196 | 4 |
| Search | 14 | 3 | 8 | 949 | 1,471 | 5 | 5, 1,890 | 5 |
| Community | 21 | 17 | 4 | 67 | 123 | 3 | 7, 1,585 | 6 |
| Operations, readiness, metrics | 14 | 2 | 0 | 513 | 518 | 14 | 15, 3,601 | 7 |
| Identity | 26 | 10 | 0 | 159 | 272 | 23 | 11, 2,289 | 8 |
| Outbox and workers | 14 | 0 | 13 | 46 | 64 | 22 | 18, 3,402 | 9 |
| Attachments | 21 | 1 | 2 | 109 | 171 | 7 | 4, 1,257 | 10 |
| Moderation | 30 | 2 | 0 | 287 | 517 | 0 | 4, 1,291 | 10 |
| Admin | 31 | 0 | 0 | 420 | 706 | 12 | 10, 2,630 | 11 |
| Privacy and portability | 23 | 0 | 0 | 195 | 351 | 7 | 9, 2,348 | 11 |
| Commands and migrations | 6 | 0 | 0 | 860 | 876 | 13 | 7, 4,320 | 12 |
| Partitions | 3 | 0 | 0 | 72 | 90 | 1 | 1, 857 | 12 |
| Query budgets and plans | 3 | 0 | 0 | 42 | 58 | 2 | 2, 778 | 12 |
| **All** | 268 | 87 | 27 | 3,940 | 5,599 | 120 | 116, 32,424 | |

## Operations by area

One row per traced operation, its success path as the suite drove it (the
most frequent path that committed and wrote, for a write). *Kind*: **hot
read** runs on a page view, **hot write** on a member's write, **async** in
an outbox handler or projection, **console** on an admin, moderation or
privacy page, **cold** from the command line or a scheduled job. A store's
row is the store as its own tests drive it, in a transaction of its own; in
production it runs inside the workflow named in the last column, and its
statements become part of that workflow's function. Function names are the
proposed `api` names of ADR 0126, section 2; phase 1 fixes them.

### Forum reads

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Forum::CategoryReader::find_category` | hot read | S categories,spaces | 1 | 1 | autocommit | `api.forum_find_category_v1` |
| `Service::Forum::CategoryReader::list_categories` | hot read | S categories,spaces | 1 | 1 | autocommit | `api.forum_list_categories_v1` |
| `Service::Forum::HomePageReader::home_page` | hot read | S categories,spaces → S thread_counters,threads,users,categories,spaces | 2 | 2 | autocommit | `api.forum_home_page_v1` |
| `Service::Forum::PostReader::find_listed_post` | hot read | S posts,post_bodies,users | 1 | 1 | autocommit | `api.forum_find_listed_post_v1` |
| `Service::Forum::PostReader::find_visible_post` | hot read | S posts,threads,categories,spaces | 1 | 1 | autocommit | `api.forum_find_visible_post_v1` |
| `Service::Forum::PostReader::list_thread_posts` | hot read | S posts,post_bodies,users | 1 | 1 | autocommit | `api.forum_list_thread_posts_v1` |
| `Service::Forum::ReadState::state_for_thread` | hot read | S thread_read_state | 1 | 1 | autocommit | `api.forum_state_for_thread_v1` |
| `Service::Forum::ReadState::summary_for_page` | hot read | S thread_read_state | 1 | 1 | autocommit | `api.forum_summary_for_page_v1` |
| `Service::Forum::Readability::readers_of` | hot read | S threads,categories,spaces | 1 | 1 | autocommit | `api.forum_readers_of_v1` |
| `Service::Forum::ThreadDetailReader::find_thread` | hot read | S threads,users,categories,spaces | 1 | 1 | autocommit | `api.forum_find_thread_v1` |
| `Service::Forum::ThreadDetailReader::find_thread_row` | hot read | S threads,users,categories,spaces | 1 | 1 | autocommit | `api.forum_find_thread_row_v1` |
| `Service::Forum::ThreadDetailReader::thread_page` | hot read | S threads,users,categories,spaces → S posts,post_bodies,users | 2 | 2 | autocommit | `api.forum_thread_page_v1` |
| `Service::Forum::ThreadReader::list_category_threads` | hot read | S thread_counters,threads,users | 1 | 1 | autocommit | `api.forum_list_category_threads_v1` |
| `Service::Forum::ThreadReader::list_public_threads` | hot read | S thread_counters,threads,users,categories,spaces | 1 | 1 | autocommit | `api.forum_list_public_threads_v1` |
| `Service::Forum::ViewerResolver::resolve` | hot read | S suspensions,role_bindings,role_permissions,permissions,users | 1 | 1 | autocommit | `api.forum_resolve_v1` |

### Forum writes

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Forum::PostStore::create_post` | hot write | BEGIN → S threads FNKU → svp[S posts; I posts; svp[I post_bodies]; svp[I post_revisions]; S thread_counters; U thread_counters; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 14 | 28 | txn, FNKU, advisory, 6 svp | inside PostingWorkflow::create_reply |
| `Service::Forum::PostStore::delete_post` | hot write | BEGIN → S threads FKS → S posts FU → S posts → U posts → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 11 | 19 | txn, FKS, FU, advisory, 3 svp | inside PostingWorkflow::delete_post |
| `Service::Forum::PostStore::edit_post` | hot write | BEGIN → S threads FKS → S posts FU → S posts → COMMIT | 3 | 5 | txn, FKS, FU | inside PostingWorkflow::edit_post |
| `Service::Forum::PostStore::restore_post` | hot write | BEGIN → S threads FKS → S posts FU → S posts → U posts → S thread_counters → U thread_counters → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 13 | 21 | txn, FKS, FU, advisory, 3 svp | `api.forum_restore_post_v1` |
| `Service::Forum::PostingWorkflow::create_reply` | hot write | BEGIN → S command_log → svp[I command_log] → S threads,users,categories,spaces → S threads FNKU → svp[S posts; I posts; svp[I post_bodies]; svp[I post_revisions]; S thread_counters; U thread_counters; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → U command_log → COMMIT | 18 | 34 | txn, FNKU, advisory, 7 svp | `api.forum_create_reply_v1` |
| `Service::Forum::PostingWorkflow::create_thread` | hot write | BEGIN → S command_log → svp[I command_log] → S categories,spaces → svp[I threads; svp[I posts; svp[I post_bodies]; svp[I post_revisions]; svp[I thread_counters]]] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 20 | 44 | txn, advisory, 11 svp | `api.forum_create_thread_v1` |
| `Service::Forum::PostingWorkflow::delete_post` | hot write | BEGIN → S command_log → svp[I command_log] → U command_log → COMMIT | 3 | 7 | txn, 1 svp | `api.forum_delete_post_v1` |
| `Service::Forum::PostingWorkflow::edit_post` | hot write | BEGIN → S command_log → svp[I command_log] → U command_log → COMMIT | 3 | 7 | txn, 1 svp | `api.forum_edit_post_v1` |
| `Service::Forum::ReadState::mark_thread_read` | hot write | BEGIN → S thread_read_state → COMMIT | 1 | 3 | txn | `api.forum_mark_thread_read_v1` |
| `Service::Forum::ThreadStore::create_thread` | hot write | BEGIN → svp[I threads; svp[I posts; svp[I post_bodies]; svp[I post_revisions]; svp[I thread_counters]]] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 16 | 38 | txn, advisory, 10 svp | inside PostingWorkflow::create_thread |
| `Service::Forum::ThreadStore::delete_thread` | hot write | BEGIN → S threads FU → S threads → U threads → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 10 | 18 | txn, FU, advisory, 3 svp | `api.forum_delete_thread_v1` |
| `Service::Forum::ThreadStore::edit_thread` | hot write | BEGIN → S threads FU → S threads → COMMIT | 2 | 4 | txn, FU | `api.forum_edit_thread_v1` |
| `Service::Forum::ThreadStore::move_thread` | hot write | BEGIN → S threads FU → S threads → COMMIT | 2 | 4 | txn, FU | `api.forum_move_thread_v1` |
| `Service::Forum::ThreadStore::restore_thread` | hot write | BEGIN → S threads FU → S threads → COMMIT | 2 | 4 | txn, FU | `api.forum_restore_thread_v1` |

### Sessions

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Identity::SessionStore::validate_session` | hot read | S sessions | 1 | 1 | autocommit | `api.session_validate_session_v1` |
| `Service::Identity::Store::validate_session` | hot read | S sessions | 1 | 1 | autocommit | `api.session_validate_session_v1` |
| `Service::Identity::SessionStore::create_session` | hot write | BEGIN → svp[I sessions; ROLLBACK TO] → S pg_class,family,pg_inherits → svp[I sessions] → COMMIT | 3 | 10 | txn, 2 svp | inside Workflow::login |
| `Service::Identity::Store::revoke_session` | cold | S sessions → U sessions | 2 | 2 | autocommit | last wave (cold) |

### Identity

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Identity::ProfileReader::public_profile` | hot read | S users → S threads,categories,spaces → S posts,threads,categories,spaces → S threads,categories,spaces → S posts,threads,categories,spaces,post_bodies → S trust_score_snapshots | 6 | 6 | autocommit | `api.identity_public_profile_v1` |
| `Service::Identity::Store::preferred_locale_for_user` | hot read | S users | 1 | 1 | autocommit | `api.identity_preferred_locale_for_user_v1` |
| `Service::Identity::Store::preferred_theme_for_user` | hot read | S users | 1 | 1 | autocommit | `api.identity_preferred_theme_for_user_v1` |
| `Service::Identity::AuthStore::authenticate_login` | hot write | S users → S credentials → BEGIN → S credentials FS → svp[I sessions] → COMMIT | 4 | 8 | txn, FS, 1 svp | inside Workflow::login |
| `Service::Identity::SecurityAudit::record_login_request` | hot write | S pg_advisory_xact_lock +advisory → S audit_log → BEGIN → I audit_log → COMMIT | 3 | 5 | txn, advisory | `api.identity_record_login_request_v1` |
| `Service::Identity::SecurityAudit::record_logout_request` | hot write | S pg_advisory_xact_lock +advisory → S audit_log → BEGIN → I audit_log → COMMIT | 3 | 5 | txn, advisory | `api.identity_record_logout_request_v1` |
| `Service::Identity::Store::authenticate_login` | hot write | S users → S credentials → BEGIN → S credentials FS → svp[I sessions] → COMMIT | 4 | 8 | txn, FS, 1 svp | inside Workflow::login |
| `Service::Identity::Workflow::login` | hot write | S users → S credentials → BEGIN → S credentials FS → svp[I sessions] → COMMIT | 4 | 8 | txn, FS, 1 svp | `api.identity_login_v1` |
| `Service::Identity::Workflow::logout` | hot write | BEGIN → S command_log → svp[I command_log] → S sessions → U sessions → U command_log → COMMIT | 5 | 9 | txn, 1 svp | `api.identity_logout_v1` |
| `Service::Identity::Workflow::register` | hot write | BEGIN → S command_log → svp[I command_log] → S users ×2 → svp[I users; S credentials; svp[I credentials]; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → S users → svp[I identity_tokens] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_mes … | 24 | 46 | txn, advisory, 10 svp | `api.identity_register_v1` |
| `Service::Identity::CredentialStore::create_password_credential` | cold | S credentials → svp[I credentials; ROLLBACK TO] → S credentials → svp[I credentials] | 4 | 9 | autocommit, 2 svp | last wave (cold) |
| `Service::Identity::PreferenceStore::update_preferred_timezone` | cold | S users → U users | 2 | 2 | autocommit | last wave (cold) |
| `Service::Identity::Store::change_password` | cold | S users → S credentials → BEGIN → S credentials FU ×2 → U credentials → S credentials → svp[I credentials] → U users → U sessions → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 12 | 18 | txn, FU, advisory, 2 svp | last wave (cold) |
| `Service::Identity::Store::confirm_email_change` | cold | BEGIN → S identity_tokens FU → S identity_tokens → U identity_tokens → S users → COMMIT | 4 | 6 | txn, FU | last wave (cold) |
| `Service::Identity::Store::confirm_email_verification` | cold | BEGIN → S identity_tokens FU → S identity_tokens → U identity_tokens → S users → U users → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 8 | 12 | txn, FU, advisory, 1 svp | last wave (cold) |
| `Service::Identity::Store::create_registration` | cold | S users ×2 → BEGIN → I users → S credentials → svp[I credentials] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 12 | 22 | txn, advisory, 4 svp | last wave (cold) |
| `Service::Identity::Store::request_email_change` | cold | S users ×2 → BEGIN → svp[I identity_tokens] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → COMMIT | 10 | 20 | txn, advisory, 4 svp | last wave (cold) |
| `Service::Identity::Store::request_email_verification` | cold | BEGIN → S users → svp[I identity_tokens] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → COMMIT | 9 | 19 | txn, advisory, 4 svp | last wave (cold) |
| `Service::Identity::Store::request_password_reset` | cold | BEGIN → S users → svp[I identity_tokens] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → COMMIT | 9 | 19 | txn, advisory, 4 svp | last wave (cold) |
| `Service::Identity::Store::reset_password` | cold | BEGIN → S identity_tokens FU → S identity_tokens FU+nowait → S identity_tokens → U identity_tokens → S users → S credentials FU ×2 → U credentials → S credentials → svp[I credentials] → U users → U sessions → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 15 | 21 | txn, FU, advisory, 2 svp | last wave (cold) |
| `Service::Identity::Store::update_preferred_locale` | cold | S users | 1 | 1 | autocommit | last wave (cold) |
| `Service::Identity::Store::update_preferred_theme` | cold | S users | 1 | 1 | autocommit | last wave (cold) |
| `Service::Identity::Store::update_preferred_timezone` | cold | S users → U users | 2 | 2 | autocommit | last wave (cold) |
| `Service::Identity::TokenStore::consume_token` | cold | S identity_tokens FU → S identity_tokens → U identity_tokens | 3 | 3 | autocommit, FU | last wave (cold) |
| `Service::Identity::TokenStore::create_token` | cold | BEGIN → I identity_tokens → COMMIT | 1 | 3 | txn | last wave (cold) |
| `Service::Identity::Workflow::verify_email` | cold | BEGIN → S command_log → svp[I command_log] → S identity_tokens FU → S identity_tokens → U identity_tokens → S users → U users → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 11 | 17 | txn, FU, advisory, 2 svp | last wave (cold) |

### Moderation

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Moderation::SuspensionStore::can_participate` | hot read | S users → S suspensions | 2 | 2 | autocommit | `api.moderation_can_participate_v1` |
| `Service::Moderation::ReportStore::create_report` | hot write | BEGIN → S reports → svp[I reports; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 9 | 19 | txn, advisory, 4 svp | inside Workflow::create_report |
| `Service::Moderation::ActionStore::hide_post` | console | BEGIN → S posts FU → S moderation_actions → S posts → U posts → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 12 | 22 | txn, FU, advisory, 4 svp | inside Workflow::hide_post |
| `Service::Moderation::ActionStore::hide_thread` | console | BEGIN → S threads FU → S moderation_actions → S threads → U threads → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 12 | 22 | txn, FU, advisory, 4 svp | inside Workflow::hide_thread |
| `Service::Moderation::ActionStore::lock_thread` | console | BEGIN → S threads FU → S moderation_actions → S threads → U threads → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 12 | 22 | txn, FU, advisory, 4 svp | inside Workflow::lock_thread |
| `Service::Moderation::ActionStore::restore_post` | console | BEGIN → S posts FU → S posts → U posts → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 11 | 21 | txn, FU, advisory, 4 svp | inside Workflow::restore_post |
| `Service::Moderation::ActionStore::restore_thread` | console | BEGIN → S threads FU → S moderation_actions → S threads → U threads → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 12 | 22 | txn, FU, advisory, 4 svp | inside Workflow::restore_thread |
| `Service::Moderation::ActionStore::reverse_action` | console | BEGIN → S moderation_actions → U moderation_actions → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 9 | 17 | txn, advisory, 3 svp | inside Workflow::reverse_action |
| `Service::Moderation::ActionStore::unlock_thread` | console | BEGIN → S threads FU → S moderation_actions → S threads → U threads → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 12 | 22 | txn, FU, advisory, 4 svp | inside Workflow::unlock_thread |
| `Service::Moderation::ReportStore::assign_report` | console | BEGIN → S reports FU → S reports → U reports → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 11 | 19 | txn, FU, advisory, 3 svp | inside Workflow::assign_report |
| `Service::Moderation::ReportStore::list_queue` | console | S reports | 1 | 1 | autocommit | `api.moderation_list_queue_v1` |
| `Service::Moderation::ReportStore::release_report` | console | BEGIN → S reports FU → S reports → U reports → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 11 | 19 | txn, FU, advisory, 3 svp | inside Workflow::release_report |
| `Service::Moderation::ReportStore::resolve_report` | console | BEGIN → S reports FU → S reports → U reports → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 11 | 19 | txn, FU, advisory, 3 svp | inside Workflow::resolve_report |
| `Service::Moderation::ReviewReader::list_actions` | console | S moderation_actions | 1 | 1 | autocommit | `api.moderation_list_actions_v1` |
| `Service::Moderation::ReviewReader::list_suspensions` | console | S suspensions | 1 | 1 | autocommit | `api.moderation_list_suspensions_v1` |
| `Service::Moderation::SuspensionStore::active_for_user` | console | S suspensions | 1 | 1 | autocommit | inside Workflow::suspend_user |
| `Service::Moderation::SuspensionStore::create_suspension` | console | BEGIN → S users → S suspensions → svp[I suspensions; U users; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 11 | 21 | txn, advisory, 4 svp | inside Workflow::suspend_user |
| `Service::Moderation::SuspensionStore::revoke_suspension` | console | BEGIN → S suspensions → U suspensions → S users → U users → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 11 | 19 | txn, advisory, 3 svp | inside Workflow::revoke_suspension |
| `Service::Moderation::Workflow::assign_report` | console | BEGIN → S command_log → svp[I command_log] → S reports FU → S reports → U command_log → COMMIT | 5 | 9 | txn, FU, 1 svp | `api.moderation_assign_report_v1` |
| `Service::Moderation::Workflow::hide_post` | console | BEGIN → S command_log → svp[I command_log] → S posts FU → S moderation_actions → S posts → U posts → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 15 | 27 | txn, FU, advisory, 5 svp | `api.moderation_hide_post_v1` |
| `Service::Moderation::Workflow::hide_thread` | console | BEGIN → S command_log → svp[I command_log] → S threads FU → S moderation_actions → S threads → U threads → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 15 | 27 | txn, FU, advisory, 5 svp | `api.moderation_hide_thread_v1` |
| `Service::Moderation::Workflow::lock_thread` | console | BEGIN → S command_log → svp[I command_log] → S threads FU → S moderation_actions → S threads → U threads → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 15 | 27 | txn, FU, advisory, 5 svp | `api.moderation_lock_thread_v1` |
| `Service::Moderation::Workflow::release_report` | console | BEGIN → S command_log → svp[I command_log] → S reports FU → S reports → U command_log → COMMIT | 5 | 9 | txn, FU, 1 svp | `api.moderation_release_report_v1` |
| `Service::Moderation::Workflow::resolve_report` | console | BEGIN → S command_log → svp[I command_log] → S reports FU → S reports → U command_log → COMMIT | 5 | 9 | txn, FU, 1 svp | `api.moderation_resolve_report_v1` |
| `Service::Moderation::Workflow::restore_post` | console | BEGIN → S command_log → svp[I command_log] → S posts FU → S moderation_actions → S posts → U posts → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 15 | 27 | txn, FU, advisory, 5 svp | `api.moderation_restore_post_v1` |
| `Service::Moderation::Workflow::restore_thread` | console | BEGIN → S command_log → svp[I command_log] → S threads FU → S moderation_actions → S threads → U threads → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 15 | 27 | txn, FU, advisory, 5 svp | `api.moderation_restore_thread_v1` |
| `Service::Moderation::Workflow::reverse_action` | console | BEGIN → S command_log → svp[I command_log] → S moderation_actions → U command_log → COMMIT | 4 | 8 | txn, 1 svp | `api.moderation_reverse_action_v1` |
| `Service::Moderation::Workflow::revoke_suspension` | console | BEGIN → S command_log → svp[I command_log] → S suspensions → U suspensions → S users → U users → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 14 | 24 | txn, advisory, 4 svp | `api.moderation_revoke_suspension_v1` |
| `Service::Moderation::Workflow::suspend_user` | console | BEGIN → S command_log → svp[I command_log] → S users → S suspensions → svp[I suspensions; U users; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → U command_log → COMMIT | 14 | 26 | txn, advisory, 5 svp | `api.moderation_suspend_user_v1` |
| `Service::Moderation::Workflow::unlock_thread` | console | BEGIN → S command_log → svp[I command_log] → S threads FU → S moderation_actions → S threads → U threads → svp[I moderation_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 15 | 27 | txn, FU, advisory, 5 svp | `api.moderation_unlock_thread_v1` |

### Admin

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Admin::AuditReview::page` | console | S audit_log | 1 | 1 | autocommit | `api.admin_page_v1` |
| `Service::Admin::AuditReview::recent` | console | S audit_log | 1 | 1 | autocommit | `api.admin_recent_v1` |
| `Service::Admin::Bootstrapper::create_owner` | console | BEGIN → S users ×2 → svp[I users; S credentials; svp[I credentials]; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → S roles ×2 → svp[I roles; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → S permissions → S role_permissions ×2 → svp[I role_permissions; S pg_advisory_xact_lock +advisory; svp[S audit_log; … | 125 | 203 | txn, advisory, 38 svp | `api.admin_create_owner_v1` |
| `Service::Admin::Bootstrapper::has_owner` | console | S roles → S role_bindings | 2 | 2 | autocommit | `api.admin_has_owner_v1` |
| `Service::Admin::CategoryStore::create_category` | console | BEGIN → S spaces → S categories → svp[I categories; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 10 | 20 | txn, advisory, 4 svp | inside Workflow::create_category |
| `Service::Admin::CategoryStore::list_categories` | console | S categories | 1 | 1 | autocommit | `api.admin_list_categories_v1` |
| `Service::Admin::CategoryStore::update_category` | console | BEGIN → S categories → svp[U categories] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 9 | 19 | txn, advisory, 4 svp | inside Workflow::update_category |
| `Service::Admin::ConsoleReader::async_jobs` | console | S outbox_messages,audit_log,dead_letters → S outbox_messages → S dead_letters → S outbox_messages | 4 | 4 | autocommit | `api.admin_async_jobs_v1` |
| `Service::Admin::ConsoleReader::email_of` | console | S users | 1 | 1 | autocommit | `api.admin_email_of_v1` |
| `Service::Admin::ConsoleReader::list_dead_letters` | console | S outbox_messages,audit_log,dead_letters | 1 | 1 | autocommit | `api.admin_list_dead_letters_v1` |
| `Service::Admin::Diagnostics::overview` | console | S audit_log ×2 → S users | 3 | 3 | autocommit | `api.admin_overview_v1` |
| `Service::Admin::Maintenance::purge_public_cache` | console | S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] | 3 | 5 | autocommit, advisory, 1 svp | `api.admin_purge_public_cache_v1` |
| `Service::Admin::Maintenance::request_search_rebuild` | console | S event_log ×2 → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] | 8 | 14 | autocommit, advisory, 3 svp | `api.admin_request_search_rebuild_v1` |
| `Service::Admin::Maintenance::search_status` | console | S now,outbox_messages → S event_log | 2 | 2 | autocommit | `api.admin_search_status_v1` |
| `Service::Admin::PermissionGate::allowed` | console | S role_bindings,roles,role_permissions,permissions | 1 | 1 | autocommit | `api.admin_allowed_v1` |
| `Service::Admin::PermissionReview::permissions_for_role` | console | S role_permissions | 1 | 1 | autocommit | `api.admin_permissions_for_role_v1` |
| `Service::Admin::PermissionReview::roles_for_user` | console | S role_bindings | 1 | 1 | autocommit | `api.admin_roles_for_user_v1` |
| `Service::Admin::RoleBindingStore::bind_role` | console | BEGIN → S role_bindings → svp[I role_bindings; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 5 | 11 | txn, advisory, 2 svp | inside AdminBootstrap::run |
| `Service::Admin::RoleBindingStore::revoke_binding` | console | BEGIN → S role_bindings FU → U role_bindings → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 5 | 9 | txn, FU, advisory, 1 svp | `api.admin_revoke_binding_v1` |
| `Service::Admin::RoleCatalog::attach_permission` | console | S role_permissions → svp[I role_permissions; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] | 5 | 9 | autocommit, advisory, 2 svp | `api.admin_attach_permission_v1` |
| `Service::Admin::RoleCatalog::create_permission` | console | S permissions → svp[I permissions; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] | 5 | 9 | autocommit, advisory, 2 svp | `api.admin_create_permission_v1` |
| `Service::Admin::RoleCatalog::create_role` | console | S roles → svp[I roles; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] | 5 | 9 | autocommit, advisory, 2 svp | `api.admin_create_role_v1` |
| `Service::Admin::RoleCatalog::list_permissions` | console | S permissions | 1 | 1 | autocommit | `api.admin_list_permissions_v1` |
| `Service::Admin::RoleCatalog::list_roles` | console | S roles | 1 | 1 | autocommit | `api.admin_list_roles_v1` |
| `Service::Admin::Workflow::check_antivirus` | console | BEGIN → S command_log → svp[I command_log] → S set_config → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 7 | 13 | txn, advisory, 2 svp | `api.admin_check_antivirus_v1` |
| `Service::Admin::Workflow::create_category` | console | BEGIN → S command_log → svp[I command_log] → S spaces → S categories → svp[I categories; ROLLBACK TO] → S pg_class,family,pg_inherits → S categories → U command_log → COMMIT | 8 | 15 | txn, 2 svp | `api.admin_create_category_v1` |
| `Service::Admin::Workflow::purge_public_cache` | console | BEGIN → S command_log → svp[I command_log] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 6 | 12 | txn, advisory, 2 svp | `api.admin_purge_public_cache_v1` |
| `Service::Admin::Workflow::replay_dead_letter` | console | BEGIN → S command_log → svp[I command_log] → S dead_letters FU → S audit_log → I outbox_messages → ROLLBACK | 5 | 9 | txn, FU, 1 svp | `api.admin_replay_dead_letter_v1` |
| `Service::Admin::Workflow::send_test_mail` | console | BEGIN → S command_log → svp[I command_log] → S users → S set_config → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → U command_log → COMMIT | 8 | 14 | txn, advisory, 2 svp | `api.admin_send_test_mail_v1` |
| `Service::Admin::Workflow::update_category` | console | BEGIN → S command_log → svp[I command_log] → S categories → svp[U categories; ROLLBACK TO] → U command_log → COMMIT | 5 | 12 | txn, 2 svp | `api.admin_update_category_v1` |
| `Command::AdminBootstrap::run` | cold | BEGIN → S roles ×2 → svp[I roles; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → S permissions ×2 → svp[I permissions; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → S role_permissions ×2 → svp[I role_permissions; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → S permissions ×2 → svp[I permissions; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audi … | 180 | 302 | txn, advisory, 60 svp | last wave (cold) |

### Privacy and portability

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Portability::ExportBundleBuilder::complete_user_export` | console | BEGIN → S export_requests → S attachments → S notification_inbox → S posts → S notification_preferences → S subscriptions → S users → U export_requests → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 15 | 23 | txn, advisory, 3 svp | `api.privacy_complete_user_export_v1` |
| `Service::Portability::ExportBundleBuilder::create_request` | console | BEGIN → S export_requests → svp[I export_requests; ROLLBACK TO] → S export_requests → S pg_class,family,pg_inherits → svp[I export_requests; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 12 | 25 | txn, advisory, 5 svp | `api.privacy_create_request_v1` |
| `Service::Portability::ExportBundleBuilder::request_user_export` | console | BEGIN → S export_requests → svp[I export_requests; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 9 | 19 | txn, advisory, 4 svp | `api.privacy_request_user_export_v1` |
| `Service::Privacy::DataRightsReview::active_holds` | console | S retention_holds | 1 | 1 | autocommit | `api.privacy_active_holds_v1` |
| `Service::Privacy::DataRightsReview::active_holds_for_user` | console | S retention_holds | 1 | 1 | autocommit | `api.privacy_active_holds_for_user_v1` |
| `Service::Privacy::DataRightsReview::completed_export_for_user` | console | S export_requests | 1 | 1 | autocommit | `api.privacy_completed_export_for_user_v1` |
| `Service::Privacy::DataRightsReview::deletion_request` | console | S deletion_requests | 1 | 1 | autocommit | `api.privacy_deletion_request_v1` |
| `Service::Privacy::DataRightsReview::deletion_requests_for_user` | console | S deletion_requests | 1 | 1 | autocommit | `api.privacy_deletion_requests_for_user_v1` |
| `Service::Privacy::DataRightsReview::erasure_jobs_by_status` | console | S erasure_jobs | 1 | 1 | autocommit | `api.privacy_erasure_jobs_by_status_v1` |
| `Service::Privacy::DataRightsReview::export_requests_for_user` | console | S export_requests | 1 | 1 | autocommit | `api.privacy_export_requests_for_user_v1` |
| `Service::Privacy::DataRightsReview::pending_deletion_requests` | console | S deletion_requests | 1 | 1 | autocommit | `api.privacy_pending_deletion_requests_v1` |
| `Service::Privacy::DataRightsReview::pending_export_requests` | console | S export_requests | 1 | 1 | autocommit | `api.privacy_pending_export_requests_v1` |
| `Service::Privacy::DeletionWorkflow::approve_request` | console | BEGIN → S deletion_requests FU → S deletion_requests → S erasure_jobs → S retention_holds → U deletion_requests → svp[I erasure_jobs] → svp[I deletion_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 14 | 26 | txn, FU, advisory, 5 svp | `api.privacy_approve_request_v1` |
| `Service::Privacy::DeletionWorkflow::complete_job` | console | BEGIN → S erasure_jobs → S deletion_requests → S retention_holds → U deletion_requests → U erasure_jobs → svp[I deletion_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 13 | 23 | txn, advisory, 4 svp | `api.privacy_complete_job_v1` |
| `Service::Privacy::DeletionWorkflow::hold_request` | console | BEGIN → S deletion_requests → U deletion_requests → svp[I deletion_actions; ROLLBACK TO] → svp[I deletion_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 11 | 24 | txn, advisory, 5 svp | `api.privacy_hold_request_v1` |
| `Service::Privacy::DeletionWorkflow::request_deletion` | console | BEGIN → S deletion_requests FU → S deletion_requests → svp[I deletion_requests; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 10 | 20 | txn, FU, advisory, 4 svp | `api.privacy_request_deletion_v1` |
| `Service::Privacy::RetentionHoldStore::active_holds_for` | console | S retention_holds | 1 | 1 | autocommit | inside Workflow::hold_deletion |
| `Service::Privacy::RetentionHoldStore::create_hold` | console | BEGIN → S retention_holds → svp[I retention_holds; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 9 | 19 | txn, advisory, 4 svp | inside Workflow::hold_deletion |
| `Service::Privacy::Workflow::approve_deletion` | console | BEGIN → S deletion_requests FU → S deletion_requests → S erasure_jobs → S retention_holds → U deletion_requests → svp[I erasure_jobs] → svp[I deletion_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 14 | 26 | txn, FU, advisory, 5 svp | `api.privacy_approve_deletion_v1` |
| `Service::Privacy::Workflow::hold_deletion` | console | S deletion_requests → BEGIN → S retention_holds → svp[I retention_holds; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT → BEGIN → S deletion_requests → U deletion_requests → svp[I deletion_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[ … | 20 | 40 | txn, advisory, 8 svp | `api.privacy_hold_deletion_v1` |
| `Service::Privacy::Workflow::request_deletion` | console | BEGIN → S deletion_requests FU → S deletion_requests → svp[I deletion_requests; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 10 | 20 | txn, FU, advisory, 4 svp | `api.privacy_request_deletion_v1` |
| `Service::Privacy::Workflow::request_export` | console | BEGIN → S command_log → svp[I command_log] → S users FS → S export_requests → svp[I export_requests; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → S export_requests → S attachments → S notification_inbox → S posts → S notification_preferences → S subscriptions → S post_bodies → S users → U export_requests → S event_log → s … | 29 | 47 | txn, FS, advisory, 8 svp | `api.privacy_request_export_v1` |
| `Service::Privacy::Workflow::run_erasure_job` | console | BEGIN → S erasure_jobs → S deletion_requests → S retention_holds → S users → S credentials → U users → S sessions → S export_requests → S command_log → U erasure_jobs → U deletion_requests → svp[I deletion_actions] → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 19 | 29 | txn, advisory, 4 svp | `api.privacy_run_erasure_job_v1` |

### Community

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Community::BookmarkStore::list_page_for_user` | hot read | S bookmarks | 1 | 1 | autocommit | `api.community_list_page_for_user_v1` |
| `Service::Community::BookmarkStore::status_for_user_target` | hot read | S bookmarks | 1 | 1 | autocommit | `api.community_status_for_user_target_v1` |
| `Service::Community::FeedReader::feed_resultset` | hot read | S suspensions,role_bindings,role_permissions,permissions,users | 1 | 1 | autocommit | `api.community_feed_resultset_v1` |
| `Service::Community::FeedReader::list_page_for_user` | hot read | S user_feed_items | 1 | 1 | autocommit | `api.community_list_page_for_user_v1` |
| `Service::Community::MentionReader::list_page_for_recipient` | hot read | S mentions,users | 1 | 1 | autocommit | `api.community_list_page_for_recipient_v1` |
| `Service::Community::MentionReader::mentions_resultset` | hot read | S suspensions,role_bindings,role_permissions,permissions,users | 1 | 1 | autocommit | `api.community_mentions_resultset_v1` |
| `Service::Community::BookmarkStore::bookmarks_resultset` | hot write | S suspensions,role_bindings,role_permissions,permissions,users | 1 | 1 | autocommit | `api.community_bookmarks_resultset_v1` |
| `Service::Community::BookmarkStore::create_bookmark` | hot write | I bookmarks | 1 | 1 | autocommit | inside Workflow::save_bookmark |
| `Service::Community::BookmarkStore::find_for_user_target` | hot write | S bookmarks | 1 | 1 | autocommit | inside Workflow::save_bookmark |
| `Service::Community::BookmarkStore::list_for_user` | hot write | S bookmarks | 1 | 1 | autocommit | `api.community_list_for_user_v1` |
| `Service::Community::BookmarkStore::remove_bookmark` | hot write | S bookmarks → U bookmarks | 2 | 2 | autocommit | `api.community_remove_bookmark_v1` |
| `Service::Community::BookmarkStore::remove_for_user_target` | hot write | S bookmarks | 1 | 1 | autocommit | `api.community_remove_for_user_target_v1` |
| `Service::Community::BookmarkStore::save_bookmark` | hot write | S bookmarks → I bookmarks | 2 | 2 | autocommit | inside Workflow::save_bookmark |
| `Service::Community::MentionStore::record_for_source` | hot write | S users → BEGIN → S mentions → svp[S users; BEGIN; S mentions; svp[I mentions]; S notification_inbox; svp[S notifications; svp[I notifications]; I notification_inbox]; svp[S notification_inbox,notifications]; COMMIT; I mentions; ROLLBACK TO] → S pg_class,family,pg_inherits → S mentions → S notification_inbox → svp[S notification_inbox,notifications] → COMMIT | 15 | 32 | txn, 6 svp | inside PostingWorkflow::create_reply |
| `Service::Community::Workflow::create_report` | hot write | BEGIN → S command_log → svp[I command_log] → S reports → svp[I reports; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → U command_log → COMMIT | 12 | 24 | txn, advisory, 5 svp | `api.community_create_report_v1` |
| `Service::Community::Workflow::save_bookmark` | hot write | BEGIN → S command_log → svp[I command_log] → S bookmarks → svp[I bookmarks] → U command_log → COMMIT | 5 | 11 | txn, 2 svp | `api.community_save_bookmark_v1` |
| `Service::Community::Workflow::save_subscription` | hot write | BEGIN → S command_log → svp[I command_log] → S subscriptions → svp[I subscriptions] → U command_log → COMMIT | 5 | 11 | txn, 2 svp | `api.community_save_subscription_v1` |
| `Service::Community::FeedProjector::project_item` | async | BEGIN → I user_feed_items ON CONFLICT SELECT → COMMIT | 1 | 3 | txn | `api.community_project_item_v1` |
| `Service::Community::FeedProjector::remove_item` | async | BEGIN → D user_feed_items → COMMIT | 1 | 3 | txn | `api.community_remove_item_v1` |
| `Service::Community::FeedProjector::remove_thread` | async | BEGIN → D user_feed_items ×2 → COMMIT | 2 | 4 | txn | `api.community_remove_thread_v1` |
| `Service::Community::ReputationLedger::record_event` | async | BEGIN → S reputation_events → svp[BEGIN; S reputation_events; svp[I reputation_events; S trust_score_snapshots FU; U trust_score_snapshots; S users]; COMMIT; I reputation_events; ROLLBACK TO] → S pg_class,family,pg_inherits → S reputation_events → S trust_score_snapshots FU → S trust_score_snapshots → COMMIT | 11 | 20 | txn, FU, 2 svp | `api.community_record_event_v1` |

### Notifications

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Notification::Dispatcher::list_for_user` | hot read | S suspensions,role_bindings,role_permissions,permissions,users → S posts,threads,notification_inbox,notifications,categories,spaces | 2 | 2 | autocommit | `api.notification_list_for_user_v1` |
| `Service::Notification::Dispatcher::list_page_for_user` | hot read | S suspensions,role_bindings,role_permissions,permissions,users → S posts,threads,notification_inbox,notifications,categories,spaces | 2 | 2 | autocommit | `api.notification_list_page_for_user_v1` |
| `Service::Notification::Dispatcher::unread_count_for_user` | hot read | S notification_inbox,notifications,posts,threads,categories,spaces | 1 | 1 | autocommit | `api.notification_unread_count_for_user_v1` |
| `Service::Notification::PreferenceStore::preferences_for_user` | hot read | S notification_preferences | 1 | 1 | autocommit | inside PostingWorkflow::create_reply |
| `Service::Notification::SubscriptionStore::status_for_user_target` | hot read | S subscriptions | 1 | 1 | autocommit | `api.notification_status_for_user_target_v1` |
| `Service::Notification::Dispatcher::create_notification` | hot write | S posts,threads,categories,spaces → BEGIN → S notification_inbox → svp[S notifications; svp[I notifications]; I notification_inbox] → COMMIT → S suspensions,role_bindings,role_permissions,permissions,users → S notification_inbox,notifications,posts,threads,categories,spaces | 7 | 13 | txn, 2 svp | `api.notification_create_notification_v1` |
| `Service::Notification::Dispatcher::fanout_to_subscribers` | hot write | S subscriptions → S posts,threads,categories,spaces → BEGIN → S notification_inbox → svp[S notifications; svp[I notifications]; I notification_inbox] → COMMIT → S suspensions,role_bindings,role_permissions,permissions,users → S notification_inbox,notifications,posts,threads,categories,spaces | 8 | 14 | txn, 2 svp | `api.notification_fanout_to_subscribers_v1` |
| `Service::Notification::Dispatcher::mark_all_read` | hot write | BEGIN → S suspensions,role_bindings,role_permissions,permissions,users → S notification_inbox,notifications,posts,threads,categories,spaces → svp[I notification_reads] → U notification_inbox → svp[I notification_reads] → U notification_inbox → svp[I notification_reads] → U notification_inbox → COMMIT → S suspensions,role_bindings,role_permissions,permissions,users → S notification_inbox,notifications,posts,threads,ca … | 10 | 18 | txn, 3 svp | `api.notification_mark_all_read_v1` |
| `Service::Notification::Dispatcher::mark_read` | hot write | BEGIN → S notification_inbox → svp[I notification_reads] → U notification_inbox → COMMIT → S suspensions,role_bindings,role_permissions,permissions,users → S notification_inbox,notifications,posts,threads,categories,spaces | 5 | 9 | txn, 1 svp | `api.notification_mark_read_v1` |
| `Service::Notification::SubscriptionStore::find_for_user_target` | hot write | S subscriptions | 1 | 1 | autocommit | inside Workflow::save_subscription |
| `Service::Notification::SubscriptionStore::mute` | hot write | S subscriptions → U subscriptions | 2 | 2 | autocommit | `api.notification_mute_v1` |
| `Service::Notification::SubscriptionStore::mute_for_user_target` | hot write | S subscriptions → U subscriptions | 2 | 2 | autocommit | `api.notification_mute_for_user_target_v1` |
| `Service::Notification::SubscriptionStore::revoke` | hot write | S subscriptions → U subscriptions | 2 | 2 | autocommit | `api.notification_revoke_v1` |
| `Service::Notification::SubscriptionStore::revoke_for_user_target` | hot write | S subscriptions → U subscriptions | 2 | 2 | autocommit | `api.notification_revoke_for_user_target_v1` |
| `Service::Notification::SubscriptionStore::save_subscription` | hot write | S subscriptions → U subscriptions | 2 | 2 | autocommit | inside Workflow::save_subscription |
| `Service::Notification::SubscriptionStore::subscribe` | hot write | I subscriptions | 1 | 1 | autocommit | inside Workflow::save_subscription |
| `Service::Notification::SubscriptionStore::subscribers_for` | hot write | S subscriptions | 1 | 1 | autocommit | inside NotificationDispatch::handle |
| `Service::Notification::Dispatcher::inbox_resultset` | cold | S suspensions,role_bindings,role_permissions,permissions,users | 1 | 1 | autocommit | last wave (cold) |
| `Service::Notification::PreferenceStore::channel_enabled` | cold | S notification_preferences | 1 | 1 | autocommit | last wave (cold) |
| `Service::Notification::PreferenceStore::enabled_channels` | cold | S notification_preferences | 1 | 1 | autocommit | last wave (cold) |
| `Service::Notification::PreferenceStore::set_preference` | cold | S notification_preferences → I notification_preferences | 2 | 2 | autocommit | last wave (cold) |
| `Service::Notification::PreferenceStore::set_preferences` | cold | S notification_preferences → I notification_preferences → S notification_preferences ×2 → U notification_preferences → S notification_preferences → I notification_preferences → S notification_preferences | 8 | 8 | autocommit | last wave (cold) |
| `Service::Notification::RecipientPolicy::can_notify` | cold | S threads,categories,spaces → S suspensions,role_bindings,role_permissions,permissions,users | 2 | 2 | autocommit | last wave (cold) |

### Attachments

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Attachment::Store::attachments_for_posts` | hot read | S attachment_links | 1 | 1 | autocommit | `api.attachment_attachments_for_posts_v1` |
| `Worker::Handler::AttachmentScanning::handle` | async | S attachments → BEGIN → S attachments → U attachments → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → COMMIT | 8 | 14 | txn, advisory, 2 svp | `api.attachment_handle_v1` |
| `Worker::Handler::MediaProcessing::handle` | async | S attachments → S attachment_variants | 2 | 2 | autocommit | `api.attachment_handle_v1` |
| `Service::Attachment::Delivery::download` | cold | S attachments → S attachment_links → S posts | 3 | 3 | autocommit | last wave (cold) |
| `Service::Attachment::MediaProcessor::process` | cold | S attachments → S attachment_variants ×3 → I attachment_variants | 5 | 5 | autocommit | last wave (cold) |
| `Service::Attachment::Store::add_variant` | cold | S attachment_variants ×2 → I attachment_variants | 3 | 3 | autocommit | last wave (cold) |
| `Service::Attachment::Store::cleanup_orphans` | cold | S attachments,attachment_links → BEGIN → S attachments FU → S attachment_links → S attachment_variants → U attachments → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 13 | 21 | txn, FU, advisory, 3 svp | last wave (cold) |
| `Service::Attachment::Store::confirm_clean` | cold | U attachments | 1 | 1 | autocommit | last wave (cold) |
| `Service::Attachment::Store::create_intent` | cold | BEGIN → S attachments → svp[I attachments; S pg_advisory_xact_lock +advisory; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT | 10 | 20 | txn, advisory, 4 svp | last wave (cold) |
| `Service::Attachment::Store::delete_linked` | cold | S attachment_links → BEGIN → S attachments → U attachments → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 11 | 19 | txn, advisory, 3 svp | last wave (cold) |
| `Service::Attachment::Store::download_for` | cold | S attachments → S attachment_links → S posts → S posts,threads,categories,spaces | 4 | 4 | autocommit | last wave (cold) |
| `Service::Attachment::Store::find_attachment` | cold | S attachments | 1 | 1 | autocommit | last wave (cold) |
| `Service::Attachment::Store::link_attachment` | cold | S attachment_links → I attachment_links | 2 | 2 | autocommit | last wave (cold) |
| `Service::Attachment::Store::mark_uploaded` | cold | S attachments → U attachments | 2 | 2 | autocommit | last wave (cold) |
| `Service::Attachment::Store::pending_scan_ids` | cold | S attachments | 1 | 1 | autocommit | last wave (cold) |
| `Service::Attachment::Store::record_scan` | cold | BEGIN → S attachments → U attachments → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → COMMIT | 7 | 13 | txn, advisory, 2 svp | last wave (cold) |
| `Service::Attachment::Store::record_scan_failure` | cold | S attachments → U attachments | 2 | 2 | autocommit | last wave (cold) |
| `Service::Attachment::Store::soft_delete` | cold | BEGIN → S attachments → U attachments → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 10 | 18 | txn, advisory, 3 svp | last wave (cold) |
| `Service::Attachment::Store::unscanned_clean_ids` | cold | S attachments | 1 | 1 | autocommit | last wave (cold) |
| `Service::Attachment::UploadPipeline::upload_and_link` | cold | BEGIN → S attachments → svp[I attachments; S pg_advisory_xact_lock +advisory; S event_log; svp[I event_log]; S outbox_messages; svp[I outbox_messages]; S pg_advisory_xact_lock +advisory; svp[S audit_log; I audit_log]] → COMMIT → S attachments → U attachments → BEGIN → S attachments → U attachments → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → COMMI … | 21 | 37 | txn, advisory, 6 svp | last wave (cold) |
| `Service::Attachment::Workflow::download` | cold | S attachments | 1 | 1 | autocommit | last wave (cold) |

### Search

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Search::Searcher::autocomplete` | hot read | BEGIN → S set_config → S search_documents,users,categories,spaces,threads,posts → COMMIT | 2 | 4 | txn | `api.search_autocomplete_v1` |
| `Service::Search::Searcher::ranked_search` | hot read | BEGIN → S set_config → S posts,threads,search_documents,categories,spaces,users → COMMIT | 2 | 4 | txn | `api.search_ranked_search_v1` |
| `Service::Search::Searcher::search` | hot read | BEGIN → S set_config → S posts,threads,search_documents,categories,spaces,users → COMMIT | 2 | 4 | txn | `api.search_search_v1` |
| `Service::Search::Indexer::index_post` | async | BEGIN → S pg_advisory_xact_lock +advisory → S posts → S threads → S post_bodies → S categories → S search_documents → svp[I search_documents] → COMMIT | 7 | 11 | txn, advisory, 1 svp | inside SearchIndexing::handle |
| `Service::Search::Indexer::index_thread` | async | BEGIN → S pg_advisory_xact_lock +advisory → S threads → S categories → S search_documents ×2 → U search_documents → COMMIT | 6 | 8 | txn, advisory | inside SearchIndexing::handle |
| `Service::Search::Indexer::index_thread_posts` | async | S posts → BEGIN → S pg_advisory_xact_lock +advisory → S posts → S threads → S post_bodies → S categories → S search_documents → svp[I search_documents] → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S posts → S threads → S post_bodies → S categories → S search_documents → svp[I search_documents] → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S posts → S threads → S post_bodies → S categories → S searc … | 87 | 135 | txn, advisory, 12 svp | `api.search_index_thread_posts_v1` |
| `Service::Search::Indexer::observe_lag` | async | S now,outbox_messages | 1 | 1 | autocommit | inside SearchRebuild::run |
| `Service::Search::Indexer::rebuild` | async | S threads → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S categories → S search_documents ×2 → U search_documents → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S categories → S search_documents ×2 → U search_documents → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S categories → S search_documents ×2 → U search_documents → COMMIT → BEGIN → S pg_advisory_xact_lock + … | 748 | 1156 | txn, advisory, 96 svp | `api.search_rebuild_v1` |
| `Service::Search::Indexer::remove_thread` | async | BEGIN → S pg_advisory_xact_lock +advisory → S threads → S pg_advisory_xact_lock +advisory → S pg_locks,posts → D search_documents → COMMIT → S posts → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S pg_locks,posts → D search_documents → COMMIT → S posts → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S pg_locks,posts → D search_documents → COMMIT → S posts → BEGIN → S pg_advisory_xact_lock +adviso … | 20 | 28 | txn, advisory | `api.search_remove_thread_v1` |
| `Service::Search::RebuildRun::step` | async | S threads → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S categories → S search_documents → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S categories → S search_documents → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S categories → S search_documents → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S threads → S categories → S search_documents → COMMIT → BEGI … | 26 | 42 | txn, advisory, 2 svp | `api.search_step_v1` |
| `Worker::Handler::SearchIndexing::handle` | async | S posts,threads → BEGIN → S pg_advisory_xact_lock +advisory → S posts → S threads → S post_bodies → S categories → S search_documents → svp[I search_documents] → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S posts → S threads → S post_bodies → S categories → S search_documents → svp[I search_documents] → COMMIT → BEGIN → S pg_advisory_xact_lock +advisory → S posts → S threads → S post_bodies → S categories → … | 41 | 67 | txn, advisory, 7 svp | `api.search_handle_v1` |
| `Command::SearchRebuild::run` | cold | S now,outbox_messages | 1 | 1 | autocommit | last wave (cold) |
| `Service::Search::RebuildRun::latest` | cold | S event_log | 1 | 1 | autocommit | last wave (cold) |
| `Service::Search::RebuildRun::request` | cold | S event_log ×2 → svp[I event_log] → S outbox_messages → svp[I outbox_messages] | 5 | 9 | autocommit, 2 svp | last wave (cold) |

### Outbox and workers

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Outbox::DeadLetterReplay::replay` | async | BEGIN → S dead_letters FU → S audit_log → I outbox_messages → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 6 | 10 | txn, FU, advisory, 1 svp | `api.outbox_replay_v1` |
| `Service::Outbox::Dispatcher::claim_ready_batch` | async | BEGIN → CTE U:SKIP+U:outbox_messages FU+skip → COMMIT | 1 | 3 | txn, FU+skip | `api.outbox_claim_ready_batch_v1` |
| `Service::Outbox::Dispatcher::dispatch_pending` | async | BEGIN → CTE U:SKIP+U:outbox_messages FU+skip → COMMIT → U outbox_messages ×2 | 3 | 5 | txn, FU+skip | `api.outbox_dispatch_pending_v1` |
| `Service::Outbox::DomainEventTransport::dispatch` | async | S event_idempotency_keys → I event_idempotency_keys → S event_idempotency_keys → U event_idempotency_keys | 4 | 4 | autocommit | `api.outbox_dispatch_v1` |
| `Service::Realtime::ChannelAuthorizer::authorize` | async | S users → S suspensions → S users → S threads,categories,spaces → S suspensions,role_bindings,role_permissions,permissions,users | 5 | 5 | autocommit | `api.outbox_authorize_v1` |
| `Service::Realtime::Hub::broadcast` | async | S threads,categories,spaces → S suspensions,role_bindings,role_permissions,permissions,users | 2 | 2 | autocommit | `api.outbox_broadcast_v1` |
| `Service::Realtime::Hub::subscribe` | async | S users → S suspensions → S users → S threads,categories,spaces → S suspensions,role_bindings,role_permissions,permissions,users | 5 | 5 | autocommit | `api.outbox_subscribe_v1` |
| `Service::Realtime::PgListener::poll_once` | async | S outbox_messages | 1 | 1 | autocommit | `api.outbox_poll_once_v1` |
| `Service::Realtime::PgListener::start` | async | LISTEN "gpforum_domain_events" | 1 | 1 | autocommit | `api.outbox_start_v1` |
| `Worker::EventIdempotencyStore::is_done` | async | S event_idempotency_keys | 1 | 1 | autocommit | `api.outbox_is_done_v1` |
| `Worker::EventIdempotencyStore::mark_done` | async | S event_idempotency_keys → I event_idempotency_keys | 2 | 2 | autocommit | `api.outbox_mark_done_v1` |
| `Worker::Handler::NotificationDispatch::handle` | async | S subscriptions → S posts,threads,categories,spaces → BEGIN → S notification_inbox → svp[S notifications; svp[I notifications]; I notification_inbox] → COMMIT → S suspensions,role_bindings,role_permissions,permissions,users → S notification_inbox,notifications,posts,threads,categories,spaces | 8 | 14 | txn, 2 svp | `api.outbox_handle_v1` |
| `Worker::Handler::ThreadActivity::handle` | async | U threads | 1 | 1 | autocommit | `api.outbox_handle_v1` |
| `Command::DeadLetterReplay::run` | cold | BEGIN → S dead_letters FU → S audit_log → I outbox_messages → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 6 | 10 | txn, FU, advisory, 1 svp | last wave (cold) |

### Query budgets and plans

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Command::QueryBudget::run` | cold | S endpoint_query_budgets | 1 | 1 | autocommit | last wave (cold) |
| `Command::QueryPlanEvidence::evidence_report` | cold | BEGIN → EXPLAIN (ANALYZE, → SET LOCAL → EXPLAIN (FORMAT → ROLLBACK → S threads,ranked → BEGIN → EXPLAIN (ANALYZE, ×2 → SET LOCAL → EXPLAIN (FORMAT → ROLLBACK → S pg_class,pg_stat_user_tables ×2 → BEGIN → EXPLAIN (ANALYZE, → SET LOCAL → EXPLAIN (FORMAT → ROLLBACK → S pg_class,pg_stat_user_tables → S threads,largest,ranked,categories → BEGIN → EXPLAIN (ANALYZE, ×2 → SET LOCAL → EXPLAIN (FORMAT → ROLLBACK → S pg_class,p … | 40 | 56 | txn | last wave (cold) |
| `Service::Operations::QueryBudget::drift_report` | cold | S endpoint_query_budgets | 1 | 1 | autocommit | last wave (cold) |

### Partitions

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Command::PartitionMaintenance::run` | cold | S to_regclass ×12 | 12 | 12 | autocommit | last wave (cold) |
| `Service::Operations::PartitionLifecycle::ensure_partitions` | cold | S pg_try_advisory_lock +advisory → S to_regclass ×2 → S audit_log_default → BEGIN → CREATE TABLE → ALTER TABLE → I partition_registry ON CONFLICT → COMMIT → S to_regclass ×2 → S event_log_default → BEGIN → CREATE TABLE → ALTER TABLE → I partition_registry ON CONFLICT → COMMIT → S to_regclass ×2 → S notifications_default → BEGIN → CREATE TABLE → ALTER TABLE → I partition_registry ON CONFLICT → COMMIT → S to_regclass × … | 56 | 74 | txn, advisory | last wave (cold) |
| `Service::Operations::PartitionLifecycle::horizon_report` | cold | S max,pg_inherits,pg_class,pg_namespace → S ONLY ×3 | 4 | 4 | autocommit | last wave (cold) |

### Operations, readiness, metrics

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Service::Operations::RateLimiter::check` | hot read | I rate_limit_buckets ON CONFLICT | 1 | 1 | autocommit | `api.ops_check_v1` |
| `Service::Operations::CommandIdempotency::run` | hot write | BEGIN → S command_log → svp[I command_log; ROLLBACK TO] → S pg_class,family,pg_inherits → S command_log → COMMIT | 4 | 9 | txn, 1 svp | `api.ops_run_v1` |
| `Service::Operations::CacheInvalidationBus::drain` | cold | LISTEN "gpforum_cache_invalidation" → LISTEN "gpforum_domain_events" | 2 | 2 | autocommit | last wave (cold) |
| `Service::Operations::DatabaseProvisioning::inspect` | cold | S pg_roles ×2 → S pg_database | 3 | 3 | autocommit | last wave (cold) |
| `Service::Operations::DatabaseProvisioning::provision` | cold | S pg_roles ×2 → S pg_database → CREATE DATABASE | 4 | 4 | autocommit | last wave (cold) |
| `Service::Operations::Doctor::check` | cold | SHOW server_version → S schema_versions ×2 → S endpoint_query_budgets → S 1 → S event_log → S outbox_messages → S projection_generations → S endpoint_query_budgets ×2 → S max,pg_inherits,pg_class,pg_namespace → S ONLY ×3 → S pg_is_in_recovery → S replay_lag,pg_stat_replication → S pg_replication_slots → S now,outbox_messages ×2 | 19 | 19 | autocommit | last wave (cold) |
| `Service::Operations::MetricsSnapshot::collect` | cold | S rate_limit_buckets → S endpoint_query_budgets → S 1 → S outbox_messages ×2 → S dead_letters → S pg_is_in_recovery → S replay_lag,pg_stat_replication → S pg_replication_slots | 9 | 9 | autocommit | last wave (cold) |
| `Service::Operations::Readiness::check` | cold | S 1 → S event_log → S outbox_messages → S projection_generations → S endpoint_query_budgets ×2 → S max,pg_inherits,pg_class,pg_namespace → S ONLY ×3 → S pg_is_in_recovery → S replay_lag,pg_stat_replication → S pg_replication_slots | 13 | 13 | autocommit | last wave (cold) |
| `Service::Operations::Replication::snapshot` | cold | S pg_is_in_recovery → S replay_lag,pg_stat_replication → S pg_replication_slots | 3 | 3 | autocommit | last wave (cold) |
| `Service::Operations::ScheduledJobs::run` | cold | S sessions → D sessions ×5 → S identity_tokens → S rate_limit_buckets → S outbox_messages → S dead_letters | 10 | 10 | autocommit | last wave (cold) |
| `Service::Operations::ScheduledJobs::run_job` | cold | S identity_tokens | 1 | 1 | autocommit | last wave (cold) |
| `Service::Operations::StagingDrill::run` | cold | CREATE DATABASE → S pg_advisory_lock +advisory → S schema_versions ×2 → -- SPDX-FileCopyrightText: → I schema_versions → -- SPDX-FileCopyrightText: → I schema_versions → -- SPDX-FileCopyrightText: → I schema_versions → -- SPDX-FileCopyrightText: → I schema_versions → I migration_safety → -- SPDX-FileCopyrightText: → I schema_versions → I migration_safety → -- SPDX-FileCopyrightText: → I schema_versions → I migration_ … | 442 | 442 | autocommit, advisory | last wave (cold) |
| `Service::Operations::TieredCache::get` | cold | LISTEN "gpforum_cache_invalidation" | 1 | 1 | autocommit | last wave (cold) |
| `Service::Operations::TieredCache::invalidate_tag` | cold | S pg_notify | 1 | 1 | autocommit | last wave (cold) |

### Commands and migrations

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Command::Migrate::run` | cold | S pg_advisory_lock +advisory → S schema_versions ×2 → S pg_advisory_unlock → S pg_advisory_lock +advisory → S to_regclass → I partition_registry ON CONFLICT → S to_regclass → I partition_registry ON CONFLICT → S to_regclass → I partition_registry ON CONFLICT → S to_regclass → I partition_registry ON CONFLICT → S to_regclass → I partition_registry ON CONFLICT → S to_regclass → I partition_registry ON CONFLICT → S to_r … | 38 | 44 | txn, advisory | last wave (cold) |
| `Command::PerformanceSeed::run` | cold | S to_regclass ×12 → BEGIN → SET CONSTRAINTS → D moderation_actions → D reports → D notification_inbox → D notifications → D user_feed_items → D subscriptions → D bookmarks → D user_read_marker_deltas → D thread_read_state → D thread_counters → D search_documents → D post_revisions → D post_bodies → D posts → D threads → D category_stats → D categories → D role_bindings → D sessions → D users → D spaces → I spaces ON  … | 593 | 595 | txn | last wave (cold) |
| `Command::ScheduledJobs::run` | cold | S attachments,attachment_links → BEGIN → S attachments FU → S attachment_links → S attachment_variants → U attachments → S pg_advisory_xact_lock +advisory → S event_log → svp[I event_log] → S outbox_messages → svp[I outbox_messages] → S pg_advisory_xact_lock +advisory → svp[S audit_log; I audit_log] → COMMIT | 13 | 21 | txn, FU, advisory, 3 svp | last wave (cold) |
| `Command::Setup::run` | cold | S pg_roles → S current_user → S pg_roles → S pg_database → S pg_roles → S current_user → S pg_roles → S pg_database → CREATE ROLE → CREATE DATABASE → S pg_advisory_lock +advisory → S schema_versions ×2 → -- SPDX-FileCopyrightText: → I schema_versions → -- SPDX-FileCopyrightText: → I schema_versions → -- SPDX-FileCopyrightText: → I schema_versions → -- SPDX-FileCopyrightText: → I schema_versions → I migration_safety → … | 211 | 211 | autocommit, advisory | last wave (cold) |
| `Migration::Runner::apply_pending` | cold | S pg_advisory_lock +advisory → S schema_versions ×2 → S pg_advisory_unlock | 4 | 4 | autocommit, advisory | last wave (cold) |
| `Migration::Runner::verify_applied` | cold | S schema_versions | 1 | 1 | autocommit | last wave (cold) |

### Shared write steps

| Operation | Kind | Statements in order (success path) | Stmts | Round trips | Txn, locks | One function call |
| --- | --- | --- | --: | --: | --- | --- |
| `Infrastructure::EventRecorder::event_recorded` | hot write | S event_log | 1 | 1 | autocommit | inside SearchIndexing::handle |
| `Infrastructure::EventRecorder::record_audit` | hot write | S pg_advisory_xact_lock +advisory → S audit_log ×2 → BEGIN → I audit_log → COMMIT | 4 | 6 | txn, advisory | inside AdminBootstrap::run |
| `Infrastructure::EventRecorder::record_event` | hot write | S pg_advisory_xact_lock +advisory → S event_log → BEGIN → I event_log → COMMIT → S outbox_messages → BEGIN → I outbox_messages → COMMIT | 5 | 9 | txn, advisory | inside SearchIndexing::handle |
| `Infrastructure::PreparedQuery::row` | cold | S categories,spaces | 1 | 1 | autocommit | last wave (cold) |
| `Infrastructure::UniqueConflict::attempt` | cold | svp[svp[I categories; ROLLBACK TO]; I categories; ROLLBACK TO] | 2 | 8 | autocommit, 2 svp | last wave (cold) |
| `Infrastructure::UniqueConflict::is_conflict_on` | cold | S pg_class,family,pg_inherits | 1 | 1 | autocommit | last wave (cold) |

## Not driven by the suite

Public subs that reach the database but were never the outermost call of a
traced operation. *(inner)* marks those that ran inside another operation,
so their statements are in that operation's row; the others ran in no
integration test (unit tests with doubles drive them) and phase 1 captures
their SQL from a test written for the capture.

- **Forum reads**: `Service::Forum::PostReader::find_post`, `Service::Forum::Readability::readable_by` (inner)
- **Forum writes**: `Service::Forum::PostPosition::read_next_position`, `Service::Forum::PostingWorkflow::edit_thread`, `Service::Forum::PostingWorkflow::move_thread`
- **Sessions**: `Service::Identity::SessionStore::revoke_session` (inner), `Service::Identity::SessionStore::revoke_user_sessions` (inner)
- **Identity**: `Service::Identity::AccountStore::change_password` (inner), `Service::Identity::AccountStore::confirm_email_change` (inner), `Service::Identity::AccountStore::confirm_email_verification` (inner), `Service::Identity::AccountStore::request_email_change` (inner), `Service::Identity::AccountStore::request_email_verification` (inner), `Service::Identity::AccountStore::request_password_reset` (inner), `Service::Identity::AccountStore::reset_password` (inner), `Service::Identity::Audit::record_action` (inner), `Service::Identity::Audit::record_mail` (inner), `Service::Identity::Audit::record_registration` (inner), `Service::Identity::CredentialStore::active_password_credential` (inner), `Service::Identity::CredentialStore::hold_active_password_credential` (inner), `Service::Identity::CredentialStore::lock_active_password_credentials` (inner), `Service::Identity::CredentialStore::rotate_password_credential` (inner), `Service::Identity::Mailer::send_email_change`, `Service::Identity::Mailer::send_email_verification`, `Service::Identity::Mailer::send_password_reset`, `Service::Identity::Mailer::send_test_message`, `Service::Identity::PreferenceStore::preferred_locale_for_user` (inner), `Service::Identity::PreferenceStore::preferred_theme_for_user` (inner), `Service::Identity::PreferenceStore::update_preferred_locale` (inner), `Service::Identity::PreferenceStore::update_preferred_theme` (inner), `Service::Identity::RegistrationStore::create_registration` (inner)
- **Admin**: `Service::Admin::Bootstrapper::bootstrap` (inner), `Service::Admin::Bootstrapper::check_owner` (inner), `Service::Admin::Bootstrapper::find_member` (inner), `Service::Admin::Bootstrapper::is_owner` (inner), `Service::Admin::ConsoleReader::count_dead_letters` (inner), `Service::Admin::ConsoleReader::count_outbox` (inner), `Service::Admin::ConsoleReader::dashboard_summary`, `Service::Admin::ConsoleReader::list_outbox` (inner), `Service::Admin::ConsoleReader::list_reports`, `Service::Admin::ConsoleReader::list_users`, `Service::Admin::Diagnostics::check_antivirus` (inner), `Service::Admin::Diagnostics::send_test_mail` (inner)
- **Privacy and portability**: `Service::Portability::ImportJobStore::create_job`, `Service::Portability::ImportJobStore::record_failure`, `Service::Portability::ImportJobStore::update_progress`, `Service::Portability::LegacyIdMapper::find_native`, `Service::Portability::LegacyIdMapper::map_identifier`, `Service::Privacy::ErasedExports::discard` (inner), `Service::Privacy::ErasedExports::may_export` (inner)
- **Community**: `Service::Community::Workflow::mute_subscription`, `Service::Community::Workflow::remove_bookmark`, `Service::Community::Workflow::revoke_subscription`
- **Attachments**: `Service::Attachment::ScanQueue::confirm_clean` (inner), `Service::Attachment::ScanQueue::pending_scan_ids` (inner), `Service::Attachment::ScanQueue::record_scan_failure` (inner), `Service::Attachment::ScanQueue::unscanned_clean_ids` (inner), `Service::Attachment::Store::find_variant` (inner), `Service::Attachment::Workflow::delete_for_post`, `Service::Attachment::Workflow::upload_for_post`
- **Search**: `Service::Search::DocumentBuilder::build_post` (inner), `Service::Search::DocumentBuilder::build_thread` (inner), `Service::Search::Indexer::index_thread_posts_batch` (inner), `Service::Search::Indexer::rebuild_batch` (inner), `Service::Search::Indexer::remove_post`
- **Outbox and workers**: `Service::Outbox::DeadLetterRecorder::create_dead_letter` (inner), `Service::Outbox::Retry::next_attempt`, `Service::Plugin::FailureRecorder::record_failure`, `Service::Plugin::HookDispatcher::dispatch`, `Service::Plugin::Registry::disable`, `Service::Plugin::Registry::enable`, `Service::Plugin::Registry::install`, `Service::Projection::GenerationManager::activate_generation`, `Service::Projection::GenerationManager::mark_failed`, `Service::Projection::GenerationManager::mark_ready`, `Service::Projection::GenerationManager::start_generation`, `Service::Projection::OffsetTracker::mark_failed`, `Service::Projection::OffsetTracker::observe_lag`, `Service::Projection::OffsetTracker::record_progress`, `Service::Realtime::Hub::connection_count`, `Service::Realtime::PgListener::reconnect`, `Service::Realtime::PgNotifier::notify` (inner), `Service::Realtime::SubscriptionPolicy::permits` (inner), `Worker::EventIdempotencyStore::begin` (inner), `Worker::EventIdempotencyStore::mark_failed`, `Worker::Handler::FeedProjection::handle`, `Worker::Handler::ReputationUpdate::handle`
- **Query budgets and plans**: `Command::QueryPlanEvidence::run`, `Service::Operations::QueryBudget::sync_schema` (inner)
- **Partitions**: `Service::Operations::PartitionLifecycle::unmigrated_tables` (inner)
- **Operations, readiness, metrics**: `Service::Operations::BatchPurge::delete_row` (inner), `Service::Operations::BatchPurge::delete_rows` (inner), `Service::Operations::CacheInvalidationBus::publish` (inner), `Service::Operations::CommandIdempotency::result_of` (inner), `Service::Operations::DeadLetterCheck::run`, `Service::Operations::DeadLetterCheck::ProbeTransport::dispatch`, `Service::Operations::RateLimiter::PostgreSQLStore::check` (inner), `Service::Operations::RateLimiter::PostgreSQLStore::snapshot` (inner), `Service::Operations::RetentionStore::purge_dead_letters` (inner), `Service::Operations::RetentionStore::purge_identity_tokens` (inner), `Service::Operations::RetentionStore::purge_outbox_messages` (inner), `Service::Operations::RetentionStore::purge_rate_limit_buckets` (inner), `Service::Operations::RetentionStore::purge_sessions` (inner), `Service::Operations::ScheduledJobs::partition_evidence` (inner)
- **Commands and migrations**: `Benchmark::PlanRules::depth_evidence`, `Benchmark::PlanRules::relation_size` (inner), `Benchmark::PlanRules::small_table_scans_are_warnings`, `Benchmark::QueryPlanEndpoints::read_deep_page`, `Benchmark::SeedDataset::insert_dataset`, `Command::HypnotoadBenchmark::benchmark_report`, `Command::HypnotoadBenchmark::run`, `Command::PerformanceSeed::seed` (inner), `Command::PerformanceSeed::seed_profile`, `Migration::Runner::applied_versions` (inner), `Migration::Runner::apply_migration` (inner), `Migration::Runner::pending` (inner), `Migration::Runner::recorded_checksums` (inner)
- **Shared write steps**: `Infrastructure::CountedQuery::select_row` (inner), `Infrastructure::PgNotifications::listen_to` (inner), `Infrastructure::PgNotifications::take` (inner), `Infrastructure::PgNotifications::unlisten`

## Limits

- The success path of each row is what the suite drove most often. Refusal
  paths, replays and conflict recovery send fewer or other statements; the
  traces hold all of them, and the differential tests of phase 1 cover each.
- Bound values were not recorded here. The statements are DBIx::Class's
  own text, with `?` where it binds; the constants it binds (visibility
  levels, moderation states) are read in phase 1, with the values.
- Some stores are driven by their tests with a transaction of their own
  (`EventRecorder::record_event` alone opens one); in production they run
  in their caller's transaction, as the workflow rows show.
- The benchmark runs the server and the client in one process over
  loopback; a real client adds the network, the same for both paths.
