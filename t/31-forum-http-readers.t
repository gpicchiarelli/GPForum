package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::HomePageReader;
use GPForum::Service::Forum::PostPosition;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::ThreadDetailReader;
use GPForum::Service::Operations::LocalCache;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadRow;
use GPForum::Test::ForumReadSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS         => 36;
const my $HOME_THREAD_FETCH_ROWS => 2;
const my $NEXT_REPLY_POSITION    => 3;

plan tests => $EXPECTED_TESTS;

my $category_rows = [
    _row(
        {
            category_id => 'category-1',
            title       => 'General',
            slug        => 'general',
            deleted_at  => undef,
        }
    ),
];
my $thread_rows = [
    _row(
        {
            thread_id        => 'thread-1',
            category_id      => 'category-1',
            author_user_id   => 'user-1',
            title            => 'Welcome',
            slug             => 'welcome',
            visibility       => 'public',
            moderation_state => 'visible',
            deleted_at       => undef,
            last_activity_at => '2026-05-23T12:00:00Z',
        }
    ),
    _row(
        {
            thread_id        => 'thread-2',
            category_id      => 'category-1',
            author_user_id   => 'user-2',
            title            => 'Second',
            slug             => 'second',
            visibility       => 'public',
            moderation_state => 'visible',
            deleted_at       => undef,
            last_activity_at => '2026-05-23T11:00:00Z',
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
            rows => $category_rows
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
is( $schema->resultset('Category')->last_query->{deleted_at},
    undef, 'category reader excludes deleted categories' );
is( $schema->resultset('Category')->last_attrs->{order_by}[0]{-asc},
    'position', 'category reader orders by position first' );
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
ok(
    $home->{latest_threads}{next_cursor},
    'home page reader exposes keyset cursor'
);
is( $schema->resultset('Thread')->last_query->{visibility},
    'public', 'home page reader uses public thread reader' );
is_deeply(
    $schema->resultset('Thread')->last_query->{moderation_state},
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
is( $schema->resultset('Thread')->last_attrs->{order_by}[0]{-desc},
    'last_activity_at', 'home page reader uses latest activity order' );
is( $schema->resultset('Thread')->last_attrs->{order_by}[1]{-desc},
    'thread_id', 'home page reader uses thread id tie breaker' );

my $visible_post_schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Post => GPForum::Test::ForumReadResultSet->new(
            rows => [
                _row(
                    {
                        post_id          => 'post-visible',
                        thread_id        => 'thread-1',
                        position         => 3,
                        deleted_at       => undef,
                        moderation_state => 'visible',
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
is( $visible_post_schema->resultset('Post')->last_query->{post_id},
    'post-visible', 'post lookup filters by post id' );
is( $visible_post_schema->resultset('Post')->last_query->{moderation_state},
    'visible', 'post lookup filters visible moderation state' );

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

my $missing_page = $detail_reader->thread_page( { thread_id => 'missing' } );
ok( !$missing_page->{ok}, 'missing thread page is not ok' );
is( $missing_page->{error},
    'not_found', 'missing thread page reports not_found' );

my $post_position =
  GPForum::Service::Forum::PostPosition->new( schema => $schema );
is( $post_position->next_position('thread-1'),
    $NEXT_REPLY_POSITION, 'next reply position increments' );

my $empty_schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        Post => GPForum::Test::ForumReadResultSet->new( rows => [] ),
    },
);
my $empty_position =
  GPForum::Service::Forum::PostPosition->new( schema => $empty_schema );
is( $empty_position->next_position('thread-2'),
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
                        thread_id        => 'thread-locked',
                        moderation_state => 'locked',
                        deleted_at       => undef,
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

1;
