# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::FeedProjector;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $CROWD      => 5_000;
const my $STATEMENTS => 5;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the feed projection test';
}

# 8.7 on PostgreSQL: a feed item reaches every recipient in one statement,
# however many there are, refreshes a row only when it changed, and is
# idempotent -- a retried event writes nothing new.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
my $projector =
  GPForum::Service::Community::FeedProjector->new( schema => $schema );
my ( $reader, $author ) =
  @{ $dbh->selectcol_arrayref('SELECT id FROM users ORDER BY id LIMIT 2') };
my ($post) = $dbh->selectrow_array('SELECT post_id FROM posts LIMIT 1');
my %item = (
    created_at => '2026-05-23T12:00:00Z',
    item_id    => $post,
    item_type  => 'post',
);

my $projected =
  $projector->project_item(
    { %item, user_ids => [ $reader, $author, $reader ] } );
is_deeply(
    [ @{$projected}{qw(projected written)} ],
    [ 2, 2 ],
    'each recipient once, whatever the duplicates'
);
is( _rows(), 2, 'two feed rows' );

is(
    $projector->project_item( { %item, user_ids => [ $reader, $author ] } )
      ->{written},
    0,
    'an unchanged item writes nothing: a retried event is harmless'
);
is(
    $projector->project_item(
        { %item, user_ids => [ $reader, $author ], visibility_version => 2 }
    )->{written},
    2,
    'a changed item refreshes the rows'
);
is( _rows(), 2, 'in place' );

$dbh->do(
    q{INSERT INTO users (id, username, display_name, email_normalized,}
      . q{ password_hash, status) SELECT gen_random_uuid(), 'crowd-' || n,}
      . q{ 'Crowd ' || n, 'crowd-' || n || '@example.test', 'x', 'active'}
      . q{ FROM generate_series(1, ?) AS n},
    undef, $CROWD
);
my $crowd = $dbh->selectcol_arrayref(
    q{SELECT id FROM users WHERE username LIKE 'crowd-%'});
my $statements = _statements(
    sub {
        $projector->project_item(
            { %item, item_id => $post, user_ids => $crowd } );
    }
);
is( _rows(), 2 + $CROWD, "$CROWD subscribers get the item" );
cmp_ok( $statements, q{<=}, $STATEMENTS,
    'in one statement, not two per subscriber' );

# A thread leaves every feed with all its posts: one statement for the
# posts, by the (item_type, item_id) index, not a full scan per post.
my ($thread) =
  $dbh->selectrow_array( 'SELECT thread_id FROM posts WHERE post_id = ?',
    undef, $post );
my $thread_posts =
  $dbh->selectcol_arrayref( 'SELECT post_id FROM posts WHERE thread_id = ?',
    undef, $thread );
for my $item ( @{$thread_posts} ) {
    $projector->project_item(
        { %item, item_id => $item, user_ids => [ $reader, $author ] } );
}
$projector->project_item(
    {
        %item,
        item_id   => $thread,
        item_type => 'thread',
        user_ids  => [ $reader, $author ],
    }
);
my $removal = _statements( sub { $projector->remove_thread($thread) } );
is(
    scalar $dbh->selectrow_array(
        q{SELECT count(*) FROM user_feed_items WHERE item_id = ?}
          . q{ OR item_id IN (SELECT post_id FROM posts WHERE thread_id = ?)},
        undef,
        $thread,
        $thread
    ),
    0,
    'removing a thread removes it and its posts from every feed'
);
cmp_ok( $removal, q{<=}, $STATEMENTS, 'in a fixed number of statements' );
ok(
    scalar $dbh->selectrow_array(
            q{SELECT count(*) FROM pg_indexes WHERE indexname =}
          . q{ 'idx_user_feed_items_item'}
    ),
    'by the index migration 047 adds'
);

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _rows {
    return
      scalar $dbh->selectrow_array(
        'SELECT count(*) FROM user_feed_items WHERE item_id = ?',
        undef, $post );
}

# Statements the projector sent, counted on the database handle: every
# statement is prepared or done through it.
sub _statements {
    my ($work) = @_;

    my $sent = 0;
    $dbh->{Callbacks} = {
        do             => sub { $sent++; return; },
        prepare        => sub { $sent++; return; },
        prepare_cached => sub { $sent++; return; },
    };
    $work->();
    delete $dbh->{Callbacks};

    return $sent;
}

1;
