# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ThreadReader;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $PAGE          => 50;
const my $SEEDED        => 7;
const my $WRITTEN       => 2;
const my $DELETED       => -1;
const my $WITH_DELTAS   => 8;
const my $OTHER_THREADS => 99;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the reply count test';
}

# A listed thread says how many replies it has. The number was stored all
# along and never shown: the counter row holds a total, and each reply,
# delete and restore leaves a delta in the shards that nothing folds into it.
# The readers add the two, for each row of the page, in the page's statement.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
my $reader = GPForum::Service::Forum::ThreadReader->new( schema => $schema );

my ( $thread, $category ) = $dbh->selectrow_array(
    'SELECT thread_id, category_id FROM threads ORDER BY thread_id LIMIT 1');

is( _in_category(),      $SEEDED, 'a seeded thread shows its counter' );
is( _on_the_home_page(), $SEEDED, 'on the home page as in its category' );

# What the application writes: one delta for each reply, and one back for a
# reply its author deleted. More than one shard may hold them.
_add_delta( 0, $WRITTEN );
_add_delta( 1, $DELETED );
is( _in_category(), $WITH_DELTAS,
    'deltas in every shard are added to the counter' );
is( _on_the_home_page(), $WITH_DELTAS, 'on the home page too' );

# Another thread's deltas are its own.
$dbh->do(
    'INSERT INTO thread_counter_shards (thread_id, shard_id,'
      . ' reply_count_delta) SELECT thread_id, 0, ? FROM threads'
      . ' WHERE thread_id <> ?',
    undef, $OTHER_THREADS, $thread
);
is( _in_category(), $WITH_DELTAS, 'and only its own' );

# A thread the application created has deltas and a counter still at zero; one
# with neither has no replies, not an unknown number of them.
$dbh->do( 'UPDATE thread_counters SET reply_count = 0 WHERE thread_id = ?',
    undef, $thread );
is( _in_category(), 1, 'a counter at zero leaves the deltas' );
$dbh->do( 'DELETE FROM thread_counter_shards WHERE thread_id = ?',
    undef, $thread );
$dbh->do( 'DELETE FROM thread_counters WHERE thread_id = ?', undef, $thread );
is( _in_category(),      0, 'no counter and no delta is no replies' );
is( _on_the_home_page(), 0, 'on the home page too' );

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _in_category {
    my $page = $reader->list_category_threads(
        { category_id => $category, limit => $PAGE } );

    return _reply_count($page);
}

sub _on_the_home_page {
    return _reply_count( $reader->list_public_threads( { limit => $PAGE } ) );
}

sub _reply_count {
    my ($page) = @_;

    my ($listed) =
      grep { $_->get_column('thread_id') eq $thread } @{ $page->{items} };

    return $listed ? $listed->get_column('reply_count') : undef;
}

sub _add_delta {
    my ( $shard, $delta ) = @_;

    $dbh->do(
        'INSERT INTO thread_counter_shards (thread_id, shard_id,'
          . ' reply_count_delta) VALUES (?, ?, ?)',
        undef, $thread, $shard, $delta
    );

    return;
}

1;
