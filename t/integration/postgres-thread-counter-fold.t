# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use DBD::Pg    qw(:async);
use Mojo::File qw(path);
use Test::More;
use Time::HiRes qw(sleep);

use lib 'lib';
use lib 't/lib';

use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $MIGRATION         => 'migrations/051_fold_thread_counter_shards.sql';
const my $TRIGGER           => 'thread_counter_shards_into_counters';
const my $SEEDED            => 7;
const my $RESIDUAL          => 3;
const my $ORPHANED          => 2;
const my $TAKEN_OFF         => -1;
const my $TWICE_OFF         => -2;
const my $WAIT_POLLS        => 40;
const my $WAIT_POLL_SECONDS => 0.05;

# What the previous release's PostStore sends for a reply, a delete and a
# restore, as DBIx::Class wrote it (DBIC_TRACE): a shard row inserted when
# the thread has none, else updated in SQL; a delete or restore updates the
# post row first, in the same transaction.
const my $OLD_INSERT_SQL => 'INSERT INTO thread_counter_shards'
  . ' ( reply_count_delta, shard_id, thread_id) VALUES ( ?, ?, ? )';
const my $OLD_UPDATE_SQL => 'UPDATE thread_counter_shards'
  . ' SET last_updated_at = now(), reply_count_delta = reply_count_delta + ?'
  . ' WHERE ( ( shard_id = ? AND thread_id = ? ) )';
const my $OLD_DELETE_POST_SQL =>
  'UPDATE posts SET deleted_at = ?, deleted_by = ?, version = ?'
  . ' WHERE ( post_id = ? )';

const my $OLD_REPLY_POST_SQL => 'INSERT INTO posts'
  . ' (post_id, thread_id, author_user_id, position)'
  . ' SELECT gen_random_uuid(), thread_id, author_user_id,'
  . ' (SELECT max(position) + 1 FROM posts WHERE thread_id = ?)'
  . ' FROM posts WHERE thread_id = ? AND position = 1';

# What this release's PostStore sends for a reply's count.
const my $NEW_REPLY_COUNT_SQL => 'UPDATE thread_counters'
  . ' SET reply_count = GREATEST(reply_count + 1, 0) WHERE thread_id = ?';

# What the previous release's ThreadReader showed, and what this one shows.
const my $OLD_READER_SQL => 'SELECT'
  . ' COALESCE((SELECT reply_count FROM thread_counters c'
  . ' WHERE c.thread_id = t.thread_id), 0)'
  . ' + COALESCE((SELECT SUM(reply_count_delta) FROM thread_counter_shards s'
  . ' WHERE s.thread_id = t.thread_id), 0)'
  . ' FROM threads t WHERE t.thread_id = ?';
const my $COUNTER_SQL =>
  'SELECT reply_count FROM thread_counters WHERE thread_id = ?';
const my $LIVE_REPLIES_SQL => 'SELECT count(*) FROM posts'
  . ' WHERE thread_id = ? AND position > 1 AND deleted_at IS NULL';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the counter fold test';
}

# Migration 051 moves the reply count out of thread_counter_shards while the
# previous release still runs: a deploy migrates, then restarts. This replays
# it from the state that release left -- deltas in the shards, an opening
# post deleted and counted -- with one of its writes in flight, then writes
# what that release writes after it, and checks that both releases' readers
# show every thread its replies throughout.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $dbh = GPForum::Test::PostgresHarness::connect_dbi( $database->{dsn} );
my @threads =
  @{ $dbh->selectcol_arrayref('SELECT thread_id FROM threads ORDER BY 1') };
my ( $plain, $deleted_opening, $uncounted, $floor, $in_flight, $later,
    $reopened_thread )
  = @threads;
is( _trigger_count(), 1, 'migration 051 leaves the trigger on the shards' );

# The schema as migration 050 left it.
$dbh->do("DROP TRIGGER $TRIGGER ON thread_counter_shards");
$dbh->do("DROP FUNCTION $TRIGGER()");

# What the previous release wrote: three replies' deltas, and on another
# thread a reply and the opening post deleted, one off each. A third thread
# lost its counter row, a fourth would go below zero.
_old_write( $plain, $RESIDUAL );
_delete_post( _post( $deleted_opening, 1 ) );
_delete_post( _post( $deleted_opening, 2 ) );
_old_write( $deleted_opening, $TWICE_OFF );
$dbh->do( 'DELETE FROM thread_counters WHERE thread_id = ?', undef,
    $uncounted );
_old_write( $uncounted, $ORPHANED );
$dbh->do( 'UPDATE thread_counters SET reply_count = 0 WHERE thread_id = ?',
    undef, $floor );
_old_write( $floor, $TAKEN_OFF );
is(
    _old_reader($deleted_opening),
    $SEEDED - 2,
    'the previous release took one off for the opening post'
);

# What the previous release showed for every thread before 051, with the
# reply in flight below counted, is what 051 leaves in the counter; but a
# count it took below zero is zero, and a thread whose opening post is
# deleted counts the reply it took off for it.
my %shown = map { $_ => _old_reader($_) } @threads;
for my $counted ( $plain, $in_flight, $deleted_opening ) {
    $shown{$counted}++;
}
$shown{$floor} = 0;

# A reply of the previous release in flight while the migration runs: the
# trigger waits for it, and its delta is folded once it commits.
my $writer = GPForum::Test::PostgresHarness::connect_dbi( $database->{dsn} );
$writer->begin_work;
$writer->do( $OLD_UPDATE_SQL, undef, 1, 0, $plain );
$writer->do( $OLD_INSERT_SQL, undef, 1, 0, $in_flight );
my $migrator = GPForum::Test::PostgresHarness::connect_dbi( $database->{dsn} );
$migrator->do( path($MIGRATION)->slurp, { pg_async => PG_ASYNC } );
ok( _waits_on_a_lock($migrator),
    'the migration waits for the reply in flight' );
$writer->commit;
ok( $migrator->pg_result, 'the migration runs once the reply commits' );

# Thread ids are UUIDv7: the first digit is the clock's, the same for every
# thread, so the fold splits on the last. A thread whose delta it moved
# carries the transaction that moved it, one for each last digit.
my @folded      = ( $plain, $uncounted, $floor, $in_flight );
my %last_digits = map { substr( $_, length() - 1 ) => 1 } @folded;
is(
    _fold_transactions(@folded),
    scalar keys %last_digits,
    'the deltas are folded in one transaction for each last digit of the id'
);

is(
    _counter($plain),
    $SEEDED + $RESIDUAL + 1,
    'the deltas, the one in flight included, are added to the counter'
);
is(
    _counter($in_flight),
    $SEEDED + 1,
    'a shard row the reply in flight inserted is folded too'
);
is(
    _counter($deleted_opening),
    _live_replies($deleted_opening),
    'a thread whose opening post is deleted counts its replies'
);
is(
    _counter($deleted_opening),
    $SEEDED - 1,
    'which the deleted opening post is not one of'
);
is( _counter($uncounted), $ORPHANED,
    'a thread without a counter row gets one' );
is( _counter($floor), 0, 'a counter does not go below zero' );
is(
    $dbh->selectrow_array(
'SELECT count(*) FROM thread_counter_shards WHERE reply_count_delta <> 0'
    ),
    0,
    'every shard row is left at zero'
);
_assert_readers_agree('after the migration');
is_deeply( { map { $_ => _counter($_) } @threads },
    \%shown, 'every thread counts what the previous release showed' );

my %folded = map { $_ => _counter($_) } @threads;
$dbh->do( path($MIGRATION)->slurp );
is_deeply( { map { $_ => _counter($_) } @threads },
    \%folded, 'running the migration again changes nothing' );

# The previous release keeps serving until its workers are gone. Each write
# it makes lands in the counter, and the shard row stays at zero.
_old_reply($later);
is( _counter($later), $SEEDED + 1, 'its reply to a thread without a shard' );
_old_reply($later);
is( _counter($later), $SEEDED + 2, 'its reply to a thread with one' );
my $reply = _post( $later, 2 );
_old_delete( $reply, $TAKEN_OFF );
is( _counter($later), $SEEDED + 1, 'its delete of a reply' );
_old_delete( $reply, 1, 'restore' );
is( _counter($later), $SEEDED + 2, 'its restore of a reply' );
my $opening = _post( $later, 1 );
_old_delete( $opening, $TAKEN_OFF );
is(
    _counter($later),
    $SEEDED + 2,
    'its delete of the opening post leaves the count'
);
_old_delete( $opening, 1, 'restore' );
is(
    _counter($later),
    $SEEDED + 2,
    'and so does its restore of the opening post'
);
is( $dbh->do( $OLD_UPDATE_SQL, undef, $TAKEN_OFF, 0, $floor ),
    1, 'a delta that would take a counter below zero still updates its row' );
is( _counter($floor), 0, 'and leaves the counter at zero' );
_assert_readers_agree('after the previous release wrote');

# An opening post the previous release deleted before the trigger, and
# restores once it is there: before 051 folds that delete's -1, or after it
# folded it but before the recount reads which openings are deleted. Either
# way the recount does not see that thread, so the restore must settle it.
$dbh->do("DROP TRIGGER $TRIGGER ON thread_counter_shards");
my $reopened = _post( $reopened_thread, 1 );
_old_delete( $reopened, $TAKEN_OFF );
$reopened->{version}++;
my ($trigger_step) =
  path($MIGRATION)->slurp =~ m{\A (.*? CREATE [ ] OR [ ] REPLACE [ ] TRIGGER
    .*? ^COMMIT;) }msx;
$dbh->do($trigger_step);
_old_delete( $reopened, 1, 'restore' );
$dbh->do( path($MIGRATION)->slurp );
is(
    _counter($reopened_thread),
    _live_replies($reopened_thread),
    'an opening post deleted before the trigger and restored after it'
);
is( _counter($reopened_thread),
    $SEEDED, 'leaves every reply counted, the opening post not' );
_assert_readers_agree('after an opening post deleted before 051 came back');

# Counting again races this release's reply in flight, which holds the
# counter row and no shard row: the count waits for that row, then reads
# the posts as they are once the reply commits.
$writer->begin_work;
$writer->do( $OLD_REPLY_POST_SQL, undef, $reopened_thread, $reopened_thread );
$writer->do( $NEW_REPLY_COUNT_SQL, undef, $reopened_thread );
$migrator->begin_work;
$migrator->do(
    $OLD_DELETE_POST_SQL,     undef,
    '2026-10-04T12:00:00Z',   $reopened->{author},
    $reopened->{version} + 2, $reopened->{post_id}
);
my $old_delta = $OLD_UPDATE_SQL =~ s{[?]}{%s}gmsxr;
$migrator->do(
    sprintf( $old_delta, $TAKEN_OFF, 0, $migrator->quote($reopened_thread) ),
    { pg_async => PG_ASYNC } );
ok( _waits_on_a_lock($migrator),
    'counting again waits for the counter row a reply in flight holds' );
$writer->commit;
$migrator->pg_result;
$migrator->commit;
is(
    _counter($reopened_thread),
    $SEEDED + 1,
    'and counts that reply once it commits'
);
_assert_readers_agree('after an opening post delete raced a reply');

$writer->disconnect;
$migrator->disconnect;
$dbh->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _trigger_count {
    return
      scalar $dbh->selectrow_array(
        'SELECT count(*) FROM pg_trigger WHERE tgname = ?',
        undef, $TRIGGER );
}

sub _old_write {
    my ( $thread, $delta ) = @_;

    my $updated = $dbh->do( $OLD_UPDATE_SQL, undef, $delta, 0, $thread );
    if ( $updated == 0 ) {
        $dbh->do( $OLD_INSERT_SQL, undef, $delta, 0, $thread );
    }

    return;
}

# The previous release's reply, in one transaction: the post row, then the
# shard.
sub _old_reply {
    my ($thread) = @_;

    $dbh->begin_work;
    $dbh->do( $OLD_REPLY_POST_SQL, undef, $thread, $thread );
    _old_write( $thread, 1 );
    $dbh->commit;

    return;
}

# The previous release's delete (-1) or restore (+1) of a post, in one
# transaction: the post row, then the shard.
sub _old_delete {
    my ( $post, $delta, $restore ) = @_;

    $dbh->begin_work;
    $dbh->do(
        $OLD_DELETE_POST_SQL,
        undef,
        $restore
        ? ( undef, undef )
        : ( '2026-10-04T12:00:00Z', $post->{author} ),
        $post->{version} + 1,
        $post->{post_id}
    );
    _old_write( $post->{thread_id}, $delta );
    $dbh->commit;

    return;
}

sub _delete_post {
    my ($post) = @_;

    $dbh->do(
        $OLD_DELETE_POST_SQL,   undef,
        '2026-10-04T12:00:00Z', $post->{author},
        $post->{version} + 1,   $post->{post_id}
    );

    return;
}

sub _post {
    my ( $thread, $position ) = @_;

    return $dbh->selectrow_hashref(
        'SELECT post_id, thread_id, author_user_id AS author, version'
          . ' FROM posts WHERE thread_id = ? AND position = ?',
        undef, $thread, $position
    );
}

sub _waits_on_a_lock {
    my ($handle) = @_;

    for ( 1 .. $WAIT_POLLS ) {
        return 1
          if $dbh->selectrow_array(
            q{SELECT count(*) FROM pg_stat_activity}
              . q{ WHERE pid = ? AND wait_event_type = 'Lock'},
            undef, $handle->{pg_pid}
          );
        sleep $WAIT_POLL_SECONDS;
    }

    return 0;
}

sub _fold_transactions {
    my @thread_ids = @_;

    return scalar $dbh->selectrow_array(
        'SELECT count(DISTINCT xmin::text) FROM thread_counters'
          . ' WHERE thread_id = ANY (?)',
        undef, \@thread_ids
    );
}

sub _counter {
    my ($thread) = @_;

    return scalar $dbh->selectrow_array( $COUNTER_SQL, undef, $thread );
}

sub _live_replies {
    my ($thread) = @_;

    return scalar $dbh->selectrow_array( $LIVE_REPLIES_SQL, undef, $thread );
}

sub _old_reader {
    my ($thread) = @_;

    return scalar $dbh->selectrow_array( $OLD_READER_SQL, undef, $thread );
}

sub _assert_readers_agree {
    my ($label) = @_;

    is_deeply(
        [ map { _old_reader($_) } @threads ],
        [ map { _counter($_) // 0 } @threads ],
        "both releases' readers show the same counts $label"
    );

    return;
}

1;
