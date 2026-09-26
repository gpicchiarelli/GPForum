# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use List::Util   qw(all);
use MIME::Base64 qw(encode_base64url);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadRow;
use GPForum::Test::ForumReadSchema;
use GPForum::Test::ThreadKeysetResultSet;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 43;
const my $DEFAULT_LIMIT  => 25;
const my $MAX_LIMIT      => 100;
const my $REQUEST_LIMIT  => 2;
const my $MAX_PAGE_WALK  => 20;

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

my $invalid_limit_plan = $page_window->plan( { limit => 'many' } );
is( $invalid_limit_plan->{limit},
    $DEFAULT_LIMIT, 'page window defaults invalid limit' );

my $invalid_cursor_plan = $page_window->plan( { after => 'not-a-cursor' } );
is( $invalid_cursor_plan->{after},
    undef, 'page window ignores malformed cursor' );

my $thread_rows = [
    _row(
        {
            thread_id        => '018f1000-0000-7000-8000-000000000105',
            last_activity_at => '2026-05-23T12:03:00Z',
        }
    ),
    _row(
        {
            thread_id        => '018f1000-0000-7000-8000-000000000104',
            last_activity_at => '2026-05-23T12:02:00Z',
        }
    ),
    _row(
        {
            thread_id        => '018f1000-0000-7000-8000-000000000103',
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
is(
    $decoded_plan->{after}{id},
    '018f1000-0000-7000-8000-000000000104',
    'cursor stores id'
);

my $post_rows = [
    _row(
        { post_id => '018f1000-0000-7000-8000-000000000100', position => 1 }
    ),
    _row(
        { post_id => '018f1000-0000-7000-8000-000000000101', position => 2 }
    ),
    _row(
        { post_id => '018f1000-0000-7000-8000-000000000102', position => 3 }
    ),
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
is( $thread_resultset->last_query->{'me.category_id'},
    'category-1', 'thread reader filters category' );
ok(
    exists $thread_resultset->last_query->{'me.deleted_at'}
      && !defined $thread_resultset->last_query->{'me.deleted_at'},
    'thread reader excludes deleted threads'
);
ok(
    ( all { /\A (?:-|me[.]) /msx } keys %{ $thread_resultset->last_query } ),
    'thread reader qualifies every column against the joined author'
);
is_deeply(
    $thread_resultset->last_query->{'me.moderation_state'},
    { -in => [ 'visible', 'locked' ] },
    'thread reader keeps visible and locked threads readable'
);
is(
    $thread_resultset->last_attrs->{rows},
    $REQUEST_LIMIT + 1,
    'thread reader fetches limit plus one'
);
is( $thread_resultset->last_attrs->{order_by}[0]{-desc},
    'me.pinned', 'thread reader keeps pinned threads first' );
is( $thread_resultset->last_attrs->{order_by}[1]{-desc},
    'me.last_activity_at', 'thread reader uses activity keyset order' );
is( $thread_resultset->last_attrs->{order_by}[2]{-desc},
    'me.thread_id', 'thread reader uses thread id tie breaker' );

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
my $category_cursor_clause = $thread_resultset->last_query->{-or};
is( $category_cursor_clause->[0]{'me.pinned'}{'<'},
    0, 'thread cursor leads the keyset with pinned' );
is( $category_cursor_clause->[1]{'me.last_activity_at'}{'<'},
    '2026-05-23T12:02:00Z', 'thread cursor pages by activity within pinned' );
is(
    $category_cursor_clause->[2]{'me.thread_id'}{'<'},
    '018f1000-0000-7000-8000-000000000104',
    'thread cursor breaks an activity tie by thread id'
);
ok( $next_category_page->{has_next},
    'thread cursor page still returns metadata' );

my $post_reader =
  GPForum::Service::Forum::PostReader->new( schema => $schema, );
my $thread_post_page = $post_reader->list_thread_posts(
    {
        thread_id => '018f1000-0000-7000-8000-000000000103',
        limit     => $REQUEST_LIMIT,
    }
);

is( scalar @{ $thread_post_page->{items} },
    $REQUEST_LIMIT, 'post reader returns page items' );
is(
    $post_resultset->last_query->{'me.thread_id'},
    '018f1000-0000-7000-8000-000000000103',
    'post reader filters thread'
);
is( $post_resultset->last_query->{'me.deleted_at'},
    undef, 'post reader excludes deleted posts' );
is_deeply(
    $post_resultset->last_attrs->{join},
    [ 'current_body', 'author' ],
    'post reader joins current body and author for thread view'
);
is( $post_resultset->last_attrs->{'+as'}[0],
    'body', 'post reader aliases rendered body without object inflation' );
is(
    $post_resultset->last_attrs->{rows},
    $REQUEST_LIMIT + 1,
    'post reader fetches limit plus one'
);
is( $post_resultset->last_attrs->{order_by}[0]{-asc},
    'me.position', 'post reader uses stable position order' );
is( $post_resultset->last_attrs->{order_by}[1]{-asc},
    'me.post_id', 'post reader uses post id tie breaker' );

$post_reader->list_thread_posts(
    {
        thread_id => '018f1000-0000-7000-8000-000000000103',
        limit     => $REQUEST_LIMIT,
        after     => $thread_post_page->{next_cursor},
    }
);

# The cursor joins the query's -and, next to the visibility condition, rather
# than replacing it (review of ADR 0102 stage 1).
my ($cursor_clause) =
  grep {
    ref $_ eq 'HASH' && exists $_->{-or} && exists $_->{-or}[0]{'me.position'}
  } @{ $post_resultset->last_query->{-and} || [] };
ok( $cursor_clause, 'post reader applies cursor clause' );
is( $cursor_clause->{-or}[0]{'me.position'}{'>'},
    2, 'post cursor pages by position' );

# A pinned thread sorts ahead of every unpinned one no matter how stale it is,
# so a cursor that ignored pinned made page two repeat or skip whole threads.
my @keyset_rows = (
    _keyset_row(
        '018f1000-0000-7000-8000-000000000111',
        1, '2026-05-20T09:00:00Z'
    ),
    _keyset_row(
        '018f1000-0000-7000-8000-000000000112',
        1, '2026-05-19T09:00:00Z'
    ),
    _keyset_row(
        '018f1000-0000-7000-8000-000000000106',
        0, '2026-05-24T09:00:00Z'
    ),
    _keyset_row(
        '018f1000-0000-7000-8000-000000000107',
        0, '2026-05-23T09:00:00Z'
    ),
    _keyset_row(
        '018f1000-0000-7000-8000-000000000108',
        0, '2026-05-22T09:00:00Z'
    ),
    _keyset_row(
        '018f1000-0000-7000-8000-000000000109',
        0, '2026-05-18T09:00:00Z'
    ),
    _keyset_row(
        '018f1000-0000-7000-8000-000000000110',
        0, '2026-05-17T09:00:00Z'
    ),
);
my $keyset_resultset = GPForum::Test::ThreadKeysetResultSet->new(
    filter_rows => 1,
    rows        => [@keyset_rows],
);
my $keyset_reader = GPForum::Service::Forum::ThreadReader->new(
    schema => GPForum::Test::ForumReadSchema->new(
        resultsets => { Thread => $keyset_resultset },
    ),
);
my $walk = _walk_category_pages( $keyset_reader, $REQUEST_LIMIT );

ok( $walk->{pages} > 1, 'pinned keyset paging spans more than one page' );
is(
    scalar @{ $walk->{ids} },
    scalar @keyset_rows,
    'pinned keyset paging returns every thread exactly once'
);
is_deeply(
    [ sort @{ $walk->{ids} } ],
    [ sort map { $_->get_column('thread_id') } @keyset_rows ],
    'pinned keyset paging neither drops nor duplicates a thread'
);
is_deeply(
    $walk->{ids},
    [
        '018f1000-0000-7000-8000-000000000111',
        '018f1000-0000-7000-8000-000000000112',
        '018f1000-0000-7000-8000-000000000106',
        '018f1000-0000-7000-8000-000000000107',
        '018f1000-0000-7000-8000-000000000108',
        '018f1000-0000-7000-8000-000000000109',
        '018f1000-0000-7000-8000-000000000110',
    ],
    'pinned keyset paging keeps pinned threads ahead of fresher ones'
);

my $legacy_cursor =
  encode_base64url('2026-05-23T09:00:00Z|018f1000-0000-7000-8000-000000000107');
my $legacy_page = $keyset_reader->list_category_threads(
    {
        category_id => 'category-1',
        limit       => $REQUEST_LIMIT,
        after       => $legacy_cursor,
    }
);

ok( $legacy_page,
    'a cursor minted before pinned joined the keyset still pages' );
is( $keyset_resultset->last_query->{-or}[0]{'me.pinned'}{'<'},
    1, 'a legacy cursor resumes from the top of the pinned block' );

sub _walk_category_pages {
    my ( $reader, $limit ) = @_;

    my @ids;
    my $pages = 0;
    my $after;
    while ( $pages < $MAX_PAGE_WALK ) {
        my $page = $reader->list_category_threads(
            {
                after       => $after,
                category_id => 'category-1',
                limit       => $limit,
            }
        );
        push @ids, map { $_->get_column('thread_id') } @{ $page->{items} };
        $pages += 1;
        last if !$page->{has_next};
        $after = $page->{next_cursor};
    }

    return { ids => \@ids, pages => $pages };
}

sub _keyset_row {
    my ( $thread_id, $pinned, $last_activity_at ) = @_;

    return _row(
        {
            category_id      => 'category-1',
            last_activity_at => $last_activity_at,
            moderation_state => 'visible',
            pinned           => $pinned,
            thread_id        => $thread_id,
            visibility       => 'public',
        }
    );
}

sub _row {
    my ($data) = @_;

    return GPForum::Test::ForumReadRow->new( data => $data );
}

1;
