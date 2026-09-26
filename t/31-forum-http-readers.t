# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use List::Util qw(any);
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::HomePageReader;
use GPForum::Service::Forum::PostPosition;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::ThreadDetailReader;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Operations::LocalCache;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadRow;
use GPForum::Test::ForumReadSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS         => 55;
const my $HOME_THREAD_FETCH_ROWS => 2;
const my $NEXT_REPLY_POSITION    => 3;

plan tests => $EXPECTED_TESTS;

my $category_rows = [
    _row(
        {
            category_id         => 'category-1',
            title               => 'General',
            slug                => 'general',
            deleted_at          => undef,
            space_id            => 'space-1',
            space_visibility    => 'public',
            visibility          => 'public',
            category_visibility => 'public',
            space_visibility    => 'public',
        }
    ),
    _row(
        {
            category_id      => 'category-staff',
            title            => 'Staff',
            slug             => 'staff',
            deleted_at       => undef,
            space_id         => 'space-1',
            space_visibility => 'public',
            visibility       => 'private',
        }
    ),
];
my $thread_rows = [
    _row(
        {
            thread_id           => 'thread-1',
            category_id         => 'category-1',
            category_visibility => 'public',
            space_id            => 'space-1',
            space_visibility    => 'public',
            author_user_id      => 'user-1',
            title               => 'Welcome',
            slug                => 'welcome',
            visibility          => 'public',
            category_visibility => 'public',
            space_visibility    => 'public',
            moderation_state    => 'visible',
            deleted_at          => undef,
            last_activity_at    => '2026-05-23T12:00:00Z',
        }
    ),
    _row(
        {
            thread_id           => 'thread-2',
            category_id         => 'category-1',
            category_visibility => 'public',
            space_id            => 'space-1',
            space_visibility    => 'public',
            author_user_id      => 'user-2',
            title               => 'Second',
            slug                => 'second',
            visibility          => 'public',
            category_visibility => 'public',
            space_visibility    => 'public',
            moderation_state    => 'visible',
            deleted_at          => undef,
            last_activity_at    => '2026-05-23T11:00:00Z',
        }
    ),
];
my $post_rows = [
    _row( { post_id => 'post-2', thread_id => 'thread-1', position => 2 } ),
    _row( { post_id => 'post-1', thread_id => 'thread-1', position => 1 } ),
];
my $schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Category => GPForum::Test::ForumReadResultSet->new(
            filter_rows => 1,
            rows        => $category_rows,
        ),
        Thread =>
          GPForum::Test::ForumReadResultSet->new( rows => $thread_rows ),
        Post => GPForum::Test::ForumReadResultSet->new( rows => $post_rows ),
    },
);

my $category_reader =
  GPForum::Service::Forum::CategoryReader->new( schema => $schema );
my $categories = $category_reader->list_categories( { limit => 10 } );

is( scalar @{$categories}, 1, 'category reader returns categories' );
is( $schema->resultset('Category')->last_query->{'me.deleted_at'},
    undef, 'category reader excludes deleted categories' );
is( $schema->resultset('Category')->last_attrs->{order_by}[0]{-asc},
    'me.position', 'category reader orders by position first' );

# ADR 0102: a private category is not found for a reader who cannot read it,
# and is for one whose grant covers it.
is( $category_reader->find_category('category-staff'),
    undef, 'an anonymous reader does not find a private category' );
ok(
    $category_reader->find_category(
        'category-staff',
        GPForum::Service::Forum::Viewer->new(
            category_ids => ['category-staff'],
            member       => 1,
            user_id      => 'user-staff',
        )
    ),
    'a reader granted category.read on it does'
);
is( $category_reader->find_category('category-1')->get_column('title'),
    'General', 'category reader finds visible category' );
is( $category_reader->find_category('missing'),
    undef, 'missing category is undef' );

my $cached_category_reader = GPForum::Service::Forum::CategoryReader->new(
    cache  => GPForum::Service::Operations::LocalCache->new,
    schema => $schema,
);
my $cached_categories =
  $cached_category_reader->list_categories( { limit => 10 } );
my $after_cache_miss_count = $schema->resultset('Category')->search_count;
$cached_category_reader->list_categories( { limit => 10 } );
is( scalar @{$cached_categories},
    1, 'cached category reader returns categories' );
is( $after_cache_miss_count, 2,
    'cached category reader queries on first cache miss' );
is( $schema->resultset('Category')->search_count,
    2, 'cached category reader avoids second query' );

my $home_reader = GPForum::Service::Forum::HomePageReader->new(
    category_reader => $category_reader,
    thread_reader   =>
      GPForum::Service::Forum::ThreadReader->new( schema => $schema ),
);
my $home = $home_reader->home_page(
    {
        category_limit => 10,
        thread_limit   => 1,
    }
);

is( scalar @{ $home->{categories} },
    1, 'home page reader returns category view models' );
is( $home->{categories}[0]{title},
    'General', 'home page reader maps category title' );
is( scalar @{ $home->{latest_threads}{items} },
    1, 'home page reader applies thread limit' );
is( $home->{latest_threads}{items}[0]{thread_id},
    'thread-1', 'home page reader maps latest public thread' );
ok( !exists $home->{latest_threads}{items}[0]{hidden_at},
    'home page reader thread view model matches canonical thread columns' );
ok(
    $home->{latest_threads}{next_cursor},
    'home page reader exposes keyset cursor'
);
is( $schema->resultset('Thread')->last_query->{'me.visibility'},
    'public', 'home page reader uses public thread reader' );
is_deeply(
    $schema->resultset('Thread')->last_query->{'me.moderation_state'},
    { -in => [ 'visible', 'locked' ] },
    'home page reader keeps locked threads readable'
);
is( $schema->resultset('Thread')->last_attrs->{rows},
    $HOME_THREAD_FETCH_ROWS, 'home page reader asks for keyset lookahead' );
ok(
    !exists $schema->resultset('Thread')->last_attrs->{offset},
    'home page reader does not use offset pagination'
);
is( $schema->resultset('Thread')->last_attrs->{columns}[0],
    'thread_id', 'home page reader uses explicit thread columns' );
ok(
    !grep { $_ eq 'hidden_at' }
      @{ $schema->resultset('Thread')->last_attrs->{columns} },
    'home page reader only requests canonical thread columns'
);
is( $schema->resultset('Thread')->last_attrs->{order_by}[0]{-desc},
    'me.last_activity_at', 'home page reader uses latest activity order' );
is( $schema->resultset('Thread')->last_attrs->{order_by}[1]{-desc},
    'me.thread_id', 'home page reader uses thread id tie breaker' );

my $thread_reader =
  GPForum::Service::Forum::ThreadReader->new( schema => $schema );
$thread_reader->list_category_threads( { category_id => 'category-1' } );
is( $schema->resultset('Thread')->last_query->{'me.deleted_at'},
    undef, 'category listing excludes deleted threads for anonymous viewers' );

# Behaviour rather than the shape of the query: a signed-in reader sees their
# own deleted thread and nobody else's, and an anonymous reader sees neither.
# The reader asks for the two halves as subqueries of one statement; the
# double answers them from these rows.
my $deleted_threads = GPForum::Service::Forum::ThreadReader->new(
    schema => GPForum::Test::ForumReadSchema->new(
        resultsets => {
            Thread => GPForum::Test::ForumReadResultSet->new(
                filter_rows => 1,
                rows        => [
                    _category_thread( 'thread-open', 'user-2', undef ),
                    _category_thread(
                        'thread-mine-deleted', 'user-1', '2026-01-02'
                    ),
                    _category_thread(
                        'thread-theirs-deleted', 'user-2', '2026-01-02'
                    ),
                ],
            ),
        },
    ),
);
is_deeply(
    _thread_ids(
        $deleted_threads->list_category_threads(
            { category_id => 'category-1', viewer_user_id => 'user-1' }
        )
    ),
    [ 'thread-mine-deleted', 'thread-open' ],
    'a signed-in reader sees their own deleted thread and nobody else\'s'
);
is_deeply(
    _thread_ids(
        $deleted_threads->list_category_threads(
            { category_id => 'category-1' }
        )
    ),
    ['thread-open'],
    'an anonymous reader sees no deleted thread'
);

my $visible_post_schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Post => GPForum::Test::ForumReadResultSet->new(
            rows => [
                _row(
                    {
                        post_id             => 'post-visible',
                        thread_id           => 'thread-1',
                        position            => 3,
                        deleted_at          => undef,
                        moderation_state    => 'visible',
                        visibility          => 'public',
                        category_visibility => 'public',
                        space_visibility    => 'public',
                        category_id         => 'category-1',
                        category_visibility => 'public',
                        space_id            => 'space-1',
                        space_visibility    => 'public',
                        thread_visibility   => 'public',
                    }
                ),
            ],
        ),
    },
);
my $post_reader =
  GPForum::Service::Forum::PostReader->new( schema => $visible_post_schema );
my $visible_post = $post_reader->find_visible_post('post-visible');
is( $visible_post->get_column('post_id'),
    'post-visible', 'post reader finds visible post by id' );
is( $visible_post_schema->resultset('Post')->last_query->{'me.post_id'},
    'post-visible', 'post lookup filters by post id' );
is(
    $visible_post_schema->resultset('Post')
      ->last_query->{'me.moderation_state'},
    'visible', 'post lookup filters visible moderation state'
);

my $detail_reader =
  GPForum::Service::Forum::ThreadDetailReader->new( schema => $schema );
my $thread = $detail_reader->find_thread('thread-1');

is( $thread->get_column('title'),
    'Welcome', 'thread detail finds visible thread' );

my $page = $detail_reader->thread_page(
    {
        thread_id => 'thread-1',
        limit     => 1,
    }
);

ok( $page->{ok}, 'thread page is ok' );
is( $page->{thread}->get_column('thread_id'),
    'thread-1', 'thread page includes thread' );
is( scalar @{ $page->{posts}{items} }, 1, 'thread page applies post limit' );
ok( $page->{posts}{next_cursor}, 'thread page exposes post cursor' );
is( $schema->resultset('Post')->last_attrs->{order_by}[0]{-asc},
    'me.position', 'post reader qualifies position ordering' );
is( $schema->resultset('Post')->last_attrs->{order_by}[1]{-asc},
    'me.post_id', 'post reader qualifies post id ordering after body join' );
is( $schema->resultset('Post')->last_query->{'me.thread_id'},
    'thread-1', 'post reader qualifies thread filter after body join' );
is( $schema->resultset('Post')->last_query->{'me.deleted_at'},
    undef, 'post reader qualifies deleted filter after body join' );
ok(
    !exists $schema->resultset('Post')->last_query->{deleted_at},
    'post reader avoids ambiguous unqualified deleted filter'
);

my $viewer_posts = $detail_reader->thread_page(
    {
        thread_id => 'thread-1',
        viewer    => GPForum::Service::Forum::Viewer->new(
            member  => 1,
            user_id => 'user-1'
        ),
    }
);
ok( $viewer_posts->{ok}, 'viewer thread page is ok' );

is_deeply(
    $schema->resultset('Post')->last_query->{-or},
    [ { 'me.deleted_at' => undef }, { 'me.author_user_id' => 'user-1' }, ],
    'post reader includes the author deleted posts for the viewer'
);
ok(
    !exists $schema->resultset('Post')->last_query->{'me.deleted_at'},
    'viewer post listing does not require deleted_at to be null'
);

# The review of stage 1 found this: a cursor page for a signed-in reader
# replaced the query's -and, which held the post-visibility condition, so
# page 2 on listed every private post. The condition must survive the cursor.
my $member_scope = GPForum::Service::Forum::Viewer->new(
    member  => 1,
    user_id => 'user-1'
)->within( 'category-1', 'space-1' );
$post_reader->schema($schema);
$post_reader->list_thread_posts(
    {
        after          => $page->{posts}{next_cursor},
        limit          => 1,
        thread_id      => 'thread-1',
        viewer_scope   => $member_scope,
        viewer_user_id => 'user-1',
    }
);
my $paged = $schema->resultset('Post')->last_query;
ok(
    (
        any {
                 ref $_ eq 'HASH'
              && exists $_->{-or}
              && any { exists $_->{'me.visibility'} }
              @{ $_->{-or} }
        } @{ $paged->{-and} || [] }
    ),
    'a signed-in reader\'s second page still filters post visibility'
);

my $missing_page = $detail_reader->thread_page( { thread_id => 'missing' } );
ok( !$missing_page->{ok}, 'missing thread page is not ok' );
is( $missing_page->{error},
    'not_found', 'missing thread page reports not_found' );

my $post_position =
  GPForum::Service::Forum::PostPosition->new( schema => $schema );
throws_ok(
    sub { return $post_position->next_position('thread-1'); },
    qr/unsafe [ ] for [ ] writes/msx,
    'direct next position allocation is rejected outside the store'
);
is( $post_position->read_next_position('thread-1'),
    $NEXT_REPLY_POSITION, 'next reply position increments' );

my $empty_schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Post => GPForum::Test::ForumReadResultSet->new( rows => [] ),
    },
);
my $empty_position =
  GPForum::Service::Forum::PostPosition->new( schema => $empty_schema );
is( $empty_position->read_next_position('thread-2'),
    1, 'empty thread starts at one' );

my $hidden_schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Thread => GPForum::Test::ForumReadResultSet->new(
            rows => [
                _row(
                    {
                        thread_id        => 'thread-hidden',
                        moderation_state => 'hidden',
                        deleted_at       => undef,
                    }
                ),
            ],
        ),
    },
);
my $hidden_detail =
  GPForum::Service::Forum::ThreadDetailReader->new( schema => $hidden_schema );
is( $hidden_detail->find_thread('thread-hidden'),
    undef, 'hidden thread is not visible' );

my $locked_schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Thread => GPForum::Test::ForumReadResultSet->new(
            rows => [
                _row(
                    {
                        thread_id           => 'thread-locked',
                        moderation_state    => 'locked',
                        visibility          => 'public',
                        category_visibility => 'public',
                        space_visibility    => 'public',
                        deleted_at          => undef,
                    }
                ),
            ],
        ),
    },
);
my $locked_detail =
  GPForum::Service::Forum::ThreadDetailReader->new( schema => $locked_schema );
is( $locked_detail->find_thread('thread-locked')->get_column('thread_id'),
    'thread-locked', 'locked thread remains readable' );

my $deleted_thread_schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Thread => GPForum::Test::ForumReadResultSet->new(
            rows => [
                _row(
                    {
                        thread_id           => 'thread-deleted',
                        author_user_id      => 'user-1',
                        moderation_state    => 'visible',
                        visibility          => 'public',
                        category_visibility => 'public',
                        space_visibility    => 'public',
                        deleted_at          => '2026-05-23T12:00:00Z',
                    }
                ),
            ],
        ),
    },
);
my $deleted_detail =
  GPForum::Service::Forum::ThreadDetailReader->new(
    schema => $deleted_thread_schema );
is( $deleted_detail->find_thread('thread-deleted'),
    undef, 'deleted thread is hidden from anonymous viewers' );
is(
    $deleted_detail->find_thread( 'thread-deleted', 'user-1' )
      ->get_column('thread_id'),
    'thread-deleted',
    'author still sees a deleted thread'
);

my $deleted_category_schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Category => GPForum::Test::ForumReadResultSet->new(
            rows => [
                _row(
                    {
                        category_id => 'category-deleted',
                        deleted_at  => '2026-05-23T12:00:00Z',
                    }
                ),
            ],
        ),
    },
);
my $deleted_category_reader =
  GPForum::Service::Forum::CategoryReader->new(
    schema => $deleted_category_schema );
is( $deleted_category_reader->find_category('category-deleted'),
    undef, 'deleted category is not visible' );

my $invalid_limit_category_reader =
  GPForum::Service::Forum::CategoryReader->new( schema => $schema );
is(
    $invalid_limit_category_reader->list_categories( { limit => 'wide-open' } )
      ->[0]->get_column('category_id'),
    'category-1',
    'category reader defaults invalid limits'
);

sub _row {
    my ($data) = @_;

    return GPForum::Test::ForumReadRow->new( data => $data );
}

sub _category_thread {
    my ( $thread_id, $author, $deleted_at ) = @_;

    return _row(
        {
            thread_id           => $thread_id,
            category_id         => 'category-1',
            author_user_id      => $author,
            deleted_at          => $deleted_at,
            moderation_state    => 'visible',
            visibility          => 'public',
            category_visibility => 'public',
            space_visibility    => 'public',
            pinned              => 0,
            last_activity_at    => '2026-01-03',
        }
    );
}

sub _thread_ids {
    my ($listing) = @_;

    return [ sort map { $_->get_column('thread_id') } @{ $listing->{items} } ];
}

1;
