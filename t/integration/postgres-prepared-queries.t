# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Attachment::Store;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::ReadState;
use GPForum::Service::Identity::SessionStore;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Service::Forum::ThreadDetailReader;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Operations::DbQueryStats;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $PAGE        => 5;
const my $ALL         => 50;
const my $KEY_LOOKUPS => 3;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the prepared query test';
}

# A reader's statement is built once per shape and run with the request's
# values (Infrastructure::PreparedQuery). What it answers must be what the
# resultset answers, row for row and column for column, for every shape:
# every standing of the viewer, with and without their own deleted posts,
# the first page and a page after a cursor; and the thread's row.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $stats  = GPForum::Service::Operations::DbQueryStats->new;
$stats->attach_to_schema($schema);

my $posts   = GPForum::Service::Forum::PostReader->new( schema => $schema );
my $threads = GPForum::Service::Forum::ThreadDetailReader->new(
    post_reader => $posts,
    schema      => $schema,
);

my $dbh = $schema->storage->dbh;
my ( $thread, $author ) = $dbh->selectrow_array(
    'SELECT thread_id, author_user_id FROM threads ORDER BY thread_id LIMIT 1');
my ($other) = $dbh->selectrow_array(
    'SELECT id FROM users WHERE id <> ? ORDER BY id LIMIT 1',
    undef, $author );

# One of the author's replies is deleted: the author still lists it, the
# others do not, and the prepared statement must know the difference.
my ($deleted) = $dbh->selectrow_array(
    'SELECT post_id FROM posts WHERE thread_id = ? AND author_user_id = ?'
      . ' AND position > 1 ORDER BY position LIMIT 1',
    undef, $thread, $author
);
$dbh->do( 'UPDATE posts SET deleted_at = now() WHERE post_id = ?',
    undef, $deleted );

my %viewer = (
    anonymous => GPForum::Service::Forum::Viewer->anonymous,
    member    => GPForum::Service::Forum::Viewer->new(
        member  => 1,
        user_id => $other,
    ),
    author => GPForum::Service::Forum::Viewer->new(
        member  => 1,
        user_id => $author,
    ),
    moderator => GPForum::Service::Forum::Viewer->new(
        global_read => 1,
        member      => 1,
        user_id     => $other,
    ),
);

for my $standing ( sort keys %viewer ) {
    my $request = {
        limit          => $PAGE,
        thread_id      => $thread,
        viewer_scope   => $viewer{$standing},
        viewer_user_id => $viewer{$standing}->user_id,
    };
    my $first = _same_rows( $request, "$standing, first page" );
    _same_rows( { %{$request}, after => $first->{next_cursor} },
        "$standing, after a cursor" );
}

ok(
    (
        grep { $_->get_column('post_id') eq $deleted } @{
            $posts->list_thread_posts(
                {
                    limit          => $ALL,
                    thread_id      => $thread,
                    viewer_scope   => $viewer{author},
                    viewer_user_id => $author,
                }
            )->{items}
        }
    ),
    'the author lists their deleted reply'
);
ok(
    !(
        grep { $_->get_column('post_id') eq $deleted } @{
            $posts->list_thread_posts(
                {
                    limit          => $ALL,
                    thread_id      => $thread,
                    viewer_scope   => $viewer{member},
                    viewer_user_id => $other,
                }
            )->{items}
        }
    ),
    'another member does not'
);

# The thread's row, and a thread that is not there.
my $thread_row = $threads->find_thread_row($thread);
my $expected   = $threads->thread_row_resultset($thread)->first;
is_deeply(
    _columns( $thread_row, _thread_names() ),
    _columns( $expected,   _thread_names() ),
    'the prepared thread row is the resultset row'
);
is( $threads->find_thread_row('018f1004-ffff-7000-8000-00000000ffff'),
    undef, 'a thread that is not there is not found' );

# Each run is one statement the statistics see, as the resultset's would be.
my $before = $stats->{total_queries};
$posts->list_thread_posts(
    {
        limit          => $ALL,
        thread_id      => $thread,
        viewer_scope   => $viewer{member},
        viewer_user_id => $other
    }
);
$threads->find_thread_row($thread);
is( $stats->{total_queries} - $before,
    2, 'two prepared runs are two statements to the statistics' );

# The lookups by a key a signed-in page runs -- the viewer's read state,
# bookmark and subscription for the thread, and the session the cookie
# names -- are prepared the same way: a miss is undef, a hit is the row
# find answers, column for column, and each is one statement.
my $read_state = GPForum::Service::Forum::ReadState->new( schema => $schema );
my $bookmarks =
  GPForum::Service::Community::BookmarkStore->new( schema => $schema );
my $subscriptions =
  GPForum::Service::Notification::SubscriptionStore->new( schema => $schema );
my $sessions =
  GPForum::Service::Identity::SessionStore->new( schema => $schema );
my %target =
  ( target_id => $thread, target_type => 'thread', user_id => $other );

is( $bookmarks->find_for_user_target( $other, 'thread', $thread ),
    undef, 'no bookmark is no row' );
is( $subscriptions->find_for_user_target( $other, 'thread', $thread ),
    undef, 'no subscription is no row' );

$bookmarks->save_bookmark( { %target, note => 'kept' } );
$subscriptions->save_subscription( {%target} );
$read_state->mark_thread_read(
    { last_read_position => 2, thread_id => $thread, user_id => $other } );
my $member  = $schema->resultset('User')->find($other);
my $session = $sessions->create_session( $member,
    { request_address => '127.0.0.1', user_agent => 'prepared-queries.t' } );
my $session_id = $session->{session}->get_column('session_id');

_same_row(
    $bookmarks->find_for_user_target( $other, 'thread', $thread ),
    $schema->resultset('Bookmark')->find( \%target ),
    'the bookmark'
);
_same_row(
    $subscriptions->find_for_user_target( $other, 'thread', $thread ),
    $schema->resultset('Subscription')->find( \%target ),
    'the subscription'
);
is_deeply(
    $read_state->state_for_thread( $other, $thread ),
    {
        map {
            $_ => $schema->resultset('ThreadReadState')
              ->find( { thread_id => $thread, user_id => $other } )
              ->get_column($_)
        } qw(user_id thread_id last_read_position last_read_at)
    },
    'the read state is the row find answers'
);
is(
    $sessions->validate_session(
        {
            session_id    => $session_id,
            session_token => $session->{session_token},
            user_id       => $other,
        }
    )->{ok},
    1,
    'the session is found by its id and its member'
);
is(
    $sessions->validate_session(
        {
            session_id    => $session_id,
            session_token => $session->{session_token},
            user_id       => $author,
        }
    )->{error},
    'not_found',
    'and not by another member'
);

# The category by its id, with its space's visibility, and one listed post
# as the page lists it: prepared like the rest, and a malformed id finds
# nothing without a statement.
my $categories =
  GPForum::Service::Forum::CategoryReader->new( schema => $schema );
my ($category) =
  $dbh->selectrow_array( 'SELECT category_id FROM threads WHERE thread_id = ?',
    undef, $thread );
my $with_space = {
    join      => 'space',
    '+select' => ['space.visibility'],
    '+as'     => ['space_visibility'],
};
is_deeply(
    _columns(
        $categories->find_category( $category, $viewer{member} ),
        [ 'category_id', 'title', 'space_visibility' ]
    ),
    _columns(
        $schema->resultset('Category')->find( $category, $with_space ),
        [ 'category_id', 'title', 'space_visibility' ]
    ),
    'the prepared category is the row find answers, with its space'
);
my ($listed) = @{
    $posts->list_thread_posts(
        {
            limit          => $ALL,
            thread_id      => $thread,
            viewer_scope   => $viewer{member},
            viewer_user_id => $other,
        }
    )->{items}
};
my $one = $posts->find_listed_post(
    {
        post_id        => $listed->get_column('post_id'),
        thread_id      => $thread,
        viewer_scope   => $viewer{member},
        viewer_user_id => $other,
    }
);
is_deeply(
    _columns( $one,    _post_names() ),
    _columns( $listed, _post_names() ),
    'the prepared listed post is the listed row'
);
$before = $stats->{total_queries};
is( $categories->find_category( 'not-a-uuid', $viewer{member} ),
    undef, 'a malformed category id finds nothing' );
is(
    $posts->find_listed_post(
        {
            post_id        => 'not-a-uuid',
            thread_id      => $thread,
            viewer_scope   => $viewer{member},
            viewer_user_id => $other,
        }
    ),
    undef,
    'as does a malformed post id'
);
is( $stats->{total_queries} - $before, 0, 'and neither sent a statement' );

# The page's attachments: one statement whose IN list the page's post ids
# fill, kept by page size, answering what the resultset answers.
my $attachments = GPForum::Service::Attachment::Store->new( schema => $schema );
my @post_ids    = map { $_->get_column('post_id') } @{
    $posts->list_thread_posts(
        {
            limit          => $ALL,
            thread_id      => $thread,
            viewer_scope   => $viewer{member},
            viewer_user_id => $other,
        }
    )->{items}
};
$before = $stats->{total_queries};
my $by_post = $attachments->attachments_for_posts( \@post_ids,
    { viewer => $viewer{member}, viewer_user_id => $other } );
is( $stats->{total_queries} - $before,
    1, 'the attachments of a page are one statement' );
is_deeply( $by_post, {}, 'and the seed has none to list' );
is_deeply(
    $attachments->attachments_for_posts(
        [ 'not-a-uuid', @post_ids ],
        { viewer => $viewer{member}, viewer_user_id => $other }
    ),
    {},
    'a post id that is not a uuid among them finds nothing'
);

$before = $stats->{total_queries};
$bookmarks->find_for_user_target( $other, 'thread', $thread );
$subscriptions->find_for_user_target( $other, 'thread', $thread );
$read_state->state_for_thread( $other, $thread );
is( $stats->{total_queries} - $before,
    $KEY_LOOKUPS, 'three key lookups are three statements to the statistics' );

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

# The rows the prepared statement answers against the resultset's, by every
# column the reader names.
sub _same_rows {
    my ( $request, $label ) = @_;

    my $page     = $posts->list_thread_posts($request);
    my $plan     = $posts->page_window->plan($request);
    my @expected = $posts->thread_posts_resultset( $request, $plan )->all;
    if ( @expected > $plan->{limit} ) {
        splice @expected, $plan->{limit};
    }

    is_deeply(
        [ map { _columns( $_, _post_names() ) } @{ $page->{items} } ],
        [ map { _columns( $_, _post_names() ) } @expected ],
        "$label: the prepared rows are the resultset's"
    );
    cmp_ok( scalar @{ $page->{items} }, '>', 0, "$label: and there are rows" );

    return $page;
}

# A prepared row against the row find answers, by every column of its
# source.
sub _same_row {
    my ( $answered, $found, $label ) = @_;

    my $names = [ $found->result_source->columns ];
    is_deeply(
        _columns( $answered, $names ),
        _columns( $found,    $names ),
        "$label the prepared lookup answers is the row find answers"
    );

    return;
}

sub _columns {
    my ( $row, $names ) = @_;

    return { map { $_ => $row->get_column($_) } @{$names} };
}

sub _post_names {
    return [
        qw(
          post_id thread_id author_user_id current_body_id position
          visibility moderation_state created_at deleted_at
          body body_source author_username author_display_name
        )
    ];
}

sub _thread_names {
    return [
        qw(
          thread_id category_id author_user_id title slug pinned
          visibility moderation_state locked_at last_activity_at deleted_at
          author_username author_display_name category_title
          category_visibility space_id space_visibility
        )
    ];
}

1;
