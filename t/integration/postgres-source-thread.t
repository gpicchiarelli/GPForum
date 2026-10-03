# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Community::MentionReader;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Forum::SourceThread;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $PAGE => 50;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the source thread test';
}

# A bookmark, a feed item, a mention and a notification point at a thread or
# a post, and their lists showed the id: "Thread 018f...", "Post 01a1...".
# Each list now carries the thread its row is about and that thread's title,
# when and only when it is cut to what its reader may read.
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
my $ids    = GPForum::Infrastructure::Id->new;
my $readability =
  GPForum::Service::Forum::Readability->new( schema => $schema );

my ( $thread, $title, $post ) = $dbh->selectrow_array(
        'SELECT t.thread_id, t.title, p.post_id FROM threads t'
      . ' JOIN posts p USING (thread_id) ORDER BY t.thread_id, p.position DESC'
      . ' LIMIT 1' );
my ( $member, $actor ) =
  @{ $dbh->selectcol_arrayref('SELECT id FROM users ORDER BY id LIMIT 2') };
my %about = ( thread => $thread, post => $post );

# The seed gave the member rows of its own; the lists below start empty.
for my $owned (
    [ bookmarks          => 'user_id' ],
    [ user_feed_items    => 'user_id' ],
    [ mentions           => 'mentioned_user_id' ],
    [ notification_inbox => 'recipient_user_id' ],
    [ notifications      => 'recipient_user_id' ],
  )
{
    my ( $table, $column ) = @{$owned};
    $dbh->do( "DELETE FROM $table WHERE $column = ?", undef, $member );
}

# The columns themselves, on a list of every kind of source.
my $gone = $ids->uuid;
_bookmark( thread => $thread );
_bookmark( post   => $post );
_bookmark( thread => $gone );
my %named = map {
    $_->get_column('target_id') => [
        $_->get_column('source_thread_id'),
        $_->get_column('source_thread_title'),
    ]
} $schema->resultset('Bookmark')->search(
    { user_id => $member },
    {
        GPForum::Service::Forum::SourceThread->attributes(
            1, 'me.target_type', 'me.target_id'
        )
    }
)->all;
is_deeply( $named{$thread}, [ $thread, $title ], 'a thread is itself' );
is_deeply(
    $named{$post},
    [ $thread, $title ],
    'a post is the thread it belongs to'
);
is_deeply(
    $named{$gone},
    [ $gone, undef ],
    'a thread that no longer exists has no title'
);
is_deeply( [ GPForum::Service::Forum::SourceThread->attributes( 0, 'a', 'b' ) ],
    [], 'a list not cut to what its reader may read gets no columns' );

# Each reader, with readability and without.
for my $kind ( sort keys %about ) {
    $dbh->do(
        'INSERT INTO user_feed_items (user_id, item_type, item_id, created_at,'
          . ' rank_score, visibility_version, permission_version)'
          . ' VALUES (?, ?, ?, now(), 1, 1, 1)',
        undef, $member, $kind, $about{$kind}
    );
    $dbh->do(
        'INSERT INTO mentions (mention_id, source_type, source_id, actor_id,'
          . ' mentioned_user_id, mentioned_username) VALUES (?, ?, ?, ?, ?, ?)',
        undef, $ids->uuid, $kind, $about{$kind}, $actor, $member, 'member'
    );

    # An inbox row and its notification share their id and their instant.
    my $notification = $ids->uuid;
    my ($now) = $dbh->selectrow_array('SELECT clock_timestamp()');
    $dbh->do(
        'INSERT INTO notifications (notification_id, recipient_user_id,'
          . ' source_type, source_id, notification_type, created_at)'
          . ' VALUES (?, ?, ?, ?, ?, ?)',
        undef, $notification, $member, $kind, $about{$kind}, 'reply', $now
    );
    $dbh->do(
        'INSERT INTO notification_inbox (recipient_user_id, notification_id,'
          . ' created_at) VALUES (?, ?, ?)',
        undef, $member, $notification, $now
    );
}

my %lists = (
    bookmarks => sub {
        my (%with) = @_;
        return GPForum::Service::Community::BookmarkStore->new(
            schema => $schema,
            %with
        )->bookmarks_resultset( $member, { limit => $PAGE } );
    },
    feed => sub {
        my (%with) = @_;
        return GPForum::Service::Community::FeedReader->new(
            schema => $schema,
            %with
        )->feed_resultset( $member, { limit => $PAGE } );
    },
    mentions => sub {
        my (%with) = @_;
        return GPForum::Service::Community::MentionReader->new(
            schema => $schema,
            %with
        )->mentions_resultset( $member, { limit => $PAGE } );
    },
    notifications => sub {
        my (%with) = @_;
        return GPForum::Service::Notification::Dispatcher->new(
            schema => $schema,
            %with
        )->inbox_resultset( $member, { limit => $PAGE } );
    },
);

for my $name ( sort keys %lists ) {
    my @rows = $lists{$name}->( readability => $readability )->all;
    is( scalar @rows, 2, "$name lists the thread and the post" );
    is_deeply(
        [ map { $_->get_column('source_thread_title') } @rows ],
        [ $title, $title ],
        "$name names the discussion of each"
    );
    is_deeply(
        [ map { $_->get_column('source_thread_id') } @rows ],
        [ $thread, $thread ],
        "$name leads to it"
    );

    my @unfiltered = $lists{$name}->()->all;
    ok( scalar @unfiltered, "$name without readability still lists" );
    ok(
        !( grep { $_->has_column_loaded('source_thread_title') } @unfiltered ),
        "$name without readability selects no title"
    );
}

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _bookmark {
    my ( $type, $id ) = @_;

    $dbh->do(
        'INSERT INTO bookmarks (bookmark_id, user_id, target_type, target_id,'
          . ' created_at) VALUES (?, ?, ?, ?, now())',
        undef, $ids->uuid, $member, $type, $id
    );

    return;
}

1;
