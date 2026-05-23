package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadRow;
use GPForum::Test::ForumReadSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 28;
const my $DEFAULT_LIMIT  => 25;
const my $MAX_LIMIT      => 100;
const my $REQUEST_LIMIT  => 2;

plan tests => $EXPECTED_TESTS;

my $page_window  = GPForum::Service::Forum::PageWindow->new;
my $default_plan = $page_window->plan( {} );

is( $default_plan->{limit}, $DEFAULT_LIMIT, 'page window defaults limit' );
is(
    $default_plan->{fetch_rows},
    $DEFAULT_LIMIT + 1,
    'page window fetches one extra row'
);

my $bounded_plan = $page_window->plan( { limit => $MAX_LIMIT + 1 } );
is( $bounded_plan->{limit}, $MAX_LIMIT, 'page window clamps max limit' );

my $low_plan = $page_window->plan( { limit => 0 } );
is( $low_plan->{limit}, 1, 'page window clamps minimum limit' );

my $thread_rows = [
    _row(
        {
            thread_id        => 'thread-3',
            last_activity_at => '2026-05-23T12:03:00Z',
        }
    ),
    _row(
        {
            thread_id        => 'thread-2',
            last_activity_at => '2026-05-23T12:02:00Z',
        }
    ),
    _row(
        {
            thread_id        => 'thread-1',
            last_activity_at => '2026-05-23T12:01:00Z',
        }
    ),
];
my $thread_page =
  $page_window->page( $thread_rows, $REQUEST_LIMIT,
    [ 'last_activity_at', 'thread_id' ] );

is( scalar @{ $thread_page->{items} }, $REQUEST_LIMIT, 'page trims extra row' );
ok( $thread_page->{has_next},    'page marks next page' );
ok( $thread_page->{next_cursor}, 'page emits next cursor' );

my $decoded_plan =
  $page_window->plan( { after => $thread_page->{next_cursor} } );
is( $decoded_plan->{after}{sort_value},
    '2026-05-23T12:02:00Z', 'cursor stores sort value' );
is( $decoded_plan->{after}{id}, 'thread-2', 'cursor stores id' );

my $post_rows = [
    _row( { post_id => 'post-1', position => 1 } ),
    _row( { post_id => 'post-2', position => 2 } ),
    _row( { post_id => 'post-3', position => 3 } ),
];
my $post_page =
  $page_window->page( $post_rows, $REQUEST_LIMIT, [ 'position', 'post_id' ] );
is( scalar @{ $post_page->{items} },
    $REQUEST_LIMIT, 'post page trims extra row' );
ok( $post_page->{next_cursor}, 'post page emits cursor' );

my $thread_resultset =
  GPForum::Test::ForumReadResultSet->new( rows => $thread_rows, );
my $post_resultset =
  GPForum::Test::ForumReadResultSet->new( rows => $post_rows, );
my $schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Thread => $thread_resultset,
        Post   => $post_resultset,
    },
);
my $thread_reader =
  GPForum::Service::Forum::ThreadReader->new( schema => $schema, );
my $category_page = $thread_reader->list_category_threads(
    {
        category_id => 'category-1',
        limit       => $REQUEST_LIMIT,
    }
);

is( scalar @{ $category_page->{items} },
    $REQUEST_LIMIT, 'thread reader returns page items' );
is( $thread_resultset->last_query->{category_id},
    'category-1', 'thread reader filters category' );
is( $thread_resultset->last_query->{deleted_at},
    undef, 'thread reader excludes deleted threads' );
is( $thread_resultset->last_query->{moderation_state},
    'visible', 'thread reader filters visible threads' );
is(
    $thread_resultset->last_attrs->{rows},
    $REQUEST_LIMIT + 1,
    'thread reader fetches limit plus one'
);
is( $thread_resultset->last_attrs->{order_by}[1]{-desc},
    'last_activity_at', 'thread reader uses activity keyset order' );

my $next_category_page = $thread_reader->list_category_threads(
    {
        category_id => 'category-1',
        limit       => $REQUEST_LIMIT,
        after       => $category_page->{next_cursor},
    }
);

ok(
    $thread_resultset->last_query->{-or},
    'thread reader applies cursor clause'
);
is( $thread_resultset->last_query->{-or}[0]{last_activity_at}{'<'},
    '2026-05-23T12:02:00Z', 'thread cursor pages by activity' );
ok( $next_category_page->{has_next},
    'thread cursor page still returns metadata' );

my $post_reader =
  GPForum::Service::Forum::PostReader->new( schema => $schema, );
my $thread_post_page = $post_reader->list_thread_posts(
    {
        thread_id => 'thread-1',
        limit     => $REQUEST_LIMIT,
    }
);

is( scalar @{ $thread_post_page->{items} },
    $REQUEST_LIMIT, 'post reader returns page items' );
is( $post_resultset->last_query->{thread_id},
    'thread-1', 'post reader filters thread' );
is( $post_resultset->last_query->{deleted_at},
    undef, 'post reader excludes deleted posts' );
is( $post_resultset->last_attrs->{prefetch}[0],
    'current_body', 'post reader prefetches current body for thread view' );
is(
    $post_resultset->last_attrs->{rows},
    $REQUEST_LIMIT + 1,
    'post reader fetches limit plus one'
);
is( $post_resultset->last_attrs->{order_by}[0]{-asc},
    'position', 'post reader uses stable position order' );

$post_reader->list_thread_posts(
    {
        thread_id => 'thread-1',
        limit     => $REQUEST_LIMIT,
        after     => $thread_post_page->{next_cursor},
    }
);

ok( $post_resultset->last_query->{-or}, 'post reader applies cursor clause' );
is( $post_resultset->last_query->{-or}[0]{position}{'>'},
    2, 'post cursor pages by position' );

sub _row {
    my ($data) = @_;

    return GPForum::Test::ForumReadRow->new( data => $data );
}

1;
