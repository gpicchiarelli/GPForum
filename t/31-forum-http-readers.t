package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::PostPosition;
use GPForum::Service::Forum::ThreadDetailReader;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadRow;
use GPForum::Test::ForumReadSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS      => 16;
const my $NEXT_REPLY_POSITION => 3;

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
            title            => 'Welcome',
            moderation_state => 'visible',
            deleted_at       => undef,
            last_activity_at => '2026-05-23T12:00:00Z',
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

sub _row {
    my ($data) = @_;

    return GPForum::Test::ForumReadRow->new( data => $data );
}

1;
