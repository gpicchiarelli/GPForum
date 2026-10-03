# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use POSIX         qw(_exit);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostStore;
use GPForum::Service::Forum::ThreadComposer;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Service::Operations::CacheInvalidationBus;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::TieredCache;
use GPForum::Migration::Runner;
use GPForum::Service::Identity::Store;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Test::PostgresHarness;
use GPForum::Worker::EventIdempotencyStore;

our $VERSION = '0.001';

const my $TOKEN_TTL       => 3_600;
const my $LOCK_TIMEOUT_MS => 10_000;
const my $IDLE_TIMEOUT_MS => 30_000;
const my $SEED_USER_SQL   => 'SELECT id FROM users ORDER BY username LIMIT 2';
const my $SEED_POST_SQL => join q{ },
  'SELECT post_id FROM posts',
  q{WHERE deleted_at IS NULL AND moderation_state = 'visible'},
  'ORDER BY post_id DESC LIMIT 1';
const my $SEED_THREAD_SQL => join q{ },
  'SELECT thread_id, visibility FROM threads',
  'WHERE deleted_at IS NULL AND locked_at IS NULL',
  q{AND moderation_state = 'visible'},
  'ORDER BY thread_id LIMIT 1';
const my $OTHER_AUTHOR_THREAD_SQL => join q{ },
  'SELECT thread_id, author_user_id, category_id, visibility FROM threads',
  'WHERE deleted_at IS NULL AND locked_at IS NULL',
  q{AND moderation_state = 'visible'},
  'AND thread_id <> ? AND author_user_id <> ?',
  'ORDER BY thread_id LIMIT 1';
const my $HOLD_THREAD_SQL =>
  'SELECT 1 FROM threads WHERE thread_id = ? FOR NO KEY UPDATE';
const my $HOLD_THREAD_NOWAIT_SQL => "$HOLD_THREAD_SQL NOWAIT";
const my $LOCK_WAITERS_SQL => join q{ },
  'SELECT count(*) FROM pg_stat_activity',
  q{WHERE datname = current_database() AND wait_event_type = 'Lock'};
const my $REPLY_RACERS => 4;
const my $CLEAR_READ_SQL =>
  'DELETE FROM thread_read_state WHERE user_id = ? AND thread_id = ?';
const my $LAST_POSITION_SQL =>
  'SELECT COALESCE(MAX(position), 0) FROM posts WHERE thread_id = ?';
const my $POSITIONS_AFTER_SQL => join q{ },
  'SELECT position FROM posts',
  'WHERE thread_id = ? AND position > ? ORDER BY position';
const my $MARK_READ_SQL => join q{ },
  'INSERT INTO thread_read_state (user_id, thread_id, last_read_position)',
  'VALUES (?, ?, 1)';
const my $BLOCKED_ON_SQL => join q{ },
  'SELECT count(*) FROM pg_stat_activity',
  'WHERE ? = ANY (pg_blocking_pids(pid))';
const my $ROW_WAIT_SQL => join q{ },
  'SELECT count(*) FROM pg_stat_activity',
  'WHERE ? = ANY (pg_blocking_pids(pid))',
  q{AND wait_event IN ('transactionid', 'tuple')};
const my $EDITABLE_POST_SQL => join q{ },
  'SELECT p.post_id, p.thread_id, p.author_user_id FROM posts p',
  'JOIN threads t ON t.thread_id = p.thread_id',
  'WHERE p.deleted_at IS NULL AND p.hidden_at IS NULL',
  q{AND p.moderation_state = 'visible'},
  'AND t.deleted_at IS NULL AND t.locked_at IS NULL',
  q{AND t.moderation_state = 'visible'},
  'ORDER BY p.post_id LIMIT 1';
const my $EDITABLE_THREAD_SQL => join q{ },
  'SELECT thread_id, author_user_id, category_id FROM threads',
  'WHERE deleted_at IS NULL AND locked_at IS NULL',
  q{AND moderation_state = 'visible'},
  'ORDER BY thread_id LIMIT 1';
const my $OTHER_CATEGORY_SQL => join q{ },
  'SELECT category_id FROM categories',
  'WHERE category_id <> ? AND deleted_at IS NULL',
  'ORDER BY category_id LIMIT 1';

# A moderator's write an author's thread delete, move or restore can queue
# behind (ActionStore's lock_thread or hide_thread), and the refusal it must
# then get: the workflow's own words.
const my @THREAD_MODERATION =>
  ( [ 'lock', 'thread is locked' ], [ 'hide', 'thread not found' ], );

# What an edit writes, and only that: the holder's own write may bump the
# row's version.
const my $POST_POINTERS_SQL => join q{ },
  'SELECT current_body_id, current_revision_id FROM posts',
  'WHERE post_id = ?';
const my $THREAD_TITLE_SQL =>
  'SELECT title, slug FROM threads WHERE thread_id = ?';
const my $POST_DELETION_SQL =>
  'SELECT deleted_at, deleted_by FROM posts WHERE post_id = ?';
const my $THREAD_WRITE_SQL => join q{ },
  'SELECT category_id, deleted_at, deleted_by FROM threads',
  'WHERE thread_id = ?';
const my $REPLY_COUNT_SQL => join q{ },
  'SELECT COALESCE(sum(reply_count_delta), 0) FROM thread_counter_shards',
  'WHERE thread_id = ?';
const my $BLOCK_POLLS          => 200;
const my $BLOCK_POLL_SECONDS   => 0.05;
const my $RACE_TARGET_ID       => '018f9999-0001-7000-8000-00000000c001';
const my $REPORT_TARGET_ID     => '018f9999-0001-7000-8000-00000000c002';
const my $COMMAND_KEY          => '018f9999-0001-7000-8000-00000000c010';
const my $HIDE_COMMAND         => '018f9999-0001-7000-8000-00000000c011';
const my $LOCK_COMMAND         => '018f9999-0001-7000-8000-00000000c012';
const my $DELETE_COMMAND       => '018f9999-0001-7000-8000-00000000c013';
const my $EDIT_LOCK_COMMAND    => '018f9999-0001-7000-8000-00000000c014';
const my $EDIT_HIDE_COMMAND    => '018f9999-0001-7000-8000-00000000c015';
const my $EDIT_DELETE_KEY      => '018f9999-0001-7000-8000-00000000c016';
const my $TITLE_LOCK_COMMAND   => '018f9999-0001-7000-8000-00000000c017';
const my $DELETE_LOCK_COMMAND  => '018f9999-0001-7000-8000-00000000c018';
const my $RESTORE_HIDE_COMMAND => '018f9999-0001-7000-8000-00000000c019';
const my $RESTORE_DELETE_KEY   => '018f9999-0001-7000-8000-00000000c01a';
const my $DELETE_RACE_KEY      => '018f9999-0001-7000-8000-00000000c01b';
const my $RESTORE_RACE_KEY     => '018f9999-0001-7000-8000-00000000c01c';
const my $EVENT_IDEM_KEY =>
  'worker.notify:018f9999-0001-7000-8000-00000000c020';
const my $EVENT_IDEM_EVENT     => '018f9999-0001-7000-8000-00000000c020';
const my $AUDIT_CORR_BASE      => 0xc100;
const my $SAVEPOINT_SLUG       => 'savepoint-balance-probe';
const my $SAVEPOINT_ID_FORMAT  => '018f9999-0001-7000-8000-%012d';
const my $SAVEPOINT_POSITION   => 9_000;
const my $SAVEPOINT_CREATED_AT => '2026-09-22T00:00:00Z';
const my $CACHE_KEY            => 'public:/t/cache-probe';
const my $CACHE_TAG            => 'thread:cache-probe';
const my $CACHE_VALUE          => '<p>cached body</p>';
const my $CACHE_TTL            => 300;
const my $MIGRATION_LOCK_KEY   => 4_021_970_001;
const my $LOCK_SQL             => 'SELECT pg_advisory_lock(?)';
const my $TRY_LOCK_SQL         => 'SELECT pg_try_advisory_lock(?)';
const my $UNLOCK_SQL           => 'SELECT pg_advisory_unlock(?)';

# This database only. Advisory locks are per database and pg_locks is per
# cluster, so counting every advisory lock reported another test file's
# migration, running in parallel against its own database, as a leak here.
const my $ADVISORY_COUNT_SQL => join q{ },
  q{SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'},
  'AND database = (SELECT oid FROM pg_database',
  'WHERE datname = current_database())';
const my $CHAIN_INDEX_SQL =>
  q{SELECT 1 FROM pg_indexes WHERE tablename = 'audit_log' }
  . q{AND indexname = 'idx_audit_log_chain_tip'};
const my $CHAIN_TIP_EXPLAIN_SQL =>
  q{EXPLAIN SELECT audit_id, record_hash FROM audit_log }
  . q{ORDER BY created_at DESC, audit_id DESC LIMIT 1};

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the PostgreSQL concurrency test';
}

local $ENV{GPFORUM_DATABASE_LOCK_TIMEOUT_MS} = $LOCK_TIMEOUT_MS;

# A holder sits idle in its transaction while the test polls for its waiter,
# up to BLOCK_POLLS * BLOCK_POLL_SECONDS. The default timeout would end it
# first, and a waiter that never queued would fail as a lost connection.
local $ENV{GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS} = $IDLE_TIMEOUT_MS;
local $ENV{GPFORUM_MINION_ENABLED}                          = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED}               = 0;

my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};

my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0,
    'migrations apply to a clean PostgreSQL database' );
is( $prepared->{seed}, 0, 'small seed profile loads' );

my $case = _load_context($database);
_audit_chain_race($case);
_command_log_race($case);
_bookmark_unique_race($case);
_subscription_unique_race($case);
_report_open_unique_race($case);
_moderation_hide_race($case);
_reply_position_race($case);
_reply_lock_allows_fk_inserts($case);
_reply_rechecks_lock($case);
_reply_rechecks_delete($case);
_edit_rechecks_thread_lock($case);
_edit_rechecks_post_hide($case);
_edit_rechecks_post_delete($case);
_title_edit_rechecks_lock($case);
_delete_rechecks_thread_lock($case);
_restore_rechecks_post_hide($case);
_thread_delete_rechecks_moderation($case);
_thread_move_rechecks_moderation($case);
_thread_restore_rechecks_moderation($case);
_privacy_approval_race($case);
_identity_token_consume_race($case);
_event_idempotency_race($case);
_nested_savepoint_balance();
_cache_invalidation_crosses_processes();
_migrations_serialise_and_verify();
_audit_chain_tip_uses_an_index();

GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

# UniqueConflict->attempt runs inside an open transaction, so it must leave the
# savepoint stack exactly as it found it. DBIx::Class's svp_rollback keeps the
# named savepoint on the stack on purpose, so a rollback that is not followed
# by a release leaks one subtransaction per conflict and makes a later release
# match the wrong entry. The in-memory doubles have no storage layer, so this
# is only observable against a real PostgreSQL.
sub _nested_savepoint_balance {
    my $schema  = GPForum::Test::PostgresHarness::connect_schema();
    my $storage = $schema->storage;
    my $rs      = $schema->resultset('Category');
    my $space   = $rs->first->get_column('space_id');

    my $depth_after_inner;
    my $inner_error;
    my $outer_error;

    $schema->txn_do(
        sub {
            $rs->create( _savepoint_category( $space, 1 ) );

            ( undef, $outer_error ) =
              GPForum::Infrastructure::UniqueConflict->attempt(
                $schema,
                sub {
                    ( undef, $inner_error ) =
                      GPForum::Infrastructure::UniqueConflict->attempt(
                        $schema,
                        sub {
                            return $rs->create(
                                _savepoint_category( $space, 2 ) );
                        }
                      );
                    $depth_after_inner = scalar @{ $storage->savepoints };

                    return $rs->create( _savepoint_category( $space, 3 ) );
                }
              );

            return 1;
        }
    );

    ok( $inner_error, 'the nested attempt observes its own unique conflict' );
    ok( $outer_error, 'the enclosing attempt observes its unique conflict' );
    is( $depth_after_inner, 1,
        'a nested attempt releases its savepoint and leaves only the outer one'
    );
    is( scalar @{ $storage->savepoints },
        0, 'a conflicting attempt leaves no savepoint behind' );
    is(
        $rs->search( { slug => $SAVEPOINT_SLUG } )->count,
        1,
        'the transaction commits with only the first row, after both rollbacks'
    );

    $rs->search( { slug => $SAVEPOINT_SLUG } )->delete;

    return;
}

sub _savepoint_category {
    my ( $space_id, $ordinal ) = @_;

    return {
        category_id => sprintf( $SAVEPOINT_ID_FORMAT, $ordinal ),
        space_id    => $space_id,
        slug        => $SAVEPOINT_SLUG,
        title       => 'savepoint balance',
        description => 'savepoint balance probe',
        position    => $SAVEPOINT_POSITION + $ordinal,
        created_at  => $SAVEPOINT_CREATED_AT,
    };
}

# Every Hypnotoad worker holds its own L1 and TieredCache::get short-circuits on
# it, so an invalidation raised in one worker used to leave the others serving
# the old entry until it expired: a moderator hid a post and the other workers
# kept rendering it.
#
# Two caches on two connections reproduce that exactly. PostgreSQL sees two
# backends, each cache has its own L1, and only the LISTEN/NOTIFY channel can
# carry the invalidation between them — which is the whole point of the fix. A
# process boundary would add nothing the second connection does not already
# provide, and forking inside the harness would share DBI handles.
sub _cache_invalidation_crosses_processes {

    # One shared L2, as in production, and a private L1 per cache, as in each
    # Hypnotoad worker. Only the notify channel can carry the invalidation from
    # one L1 to the other.
    my $shared = GPForum::Service::Operations::LocalCache->new(
        namespace => 'gpforum-shared' );
    my $peer   = _bus_backed_cache($shared);
    my $author = _bus_backed_cache($shared);

    for my $cache ( $peer, $author ) {
        $cache->put( $CACHE_KEY, $CACHE_VALUE,
            { tags => [$CACHE_TAG], ttl_seconds => $CACHE_TTL } );
    }

    # The first read is what issues LISTEN on a backend, so both have to read
    # before the author notifies or PostgreSQL has nobody to deliver to.
    is( $peer->get($CACHE_KEY),   $CACHE_VALUE, 'the peer serves the entry' );
    is( $author->get($CACHE_KEY), $CACHE_VALUE, 'the author serves the entry' );

    $author->invalidate_tag($CACHE_TAG);
    is( $author->bus->stats->{published},
        1, 'invalidating a tag publishes one notification' );
    is( $author->get($CACHE_KEY), undef, 'the author drops its own entry' );

    is( $peer->get($CACHE_KEY),
        undef, 'the peer drops the entry it was never asked to invalidate' );
    is( $peer->stats->{remote_invalidations},
        1, 'the peer records the invalidation as remote' );
    is( $peer->bus->stats->{skipped_self},
        0, 'the peer does not mistake the notification for its own' );

    # PostgreSQL delivers a NOTIFY to the sender too; replaying it would be
    # wasted work, so the sending backend PID has to be recognised.
    is( $author->bus->stats->{skipped_self},
        1, 'the author skips its own notification' );

    return;
}

sub _bus_backed_cache {
    my ($shared) = @_;

    my $schema = GPForum::Test::PostgresHarness::connect_schema();

    return GPForum::Service::Operations::TieredCache->new(
        bus => GPForum::Service::Operations::CacheInvalidationBus->new(
            schema => $schema
        ),
        l1 => GPForum::Service::Operations::LocalCache->new(
            namespace => 'gpforum'
        ),
        l2 => $shared,
    );
}

# Two hosts deploying at once used to run the same migration concurrently:
# each read an empty schema_versions and proceeded, and the second died on a
# duplicate key in pg_type. The runner now holds one session-level advisory
# lock across the whole run. Session-level and not transaction-level, because
# the migration files open and commit their own transactions and an xact lock
# would be released by the first COMMIT.
sub _migrations_serialise_and_verify {
    my $schema = GPForum::Test::PostgresHarness::connect_schema();
    my $runner = GPForum::Migration::Runner->new( schema => $schema );

    my $holder = GPForum::Test::PostgresHarness::connect_schema();
    my $rival  = GPForum::Test::PostgresHarness::connect_schema();

    my ($free) =
      $rival->storage->dbh->selectrow_array( $TRY_LOCK_SQL, undef,
        $MIGRATION_LOCK_KEY );
    ok( $free, 'the migration lock is free before anyone takes it' );
    $rival->storage->dbh->selectrow_array( $UNLOCK_SQL, undef,
        $MIGRATION_LOCK_KEY );

    $holder->storage->dbh->selectrow_array( $LOCK_SQL, undef,
        $MIGRATION_LOCK_KEY );
    my ($contended) =
      $rival->storage->dbh->selectrow_array( $TRY_LOCK_SQL, undef,
        $MIGRATION_LOCK_KEY );
    ok( !$contended,
        'a second deployer cannot take the migration lock while it is held' );
    $holder->storage->dbh->selectrow_array( $UNLOCK_SQL, undef,
        $MIGRATION_LOCK_KEY );

    my ($released) =
      $rival->storage->dbh->selectrow_array( $TRY_LOCK_SQL, undef,
        $MIGRATION_LOCK_KEY );
    ok( $released, 'the lock is available again once the run finishes' );
    $rival->storage->dbh->selectrow_array( $UNLOCK_SQL, undef,
        $MIGRATION_LOCK_KEY );

    # apply_pending on an already-migrated database must leave no lock behind.
    my $applied = $runner->apply_pending;
    is( scalar @{$applied}, 0, 'a second run applies nothing' );
    my ($leaked) = $schema->storage->dbh->selectrow_array($ADVISORY_COUNT_SQL);
    is( $leaked, 0, 'apply_pending releases its advisory lock' );

    # A checksum nobody compares is a comment.
    my $dbh = $schema->storage->dbh;
    my ($version) =
      $dbh->selectrow_array(
        'SELECT version FROM schema_versions ORDER BY version LIMIT 1');
    my ($original) = $dbh->selectrow_array(
        'SELECT checksum FROM schema_versions WHERE version = ?',
        undef, $version );
    $dbh->do( 'UPDATE schema_versions SET checksum = ? WHERE version = ?',
        undef, 'tampered', $version );
    my $survived = eval { $runner->verify_applied; 1 };
    ok( !$survived,
        'a migration file that changed after it was applied is rejected' );
    like(
        "$EVAL_ERROR",
        qr/changed [ ] after [ ] they [ ] were [ ] applied/msx,
        'the rejection says what drifted'
    );
    $dbh->do( 'UPDATE schema_versions SET checksum = ? WHERE version = ?',
        undef, $original, $version );
    ok( eval { $runner->verify_applied; 1 },
        'verification passes once the recorded checksum matches the file' );

    return;
}

# EventRecorder reads the head of the hash chain on every auditable write, and
# does it while holding pg_advisory_xact_lock, so the cost is paid serially by
# every thread creation, moderation action and privacy request. audit_log is
# partitioned on created_at and carried only a BRIN index, which cannot answer
# an ORDER BY ... LIMIT: measured against 200,000 rows the read was a parallel
# sequential scan of every partition plus a top-N heapsort, 3,543 shared
# buffers. Migration 039 makes it a Merge Append of index scans, 8 buffers.
sub _audit_chain_tip_uses_an_index {
    my $schema = GPForum::Test::PostgresHarness::connect_schema();
    my $dbh    = $schema->storage->dbh;

    my ($present) = $dbh->selectrow_array($CHAIN_INDEX_SQL);
    ok( $present,
        'the audit chain tip index exists on the partitioned parent' );

    my $plan = join "\n",
      map { $_->[0] } @{ $dbh->selectall_arrayref($CHAIN_TIP_EXPLAIN_SQL) };

    unlike(
        $plan,
        qr/Seq [ ] Scan [ ] on [ ] audit_log/msx,
        'reading the chain tip does not scan an audit_log partition'
    );
    like(
        $plan,
        qr/Index [ ] Scan|Index [ ] Only [ ] Scan/msx,
        'reading the chain tip uses an index'
    );

    return;
}

sub _load_context {
    my ($database_info) = @_;

    my $users = $database_info->{dbh}
      ->selectall_arrayref( $SEED_USER_SQL, { Slice => {} } );
    ok( @{$users} >= GPForum::Test::PostgresHarness::worker_count(),
        'seed provides at least two users' );
    my ($post_id) = $database_info->{dbh}->selectrow_array($SEED_POST_SQL);
    ok( $post_id, 'seed provides a visible post' );
    my $thread =
      $database_info->{dbh}->selectrow_hashref( $SEED_THREAD_SQL, undef );
    ok( $thread, 'seed provides an open thread to reply to' );

    return {
        actor_user_id    => $users->[0]{id},
        dbh              => $database_info->{dbh},
        member_user_id   => $users->[1]{id},
        post_id          => $post_id,
        race_target      => $RACE_TARGET_ID,
        reply_thread_id  => $thread->{thread_id},
        reply_visibility => $thread->{visibility},
        report_target    => $REPORT_TARGET_ID,
    };
}

sub _command_log_race {
    my ($ctx) = @_;

    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _run_command_probe( $ctx->{member_user_id} );
        }
    );
    _assert_workers_ok( \@outcomes, 'command_log race' );
    _assert_command_log_outcomes( \@outcomes, $ctx );

    return;
}

sub _run_command_probe {
    my ($actor_id) = @_;

    my $service = GPForum::Service::Operations::CommandIdempotency->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), );
    my $result = $service->run(
        {
            actor_id     => $actor_id,
            command_id   => $COMMAND_KEY,
            command_type => 'concurrency.probe',
            request      => { probe => 'command_log' },
        },
        sub { return { ok => 1, probe => 'done', status => 'ok' }; },
        sub {
            my ($value) = @_;
            return {
                ok     => $value->{ok},
                probe  => $value->{probe},
                status => $value->{status},
            };
        },
    );

    return {
        conflict    => $result->{conflict}    ? 1 : 0,
        in_progress => $result->{in_progress} ? 1 : 0,
        recorded    => $result->{recorded}    ? 1 : 0,
        replayed    => $result->{replayed}    ? 1 : 0,
    };
}

sub _assert_command_log_outcomes {
    my ( $outcomes, $ctx ) = @_;

    my $recorded =
      grep { $_->{result}{recorded} } @{$outcomes};
    my $settled = grep {
             $_->{result}{recorded}
          || $_->{result}{replayed}
          || $_->{result}{in_progress}
    } @{$outcomes};
    is( $recorded, 1, 'command_log race records exactly one winner' );
    is(
        $settled,
        GPForum::Test::PostgresHarness::worker_count(),
        'command_log losers replay or report in_progress'
    );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'command_log', { idempotency_key => $COMMAND_KEY }
        ),
        1,
        'command_log race keeps one command_log row'
    );

    return;
}

sub _bookmark_unique_race {
    my ($ctx) = @_;

    my $input = {
        note        => 'concurrency bookmark',
        target_id   => $ctx->{race_target},
        target_type => 'thread',
        user_id     => $ctx->{member_user_id},
    };
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $saved =
              GPForum::Service::Community::BookmarkStore->new(
                schema => GPForum::Test::PostgresHarness::connect_schema(), )
              ->save_bookmark($input);
            return { bookmark_id => $saved->{bookmark_id} };
        }
    );
    _assert_workers_ok( \@outcomes, 'bookmark unique race' );
    _assert_single_id( \@outcomes, 'bookmark_id', 'bookmark unique race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh},
            'bookmarks',
            {
                target_id   => $input->{target_id},
                target_type => $input->{target_type},
                user_id     => $input->{user_id},
            }
        ),
        1,
        'bookmark unique race keeps one row'
    );

    return;
}

sub _subscription_unique_race {
    my ($ctx) = @_;

    my $input = {
        preference  => 'all',
        target_id   => $ctx->{race_target},
        target_type => 'thread',
        user_id     => $ctx->{member_user_id},
    };
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $saved =
              GPForum::Service::Notification::SubscriptionStore->new(
                schema => GPForum::Test::PostgresHarness::connect_schema(), )
              ->save_subscription($input);
            return { subscription_id => $saved->{subscription_id} };
        }
    );
    _assert_workers_ok( \@outcomes, 'subscription unique race' );
    _assert_single_id( \@outcomes, 'subscription_id',
        'subscription unique race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh},
            'subscriptions',
            {
                target_id   => $input->{target_id},
                target_type => $input->{target_type},
                user_id     => $input->{user_id},
            }
        ),
        1,
        'subscription unique race keeps one row'
    );

    return;
}

sub _report_open_unique_race {
    my ($ctx) = @_;

    my $input = {
        details          => 'concurrency report',
        reason           => 'spam',
        reporter_user_id => $ctx->{member_user_id},
        target_id        => $ctx->{report_target},
        target_type      => 'post',
    };
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $report =
              GPForum::Service::Moderation::ReportStore->new(
                schema => GPForum::Test::PostgresHarness::connect_schema(), )
              ->create_report($input);
            return {
                report_id => GPForum::Test::PostgresHarness::row_value(
                    $report, 'report_id'
                )
            };
        }
    );
    _assert_workers_ok( \@outcomes, 'report open unique race' );
    _assert_single_id( \@outcomes, 'report_id', 'report open unique race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh},
            'reports',
            {
                reporter_user_id => $input->{reporter_user_id},
                status           => 'open',
                target_id        => $input->{target_id},
                target_type      => $input->{target_type},
            }
        ),
        1,
        'report open unique race keeps one open report'
    );

    return;
}

sub _moderation_hide_race {
    my ($ctx) = @_;

    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _hide_once($ctx);
        }
    );
    _assert_workers_ok( \@outcomes, 'moderation hide race' );
    _assert_single_id( \@outcomes, 'action_id', 'moderation hide race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'moderation_actions',
            { command_id => $HIDE_COMMAND }
        ),
        1,
        'moderation hide race keeps one action row'
    );
    my ($state) =
      $ctx->{dbh}
      ->selectrow_array( 'SELECT moderation_state FROM posts WHERE post_id = ?',
        undef, $ctx->{post_id}, );
    is( $state, 'hidden', 'moderation hide race leaves the post hidden' );

    return;
}

sub _hide_once {
    my ($ctx) = @_;

    my $hidden = GPForum::Service::Moderation::ActionStore->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), )
      ->hide_post(
        {
            actor_user_id => $ctx->{actor_user_id},
            command_id    => $HIDE_COMMAND,
            post_id       => $ctx->{post_id},
            reason        => 'concurrency hide',
        }
      );

    return {
        action_id => GPForum::Test::PostgresHarness::row_value(
            $hidden->{action}, 'moderation_action_id'
        ),
        ok       => $hidden->{ok}       ? 1 : 0,
        replayed => $hidden->{replayed} ? 1 : 0,
        skipped  => $hidden->{skipped}  ? 1 : 0,
    };
}

# Replies to one thread take their positions under the thread row lock, so
# they come out in commit order: the PostReader keyset and the ReadState
# high-water mark both assume a reply that commits later never has the lower
# number. Racing replies freely cannot show the lock: without it the retry on
# the (thread_id, position) unique index still hands out contiguous positions.
# So the test holds the thread row as a reply in flight would, sees every
# racing reply queue behind it, then lets them through.
sub _reply_position_race {
    my ($ctx) = @_;

    my ($before) =
      $ctx->{dbh}
      ->selectrow_array( $LAST_POSITION_SQL, undef, $ctx->{reply_thread_id} );
    my $holder =
      GPForum::Test::PostgresHarness::connect_dbi( $ENV{GPFORUM_DATABASE_DSN} );
    $holder->begin_work;
    $holder->selectrow_array( $HOLD_THREAD_SQL, undef,
        $ctx->{reply_thread_id} );

    my @replies =
      map { _spawn_reply( $ctx, "concurrent reply $_" ) } 1 .. $REPLY_RACERS;
    ok(
        _await_lock_waiters( $ctx->{dbh}, $REPLY_RACERS ),
        'every racing reply queues on the thread row lock'
    );
    $holder->rollback;
    $holder->disconnect;

    my @outcomes = map { _collect_worker($_) } @replies;
    _assert_workers_ok( \@outcomes, 'reply position race' );

    my @positions =
      sort { $a <=> $b } map { $_->{result}{position} // 0 } @outcomes;
    is_deeply(
        \@positions,
        [ map { $before + $_ } 1 .. $REPLY_RACERS ],
        'reply position race hands each reply the next position'
    );
    is_deeply(
        $ctx->{dbh}->selectcol_arrayref(
            $POSITIONS_AFTER_SQL, undef, $ctx->{reply_thread_id}, $before
        ),
        \@positions,
        'reply position race stores exactly those positions'
    );
    _assert_one_created_event( $ctx, \@outcomes );

    return;
}

sub _assert_one_created_event {
    my ( $ctx, $outcomes ) = @_;

    for my $outcome ( @{$outcomes} ) {
        is(
            GPForum::Test::PostgresHarness::count_rows(
                $ctx->{dbh},
                'event_log',
                {
                    aggregate_id => $outcome->{result}{post_id},
                    event_type   => 'post.created',
                }
            ),
            1,
            'reply position race records one post.created per reply'
        );
    }

    return;
}

# FOR UPDATE on the thread row conflicts with the FOR KEY SHARE a foreign-key
# check takes, so a reader's first mark-read insert waited for every reply in
# flight to commit. FOR NO KEY UPDATE still serialises replies and does not.
sub _reply_lock_allows_fk_inserts {
    my ($ctx) = @_;

    my $holder = GPForum::Test::PostgresHarness::connect_schema();
    my $reader =
      GPForum::Test::PostgresHarness::connect_dbi( $ENV{GPFORUM_DATABASE_DSN} );
    my @read_key = ( $ctx->{member_user_id}, $ctx->{reply_thread_id} );

    $holder->txn_begin;
    my $in_flight = GPForum::Service::Forum::PostStore->new( schema => $holder )
      ->create_post( _reply_command( $ctx, 'reply in flight' ) );
    ok( $in_flight->{ok}, 'a reply is in flight, holding the thread lock' );

    # Passing the foreign-key check proves nothing if the reply took no lock.
    my $next_reply = eval {
        $reader->selectrow_array( $HOLD_THREAD_NOWAIT_SQL, undef,
            $ctx->{reply_thread_id} );
        1;
    };
    ok( !$next_reply,
        'the reply in flight holds the thread from the next one' );

    # The seed has already marked the thread read for its users. Clear the
    # marker inside the rolled-back transaction, so the insert is a first
    # mark and runs the foreign-key check.
    $reader->begin_work;
    $reader->do(q{SET LOCAL lock_timeout = '200ms'});
    $reader->do( $CLEAR_READ_SQL, undef, @read_key );
    my $inserted = eval {
        $reader->do( $MARK_READ_SQL, undef, @read_key );
        1;
    };
    ok( $inserted,
        'a first mark-read insert does not wait for the reply to commit' )
      or diag($EVAL_ERROR);

    $reader->rollback;
    $holder->txn_rollback;
    $reader->disconnect;
    $holder->storage->disconnect;

    return;
}

# The workflow checks locked_at before the command's transaction, so a
# moderator who locks the thread in between used to see a reply land in the
# locked thread. The reply now waits on the moderator's row lock, reads the
# thread as committed, and is refused.
sub _reply_rechecks_lock {
    my ($ctx) = @_;

    my $posts_before =
      GPForum::Test::PostgresHarness::count_rows( $ctx->{dbh}, 'posts',
        { thread_id => $ctx->{reply_thread_id} } );
    my $moderator = GPForum::Test::PostgresHarness::connect_schema();
    $moderator->txn_begin;
    my $locked =
      GPForum::Service::Moderation::ActionStore->new( schema => $moderator )
      ->lock_thread(
        {
            actor_user_id => $ctx->{actor_user_id},
            command_id    => $LOCK_COMMAND,
            reason        => 'concurrency lock',
            thread_id     => $ctx->{reply_thread_id},
        }
      );
    ok( $locked->{ok}, 'a moderator locks the thread, not yet committed' );
    my ($moderator_pid) =
      $moderator->storage->dbh->selectrow_array('SELECT pg_backend_pid()');

    my $reply = _spawn_reply( $ctx, 'reply racing a lock' );
    ok(
        _await_blocked_on( $ctx->{dbh}, $moderator_pid ),
        'the reply waits on the moderator\'s thread lock'
    );
    $moderator->txn_commit;
    $moderator->storage->disconnect;

    my $outcome = _collect_worker($reply);
    ok( $outcome->{ok}, 'the waiting reply finishes without exception' )
      or diag( $outcome->{error} // 'missing error' );
    is_deeply(
        {
            error => $outcome->{result}{error},
            ok    => $outcome->{result}{ok}
        },
        { error => 'thread is locked', ok => 0 },
        'the reply sees the lock committed while it waited and is refused'
    );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'posts', { thread_id => $ctx->{reply_thread_id} }
        ),
        $posts_before,
        'the refused reply leaves no post in the locked thread'
    );

    return;
}

# A deleted thread is not found to anyone but its author, so a reply that
# waited while the author deleted the thread must read the deletion and be
# refused, not land in a thread its own writer can no longer open.
sub _reply_rechecks_delete {
    my ($ctx) = @_;

    my $thread = $ctx->{dbh}->selectrow_hashref(
        $OTHER_AUTHOR_THREAD_SQL, undef,
        $ctx->{reply_thread_id},
        $ctx->{member_user_id}
    );
    ok( $thread, 'seed provides an open thread by someone else' );
    my $target = {
        %{$ctx},
        reply_thread_id  => $thread->{thread_id},
        reply_visibility => $thread->{visibility},
    };
    my $posts_before =
      GPForum::Test::PostgresHarness::count_rows( $ctx->{dbh}, 'posts',
        { thread_id => $thread->{thread_id} } );

    my $author = GPForum::Test::PostgresHarness::connect_schema();
    $author->txn_begin;
    my $deleted =
      GPForum::Service::Forum::ThreadStore->new( schema => $author )
      ->delete_thread(
        {
            idempotency_key => $DELETE_COMMAND,
            thread          => {
                category_id => $thread->{category_id},
                deleted_by  => $thread->{author_user_id},
                thread_id   => $thread->{thread_id},
            },
        }
      );
    ok( $deleted->{ok}, 'the author deletes the thread, not yet committed' );
    my ($author_pid) =
      $author->storage->dbh->selectrow_array('SELECT pg_backend_pid()');

    my $reply = _spawn_reply( $target, 'reply racing a delete' );
    ok(
        _await_blocked_on( $ctx->{dbh}, $author_pid ),
        'the reply waits on the author\'s thread lock'
    );
    $author->txn_commit;
    $author->storage->disconnect;

    my $outcome = _collect_worker($reply);
    ok( $outcome->{ok}, 'the reply racing a delete finishes without exception' )
      or diag( $outcome->{error} // 'missing error' );
    is_deeply(
        {
            error => $outcome->{result}{error},
            ok    => $outcome->{result}{ok}
        },
        { error => 'thread not found', ok => 0 },
        'the reply sees the deletion committed while it waited and is refused'
    );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'posts', { thread_id => $thread->{thread_id} }
        ),
        $posts_before,
        'the refused reply leaves no post in the deleted thread'
    );

    return;
}

# The workflow checks an edit before the store takes any row lock: the post is
# live and not hidden, its thread readable and not locked. A moderator who
# locks the thread in between used to see the edit land in the locked thread
# (ADR 0061). The edit now takes the thread row before the post, waits on the
# moderator's lock, reads the thread as committed and is refused.
sub _edit_rechecks_thread_lock {
    my ($ctx) = @_;

    my $post = _editable_post($ctx);
    _assert_refused_after_wait(
        $ctx,
        {
            write =>
              sub { return _edit_post_once( $post, 'edit racing a lock' ) },
            error => 'thread is locked',
            hold  => sub {
                my ($holder) = @_;
                return GPForum::Service::Moderation::ActionStore->new(
                    schema => $holder )->lock_thread(
                    {
                        actor_user_id => $ctx->{actor_user_id},
                        command_id    => $EDIT_LOCK_COMMAND,
                        reason        => 'concurrency edit lock',
                        thread_id     => $post->{thread_id},
                    }
                    );
            },
            label => 'a post edit racing a thread lock',
            state => sub { return _post_edit_state( $ctx, $post ) },
        }
    );

    return;
}

# A moderator hides the post while its author's edit waits on the post row.
sub _edit_rechecks_post_hide {
    my ($ctx) = @_;

    my $post = _editable_post($ctx);
    _assert_refused_after_wait(
        $ctx,
        {
            write =>
              sub { return _edit_post_once( $post, 'edit racing a hide' ) },
            error => 'post is hidden',
            hold  => sub {
                my ($holder) = @_;
                return GPForum::Service::Moderation::ActionStore->new(
                    schema => $holder )->hide_post(
                    {
                        actor_user_id => $ctx->{actor_user_id},
                        command_id    => $EDIT_HIDE_COMMAND,
                        post_id       => $post->{post_id},
                        reason        => 'concurrency edit hide',
                    }
                    );
            },
            label => 'a post edit racing a hide',
            state => sub { return _post_edit_state( $ctx, $post ) },
        }
    );

    return;
}

# The author deletes the post in one tab while an edit from another waits.
sub _edit_rechecks_post_delete {
    my ($ctx) = @_;

    my $post = _editable_post($ctx);
    _assert_refused_after_wait(
        $ctx,
        {
            write =>
              sub { return _edit_post_once( $post, 'edit racing a delete' ) },
            error => 'post not found',
            hold  => sub {
                my ($holder) = @_;
                return GPForum::Service::Forum::PostStore->new(
                    schema => $holder )->delete_post(
                    {
                        idempotency_key => $EDIT_DELETE_KEY,
                        post            => {
                            deleted_by => $post->{author_user_id},
                            post_id    => $post->{post_id},
                            thread_id  => $post->{thread_id},
                        },
                    }
                    );
            },
            label => 'a post edit racing a delete',
            state => sub { return _post_edit_state( $ctx, $post ) },
        }
    );

    return;
}

# A thread's title is an edit of the thread, and ADR 0061's lock covers it.
sub _title_edit_rechecks_lock {
    my ($ctx) = @_;

    my $thread = $ctx->{dbh}->selectrow_hashref( $EDITABLE_THREAD_SQL, undef );
    ok( $thread, 'seed provides another open thread to retitle' );
    my $command = GPForum::Service::Forum::ThreadComposer->new->prepare_title(
        {
            editor_user_id  => $thread->{author_user_id},
            idempotency_key => $TITLE_LOCK_COMMAND,
            thread_id       => $thread->{thread_id},
            title           => 'Title edit racing a lock',
        }
    )->{command};
    _assert_refused_after_wait(
        $ctx,
        {
            write => sub {
                return _store_answer(
                    GPForum::Service::Forum::ThreadStore->new(
                        schema =>
                          GPForum::Test::PostgresHarness::connect_schema()
                    )->edit_thread($command)
                );
            },
            error => 'thread is locked',
            hold  => sub {
                my ($holder) = @_;
                return GPForum::Service::Moderation::ActionStore->new(
                    schema => $holder )->lock_thread(
                    {
                        actor_user_id => $ctx->{actor_user_id},
                        command_id    => $TITLE_LOCK_COMMAND,
                        reason        => 'concurrency title lock',
                        thread_id     => $thread->{thread_id},
                    }
                    );
            },
            label => 'a title edit racing a thread lock',
            state => sub {
                return {
                    events => GPForum::Test::PostgresHarness::count_rows(
                        $ctx->{dbh},
                        'event_log',
                        {
                            aggregate_id => $thread->{thread_id},
                            event_type   => 'thread.updated',
                        }
                    ),
                    row => $ctx->{dbh}->selectrow_hashref(
                        $THREAD_TITLE_SQL, undef, $thread->{thread_id}
                    ),
                };
            },
        }
    );

    return;
}

# The workflow refuses its author's delete of a post in a locked thread, as
# it refuses an edit (ADR 0061). A moderator who locks the thread after that
# check used to see the post disappear from the locked thread anyway.
sub _delete_rechecks_thread_lock {
    my ($ctx) = @_;

    my $post = _editable_post($ctx);
    _assert_refused_after_wait(
        $ctx,
        {
            write => sub {
                return _store_answer(
                    GPForum::Service::Forum::PostStore->new(
                        schema =>
                          GPForum::Test::PostgresHarness::connect_schema()
                    )->delete_post(
                        _post_delete_command( $post, $DELETE_RACE_KEY )
                    )
                );
            },
            error => 'thread is locked',
            hold  => sub {
                my ($holder) = @_;
                return GPForum::Service::Moderation::ActionStore->new(
                    schema => $holder )->lock_thread(
                    {
                        actor_user_id => $ctx->{actor_user_id},
                        command_id    => $DELETE_LOCK_COMMAND,
                        reason        => 'concurrency delete lock',
                        thread_id     => $post->{thread_id},
                    }
                    );
            },
            label => 'a post delete racing a thread lock',
            state => sub { return _post_deletion_state( $ctx, $post ) },
        }
    );

    return;
}

# The author restores their deleted post while a moderator hides it: the
# workflow refuses to restore a hidden post, and so must the store once the
# hide has committed.
sub _restore_rechecks_post_hide {
    my ($ctx) = @_;

    my $post = _editable_post($ctx);
    my $deleted =
      GPForum::Service::Forum::PostStore->new(
        schema => GPForum::Test::PostgresHarness::connect_schema() )
      ->delete_post( _post_delete_command( $post, $RESTORE_DELETE_KEY ) );
    ok( $deleted->{ok}, 'the author has deleted the post to restore' );

    _assert_refused_after_wait(
        $ctx,
        {
            write => sub {
                return _store_answer(
                    GPForum::Service::Forum::PostStore->new(
                        schema =>
                          GPForum::Test::PostgresHarness::connect_schema()
                    )->restore_post(
                        {
                            idempotency_key => $RESTORE_RACE_KEY,
                            post            => {
                                author_user_id => $post->{author_user_id},
                                post_id        => $post->{post_id},
                                restored_by    => $post->{author_user_id},
                                thread_id      => $post->{thread_id},
                            },
                        }
                    )
                );
            },
            error => 'post is hidden',
            hold  => sub {
                my ($holder) = @_;
                return GPForum::Service::Moderation::ActionStore->new(
                    schema => $holder )->hide_post(
                    {
                        actor_user_id => $ctx->{actor_user_id},
                        command_id    => $RESTORE_HIDE_COMMAND,
                        post_id       => $post->{post_id},
                        reason        => 'concurrency restore hide',
                    }
                    );
            },
            label => 'a post restore racing a hide',
            state => sub { return _post_deletion_state( $ctx, $post ) },
        }
    );

    return;
}

# The workflow refuses its author's delete of a thread that is locked, or
# that it cannot see because a moderator hid it, as it refuses a title edit
# (ADR 0061). It checks before the store's row lock, so a lock or hide that
# committed in between used to let the delete land; the store now reads the
# thread back under its lock and asks again.
sub _thread_delete_rechecks_moderation {
    my ($ctx) = @_;

    _thread_write_races(
        $ctx,
        {
            name  => 'delete',
            write => sub {
                my ( $store, $thread ) = @_;
                return $store->delete_thread(
                    {
                        idempotency_key => _fresh_id(),
                        thread          => {
                            deleted_by => $thread->{author_user_id},
                            thread_id  => $thread->{thread_id},
                        },
                    }
                );
            },
        }
    );

    return;
}

# A move is checked as a delete is, and must not carry a thread a moderator
# has just locked or hidden into another category.
sub _thread_move_rechecks_moderation {
    my ($ctx) = @_;

    _thread_write_races(
        $ctx,
        {
            name  => 'move',
            write => sub {
                my ( $store, $thread ) = @_;
                my $move =
                  GPForum::Service::Forum::ThreadComposer->new->prepare_move(
                    {
                        category_id     => $thread->{other_category_id},
                        editor_user_id  => $thread->{author_user_id},
                        idempotency_key => _fresh_id(),
                        thread_id       => $thread->{thread_id},
                    }
                  );
                croak 'move command did not prepare' if !$move->{ok};

                return $store->move_thread( $move->{command} );
            },
        }
    );

    return;
}

# The author restores a thread they deleted while a moderator locks or hides
# it: the workflow refuses to restore either, and so must the store once the
# moderator has committed.
sub _thread_restore_rechecks_moderation {
    my ($ctx) = @_;

    _thread_write_races(
        $ctx,
        {
            name    => 'restore',
            prepare => sub {
                my ($thread) = @_;
                my $deleted =
                  GPForum::Service::Forum::ThreadStore->new(
                    schema => GPForum::Test::PostgresHarness::connect_schema() )
                  ->delete_thread(
                    {
                        idempotency_key => _fresh_id(),
                        thread          => {
                            deleted_by => $thread->{author_user_id},
                            thread_id  => $thread->{thread_id},
                        },
                    }
                  );
                ok( $deleted->{ok},
                    'the author has deleted the thread to restore' );

                return;
            },
            write => sub {
                my ( $store, $thread ) = @_;
                return $store->restore_thread(
                    {
                        idempotency_key => _fresh_id(),
                        thread          => {
                            author_user_id => $thread->{author_user_id},
                            category_id    => $thread->{category_id},
                            restored_by    => $thread->{author_user_id},
                            thread_id      => $thread->{thread_id},
                        },
                    }
                );
            },
        }
    );

    return;
}

# One race per moderator write, each on a thread no earlier race has
# touched: the lock or hide is held uncommitted, the author's write is forked
# through ThreadStore and must queue on the thread row, then be refused.
sub _thread_write_races {
    my ( $ctx, $race ) = @_;

    for my $moderation (@THREAD_MODERATION) {
        my ( $noun, $error ) = @{$moderation};
        my $thread = _open_thread($ctx);
        if ( $race->{prepare} ) {
            $race->{prepare}->($thread);
        }

        _assert_refused_after_wait(
            $ctx,
            {
                error => $error,
                hold  => sub {
                    my ($holder) = @_;
                    return _moderate_thread( $holder, $ctx, $noun, $thread );
                },
                label => "a thread $race->{name} racing a thread $noun",
                state => sub { return _thread_write_state( $ctx, $thread ) },
                write => sub {
                    my $schema =
                      GPForum::Test::PostgresHarness::connect_schema();
                    my $store = GPForum::Service::Forum::ThreadStore->new(
                        schema => $schema );
                    return _store_answer( $race->{write}->( $store, $thread ) );
                },
            }
        );
    }

    return;
}

# A moderator's lock or hide of the thread, through ActionStore as the
# moderation routes make it, left uncommitted in $holder.
sub _moderate_thread {
    my ( $holder, $ctx, $noun, $thread ) = @_;

    my $moderate = "${noun}_thread";

    return GPForum::Service::Moderation::ActionStore->new( schema => $holder )
      ->$moderate(
        {
            actor_user_id => $ctx->{actor_user_id},
            command_id    => _fresh_id(),
            reason        => "concurrency thread write $noun",
            thread_id     => $thread->{thread_id},
        }
      );
}

# The first thread still open, and a category to move it to.
sub _open_thread {
    my ($ctx) = @_;

    my $thread = $ctx->{dbh}->selectrow_hashref( $EDITABLE_THREAD_SQL, undef );
    ok( $thread, 'seed provides another open thread' );
    return $thread if !$thread;

    ( $thread->{other_category_id} ) =
      $ctx->{dbh}
      ->selectrow_array( $OTHER_CATEGORY_SQL, undef, $thread->{category_id} );

    return $thread;
}

# What a thread delete, move or restore writes: the deletion markers, the
# category and the event. The holder's own write may bump the version.
sub _thread_write_state {
    my ( $ctx, $thread ) = @_;

    return {
        events => {
            map {
                $_ => GPForum::Test::PostgresHarness::count_rows(
                    $ctx->{dbh},
                    'event_log',
                    { aggregate_id => $thread->{thread_id}, event_type => $_ }
                )
            } qw(thread.deleted thread.moved thread.undeleted)
        },
        row => $ctx->{dbh}
          ->selectrow_hashref( $THREAD_WRITE_SQL, undef, $thread->{thread_id} ),
    };
}

sub _fresh_id {
    return GPForum::Infrastructure::Id->new->uuid;
}

sub _post_delete_command {
    my ( $post, $idempotency_key ) = @_;

    return {
        idempotency_key => $idempotency_key,
        post            => {
            deleted_by => $post->{author_user_id},
            post_id    => $post->{post_id},
            thread_id  => $post->{thread_id},
        },
    };
}

# What a delete or restore writes: the post's deletion markers, the thread's
# reply count and the event.
sub _post_deletion_state {
    my ( $ctx, $post ) = @_;

    my ($replies) =
      $ctx->{dbh}
      ->selectrow_array( $REPLY_COUNT_SQL, undef, $post->{thread_id} );

    return {
        events => {
            map {
                $_ => GPForum::Test::PostgresHarness::count_rows( $ctx->{dbh},
                    'event_log',
                    { aggregate_id => $post->{post_id}, event_type => $_ } )
            } qw(post.deleted post.undeleted)
        },
        replies => $replies,
        row     => $ctx->{dbh}
          ->selectrow_hashref( $POST_DELETION_SQL, undef, $post->{post_id} ),
    };
}

sub _store_answer {
    my ($stored) = @_;

    return { error => $stored->{error}, ok => $stored->{ok} ? 1 : 0 };
}

# The holder acts in a transaction left open; the author's write, forked,
# must queue on one of the holder's rows, and once the holder commits, read
# what it wrote, be refused in the workflow's words, and leave the target as
# it was.
sub _assert_refused_after_wait {
    my ( $ctx, $race ) = @_;

    my $before = $race->{state}->();
    my $holder = GPForum::Test::PostgresHarness::connect_schema();
    $holder->txn_begin;
    ok( $race->{hold}->($holder)->{ok},
        "$race->{label}: the holder writes, not yet committed" );
    my ($holder_pid) =
      $holder->storage->dbh->selectrow_array('SELECT pg_backend_pid()');

    my $write = _spawn_worker( $race->{write} );
    ok( _await_row_wait( $ctx->{dbh}, $holder_pid ),
        "$race->{label}: the write waits on the holder's row lock" );
    $holder->txn_commit;
    $holder->storage->disconnect;

    my $outcome = _collect_worker($write);
    ok( $outcome->{ok}, "$race->{label}: the write finishes without exception" )
      or diag( $outcome->{error} // 'missing error' );
    is_deeply(
        {
            error => $outcome->{result}{error},
            ok    => $outcome->{result}{ok}
        },
        { error => $race->{error}, ok => 0 },
        "$race->{label}: the write reads the commit it waited on and is refused"
    );
    is_deeply( $race->{state}->(),
        $before, "$race->{label}: the refused write changes nothing" );

    return;
}

sub _editable_post {
    my ($ctx) = @_;

    my $post = $ctx->{dbh}->selectrow_hashref( $EDITABLE_POST_SQL, undef );
    ok( $post, 'seed provides a live post in an open thread to edit' );

    return $post;
}

sub _post_edit_state {
    my ( $ctx, $post ) = @_;

    return {
        events => GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh},
            'event_log',
            {
                aggregate_id => $post->{post_id},
                event_type   => 'post.updated',
            }
        ),
        revisions => GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'post_revisions', { post_id => $post->{post_id} }
        ),
        row => $ctx->{dbh}
          ->selectrow_hashref( $POST_POINTERS_SQL, undef, $post->{post_id} ),
    };
}

sub _edit_post_once {
    my ( $post, $body ) = @_;

    my $composed = GPForum::Service::Forum::PostComposer->new->prepare_revision(
        {
            body_hash       => "hash of $body",
            body_source     => $body,
            editor_user_id  => $post->{author_user_id},
            idempotency_key => "edit of $post->{post_id}",
            post_id         => $post->{post_id},
            thread_id       => $post->{thread_id},
        }
    );
    if ( !$composed->{ok} ) {
        croak "edit command did not prepare: $body";
    }
    return _store_answer(
        GPForum::Service::Forum::PostStore->new(
            schema => GPForum::Test::PostgresHarness::connect_schema()
        )->edit_post( $composed->{command} )
    );
}

sub _reply_once {
    my ( $ctx, $body ) = @_;

    my $stored =
      GPForum::Service::Forum::PostStore->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), )
      ->create_post( _reply_command( $ctx, $body ) );

    return {
        error    => $stored->{error},
        ok       => $stored->{ok} ? 1 : 0,
        position => GPForum::Test::PostgresHarness::row_value(
            $stored->{post}, 'position'
        ),
        post_id => GPForum::Test::PostgresHarness::row_value(
            $stored->{post}, 'post_id'
        ),
    };
}

sub _reply_command {
    my ( $ctx, $body ) = @_;

    my $composed = GPForum::Service::Forum::PostComposer->new->prepare(
        {
            allocate_position => 1,
            author_user_id    => $ctx->{member_user_id},
            body_hash         => "hash of $body",
            body_source       => $body,
            thread_id         => $ctx->{reply_thread_id},
            visibility_floor  => $ctx->{reply_visibility},
        }
    );
    if ( !$composed->{ok} ) {
        croak "reply command did not prepare: $body";
    }

    return $composed->{command};
}

sub _spawn_reply {
    my ( $ctx, $body ) = @_;

    return _spawn_worker( sub { return _reply_once( $ctx, $body ) } );
}

# PostgresHarness::race releases its workers together and waits for all of
# them, which leaves the parent no step while one is blocked. This forks one
# write and returns at once, so the parent can see it wait and then commit.
sub _spawn_worker {
    my ($work) = @_;

    pipe my $out_reader, my $out_writer or croak 'worker pipe failed';
    my $pid = fork;
    if ( !defined $pid ) {
        croak "fork failed: $OS_ERROR";
    }
    if ( $pid == 0 ) {
        close $out_reader or croak 'child worker reader close failed';
        my $result = eval { return $work->() };
        my $payload =
          $result ? { ok => 1, result => $result } : { error => "$EVAL_ERROR" };
        print {$out_writer} encode_json($payload)
          or croak 'worker result write failed';
        close $out_writer or croak 'child worker writer close failed';

        # _exit skips the destructors that would close the parent's handles.
        _exit(0);
    }

    close $out_writer or croak 'parent worker writer close failed';
    return { out => $out_reader, pid => $pid };
}

sub _collect_worker {
    my ($child) = @_;

    local $INPUT_RECORD_SEPARATOR = undef;
    my $json = readline $child->{out};
    close $child->{out} or croak 'parent worker reader close failed';
    waitpid $child->{pid}, 0;

    return decode_json($json);
}

# Backends of this database waiting on a heavyweight lock. Only the first
# reply in a row-lock queue is blocked by the holder itself; the others wait on
# the tuple lock the first one holds, so pg_blocking_pids of the holder would
# not count them.
sub _await_lock_waiters {
    my ( $dbh, $count ) = @_;

    for ( 1 .. $BLOCK_POLLS ) {
        my ($waiting) = $dbh->selectrow_array($LOCK_WAITERS_SQL);
        return 1 if $waiting >= $count;
        $dbh->do( 'SELECT pg_sleep(?)', undef, $BLOCK_POLL_SECONDS );
    }

    return 0;
}

sub _await_blocked_on {
    my ( $dbh, $holder_pid ) = @_;

    for ( 1 .. $BLOCK_POLLS ) {
        my ($waiting) =
          $dbh->selectrow_array( $BLOCKED_ON_SQL, undef, $holder_pid );
        return 1 if $waiting;
        $dbh->do( 'SELECT pg_sleep(?)', undef, $BLOCK_POLL_SECONDS );
    }

    return 0;
}

# Blocked by the holder on a row: a transaction id or a tuple lock. Every
# write here also queues on the audit chain's advisory lock, so a backend
# merely blocked by the holder could be waiting there, behind a check it
# never made.
sub _await_row_wait {
    my ( $dbh, $holder_pid ) = @_;

    for ( 1 .. $BLOCK_POLLS ) {
        my ($waiting) =
          $dbh->selectrow_array( $ROW_WAIT_SQL, undef, $holder_pid );
        return 1 if $waiting;
        $dbh->do( 'SELECT pg_sleep(?)', undef, $BLOCK_POLL_SECONDS );
    }

    return 0;
}

sub _audit_chain_race {
    my ($ctx) = @_;

    my $before =
      GPForum::Test::PostgresHarness::count_rows( $ctx->{dbh}, 'audit_log',
        {} );
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my ($slot) = @_;
            return _append_audit( $ctx, $slot );
        }
    );
    _assert_workers_ok( \@outcomes, 'audit chain race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'audit_log', {}
        ),
        $before + GPForum::Test::PostgresHarness::worker_count(),
        'audit chain race appends two rows'
    );
    _assert_concurrent_audit_link( \@outcomes );
    _assert_distinct_hashes( \@outcomes );

    return;
}

sub _append_audit {
    my ( $ctx, $slot ) = @_;

    my $schema = GPForum::Test::PostgresHarness::connect_schema();
    my $recorder =
      GPForum::Infrastructure::EventRecorder->new( schema => $schema );
    my $audit = $schema->txn_do(
        sub {
            return $recorder->record_audit(
                action         => 'concurrency.audit.' . $slot,
                actor_id       => $ctx->{actor_user_id},
                correlation_id => sprintf( '018f9999-0001-7000-8000-%012x',
                    $AUDIT_CORR_BASE + $slot ),
                metadata    => { slot => $slot },
                target_id   => $ctx->{race_target},
                target_type => 'thread',
            );
        }
    );

    return {
        audit_id      => $audit->{audit_id},
        previous_hash => $audit->{previous_hash},
        record_hash   => $audit->{record_hash},
    };
}

sub _assert_concurrent_audit_link {
    my ($outcomes) = @_;

    my $audit_a = $outcomes->[0]{result};
    my $audit_b = $outcomes->[1]{result};
    _assert_no_shared_previous( $audit_a, $audit_b );
    _assert_parent_child_link( $audit_a, $audit_b );

    return;
}

sub _assert_no_shared_previous {
    my ( $audit_a, $audit_b ) = @_;

    my $prev_a = $audit_a->{previous_hash};
    my $prev_b = $audit_b->{previous_hash};
    if ( defined $prev_a && defined $prev_b && $prev_a eq $prev_b ) {
        fail('concurrent audits must not share the same previous_hash');
        return;
    }

    pass('concurrent audits do not share previous_hash');
    return;
}

sub _assert_parent_child_link {
    my ( $audit_a, $audit_b ) = @_;

    my $prev_a = $audit_a->{previous_hash} // q{};
    my $prev_b = $audit_b->{previous_hash} // q{};
    my $linked = ( $prev_a eq ( $audit_b->{record_hash} // q{x} ) )
      || ( $prev_b eq ( $audit_a->{record_hash} // q{x} ) );
    ok( $linked, 'one concurrent audit is the parent of the other' );

    return;
}

sub _assert_distinct_hashes {
    my ($outcomes) = @_;

    my %seen;
    for my $outcome ( @{$outcomes} ) {
        my $hash = $outcome->{result}{record_hash};
        ok( !$seen{$hash}++, 'concurrent audit record_hash values differ' );
    }

    return;
}

sub _privacy_approval_race {
    my ($ctx) = @_;

    my $request_id = _seed_deletion_request($ctx);
    ok( $request_id, 'privacy race seeds a deletion request' );
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _approve_once( $ctx, $request_id );
        }
    );
    _assert_workers_ok( \@outcomes, 'privacy approval race' );
    _assert_single_id( \@outcomes, 'erasure_job_id', 'privacy approval race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'erasure_jobs',
            { deletion_request_id => $request_id }
        ),
        1,
        'privacy approval race keeps one erasure job row'
    );

    return;
}

sub _seed_deletion_request {
    my ($ctx) = @_;

    my $workflow = GPForum::Service::Privacy::DeletionWorkflow->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), );
    my $request = $workflow->request_deletion(
        {
            reason            => 'concurrency erasure',
            request_type      => 'anonymize',
            requester_user_id => $ctx->{member_user_id},
            resource_id       => $ctx->{member_user_id},
            resource_type     => 'user',
        }
    );

    return $request->{deletion_request_id};
}

sub _approve_once {
    my ( $ctx, $request_id ) = @_;

    my $approved =
      GPForum::Service::Privacy::DeletionWorkflow->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), )
      ->approve_request( $request_id, $ctx->{actor_user_id},
        'concurrency approval',
      );

    return {
        erasure_job_id => GPForum::Test::PostgresHarness::row_value(
            $approved->{job}, 'erasure_job_id'
        ),
        ok     => $approved->{ok}     ? 1 : 0,
        reused => $approved->{reused} ? 1 : 0,
    };
}

sub _identity_token_consume_race {
    my ($ctx) = @_;

    my $issued = _issue_reset_token($ctx);
    ok( $issued->{raw_token}, 'identity token race issues a raw token' );
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _consume_once( $issued->{raw_token} );
        }
    );
    _assert_workers_ok( \@outcomes, 'identity token consume race' );
    _assert_token_consume_outcomes( \@outcomes, $ctx, $issued->{token_id} );

    return;
}

sub _issue_reset_token {
    my ($ctx) = @_;

    my $store =
      GPForum::Service::Identity::Store->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), );

    return $store->token_store->create_token(
        {
            email_normalized => 'perf_user_race@example.invalid',
            token_type       => 'password_reset',
            ttl_seconds      => $TOKEN_TTL,
            user_id          => $ctx->{member_user_id},
        }
    );
}

sub _consume_once {
    my ($raw_token) = @_;

    my $child =
      GPForum::Service::Identity::Store->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), );
    my $consumed = $child->schema->txn_do(
        sub {
            return $child->token_store->consume_token( 'password_reset',
                $raw_token );
        }
    );

    return {
        error    => $consumed->{error} || q{},
        ok       => $consumed->{ok} ? 1 : 0,
        token_id => $consumed->{token_id} || q{},
    };
}

sub _assert_token_consume_outcomes {
    my ( $outcomes, $ctx, $token_id ) = @_;

    my $ok_count = grep { $_->{result}{ok} } @{$outcomes};
    my $used_count =
      grep { $_->{result}{error} eq 'token_used' } @{$outcomes};
    is( $ok_count,   1, 'identity token consume race succeeds once' );
    is( $used_count, 1, 'identity token consume race reports token_used once' );
    my ($used_at) =
      $ctx->{dbh}->selectrow_array(
        'SELECT used_at FROM identity_tokens WHERE token_id = ?',
        undef, $token_id, );
    ok( defined $used_at, 'identity token consume race marks used_at' );

    return;
}

sub _event_idempotency_race {
    my ($ctx) = @_;

    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $store = GPForum::Worker::EventIdempotencyStore->new(
                schema => GPForum::Test::PostgresHarness::connect_schema(), );
            my $ok =
              $store->mark_done( $EVENT_IDEM_KEY,
                { event_id => $EVENT_IDEM_EVENT },
              );
            return {
                done => $store->is_done($EVENT_IDEM_KEY) ? 1 : 0,
                ok   => $ok                              ? 1 : 0,
            };
        }
    );
    _assert_workers_ok( \@outcomes, 'event_idempotency_keys race' );
    my $accepted =
      grep { $_->{result}{ok} && $_->{result}{done} } @outcomes;
    is(
        $accepted,
        GPForum::Test::PostgresHarness::worker_count(),
        'event_idempotency_keys race accepts both mark_done calls'
    );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'event_idempotency_keys',
            { idempotency_key => $EVENT_IDEM_KEY },
        ),
        1,
        'event_idempotency_keys race keeps one row'
    );

    return;
}

sub _assert_workers_ok {
    my ( $outcomes, $label ) = @_;

    for my $index ( 0 .. $#{$outcomes} ) {
        ok( $outcomes->[$index]{ok},
            "$label worker $index completed without exception" )
          or diag( $outcomes->[$index]{error} // 'missing error' );
    }

    return;
}

sub _assert_single_id {
    my ( $outcomes, $key, $label ) = @_;

    my %ids =
      map  { $_->{result}{$key} => 1 }
      grep { defined $_->{result}{$key} && length $_->{result}{$key} }
      @{$outcomes};
    is( scalar keys %ids, 1, "$label returns one $key" );

    return;
}

1;
