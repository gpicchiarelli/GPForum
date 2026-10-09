# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostStore;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $PAGE          => 50;
const my $SEEDED        => 7;
const my $OTHER_THREADS => 99;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the reply count test';
}

# A listed thread says how many replies it has: its counter row's
# reply_count, read for each row of the page in the page's statement. A
# reply and a restore add one, a delete takes one off, and the opening post
# is not a reply.
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
my $store  = GPForum::Service::Forum::PostStore->new( schema => $schema );

my ( $thread, $category, $author ) = $dbh->selectrow_array(
        'SELECT thread_id, category_id, author_user_id FROM threads'
      . ' ORDER BY thread_id LIMIT 1' );
my ($opening) =
  $dbh->selectrow_array(
    'SELECT post_id FROM posts WHERE thread_id = ? AND position = 1',
    undef, $thread );

is( _in_category(),      $SEEDED, 'a seeded thread shows its counter' );
is( _on_the_home_page(), $SEEDED, 'on the home page as in its category' );

my $reply = _reply();
is( _in_category(),      $SEEDED + 1, 'a reply adds one' );
is( _on_the_home_page(), $SEEDED + 1, 'on the home page too' );
ok( _deleted( delete_post => $reply ), 'the reply is deleted' );
is( _in_category(), $SEEDED, 'a delete takes it off' );
ok( _deleted( restore_post => $reply ), 'the reply is restored' );
is( _in_category(), $SEEDED + 1, 'a restore adds it back' );
ok( _deleted( delete_post => $opening ), 'the opening post is deleted' );
is( _in_category(), $SEEDED + 1, 'the opening post is not a reply' );
ok( _deleted( restore_post => $opening ), 'the opening post is restored' );
is( _in_category(), $SEEDED + 1, 'nor is it one once restored' );

# Another thread's count is its own.
$dbh->do( 'UPDATE thread_counters SET reply_count = ? WHERE thread_id <> ?',
    undef, $OTHER_THREADS, $thread );
is( _in_category(), $SEEDED + 1, 'and only its own' );

# A thread with no counter row has no replies, not an unknown number of
# them; its next reply gives it one.
$dbh->do( 'DELETE FROM thread_counters WHERE thread_id = ?', undef, $thread );
is( _in_category(),      0, 'no counter is no replies' );
is( _on_the_home_page(), 0, 'on the home page too' );
_reply();
is( _in_category(), 1, 'a reply to it creates its counter' );

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _reply {
    my $composed = GPForum::Service::Forum::PostComposer->new->prepare(
        {
            allocate_position => 1,
            author_user_id    => $author,
            body_hash         => 'hash of a reply',
            body_source       => 'A reply',
            thread_id         => $thread,
        }
    );
    my $stored = $store->create_post( $composed->{command} );

    return $stored->{post}->get_column('post_id');
}

sub _deleted {
    my ( $method, $post_id ) = @_;

    my $writer = $method eq 'delete_post' ? 'deleted_by' : 'restored_by';

    return $store->$method(
        {
            idempotency_key => "$method $post_id",
            post            => {
                author_user_id => $author,
                post_id        => $post_id,
                thread_id      => $thread,
                $writer        => $author,
            },
        }
    )->{ok};
}

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

1;
