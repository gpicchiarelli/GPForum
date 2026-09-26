# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use POSIX         qw(_exit);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostStore;
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
const my $BLOCK_POLLS        => 200;
const my $BLOCK_POLL_SECONDS => 0.05;
const my $RACE_TARGET_ID     => '018f9999-0001-7000-8000-00000000c001';
const my $REPORT_TARGET_ID   => '018f9999-0001-7000-8000-00000000c002';
const my $COMMAND_KEY        => '018f9999-0001-7000-8000-00000000c010';
const my $HIDE_COMMAND       => '018f9999-0001-7000-8000-00000000c011';
const my $LOCK_COMMAND       => '018f9999-0001-7000-8000-00000000c012';
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

local $ENV{GPFORUM_DATABASE_LOCK_TIMEOUT_MS}  = $LOCK_TIMEOUT_MS;
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

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
# number. Concurrent replies must all land, on the next positions, one each.
sub _reply_position_race {
    my ($ctx) = @_;

    my ($before) =
      $ctx->{dbh}
      ->selectrow_array( $LAST_POSITION_SQL, undef, $ctx->{reply_thread_id} );
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my ($slot) = @_;
            return _reply_once( $ctx, "concurrent reply $slot" );
        }
    );
    _assert_workers_ok( \@outcomes, 'reply position race' );

    my @positions =
      sort { $a <=> $b } map { $_->{result}{position} // 0 } @outcomes;
    is_deeply(
        \@positions,
        [
            map { $before + $_ }
              1 .. GPForum::Test::PostgresHarness::worker_count()
        ],
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

    my $outcome = _collect_reply($reply);
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

# PostgresHarness::race releases its workers together and waits for all of
# them, which leaves the parent no step while one is blocked. This forks one
# reply and returns at once, so the parent can see it wait and then commit.
sub _spawn_reply {
    my ( $ctx, $body ) = @_;

    pipe my $out_reader, my $out_writer or croak 'reply pipe failed';
    my $pid = fork;
    if ( !defined $pid ) {
        croak "fork failed: $OS_ERROR";
    }
    if ( $pid == 0 ) {
        close $out_reader or croak 'child reply reader close failed';
        my $result = eval { return _reply_once( $ctx, $body ) };
        my $payload =
          $result ? { ok => 1, result => $result } : { error => "$EVAL_ERROR" };
        print {$out_writer} encode_json($payload)
          or croak 'reply result write failed';
        close $out_writer or croak 'child reply writer close failed';

        # _exit skips the destructors that would close the parent's handles.
        _exit(0);
    }

    close $out_writer or croak 'parent reply writer close failed';
    return { out => $out_reader, pid => $pid };
}

sub _collect_reply {
    my ($child) = @_;

    local $INPUT_RECORD_SEPARATOR = undef;
    my $json = readline $child->{out};
    close $child->{out} or croak 'parent reply reader close failed';
    waitpid $child->{pid}, 0;

    return decode_json($json);
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
