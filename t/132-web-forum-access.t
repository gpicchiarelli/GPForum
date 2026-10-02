# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Operations::LocalCache;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadSchema;
use GPForum::Web::ForumAccess;
use Test::More;

our $VERSION = '0.001';

const my $READ_RATE_LIMIT        => 60;
const my $READ_RATE_WINDOW       => 60;
const my $WRITE_RATE_LIMIT       => 20;
const my $REPORT_RATE_LIMIT      => 5;
const my $CHURN_RATE_LIMIT       => 10;
const my $WRITE_RATE_WINDOW      => 60;
const my $REPORT_REASON_MAX      => 80;
const my $REPORT_DETAILS_MAX     => 2_000;
const my $SEARCH_DEFAULT         => 20;
const my $SEARCH_MAX             => 50;
const my $SEARCH_REQUESTED       => 10;
const my $SEARCH_OVER_MAX        => 80;
const my $SEARCH_FETCH           => 21;
const my $SEARCH_DOUBLE          => 40;
const my $AUTOCOMPLETE_DEFAULT   => 10;
const my $AUTOCOMPLETE_REQUESTED => 5;
const my $LIST_DEFAULT           => 25;
const my $LIST_REQUESTED         => 10;
const my $LIST_LEADING_ZERO      => 7;
const my $LIST_MAX               => 100;
const my $LIST_OVER_MAX          => 100_000;
const my $CATEGORY_DEFAULT       => 100;
const my $CATEGORY_REQUESTED     => 50;
const my $CATEGORY_MAX           => 200;

my $access = GPForum::Web::ForumAccess->new;

is_deeply(
    $access->read_rate_input(
        {
            action   => 'search',
            actor_id => '198.51.100.10',
        }
    ),
    {
        action         => 'search',
        actor_id       => '198.51.100.10',
        limit          => $READ_RATE_LIMIT,
        scope          => 'forum_retrieval',
        window_seconds => $READ_RATE_WINDOW,
    },
    'read_rate_input uses the forum retrieval window'
);

{
    local $ENV{GPFORUM_FORUM_READ_RATE_LIMIT} = '100000';
    is(
        $access->read_rate_input(
            {
                action   => 'search',
                actor_id => '198.51.100.10',
            }
        )->{limit},
        100_000,
'read_rate_input honors GPFORUM_FORUM_READ_RATE_LIMIT for stress/capacity'
    );
}

is_deeply(
    $access->write_rate_input(
        {
            action   => 'thread.create',
            actor_id => 'user-1',
        }
    ),
    {
        action         => 'thread.create',
        actor_id       => 'user-1',
        limit          => $WRITE_RATE_LIMIT,
        scope          => 'forum_http',
        window_seconds => $WRITE_RATE_WINDOW,
    },
    'write_rate_input uses the default write limit'
);

is( $access->write_limit_for('report.create'),
    $REPORT_RATE_LIMIT, 'write_limit_for caps reports' );
is( $access->write_limit_for('thread.bookmark'),
    $CHURN_RATE_LIMIT, 'write_limit_for caps bookmark churn' );
is( $access->write_limit_for('thread.bookmark.remove'),
    $CHURN_RATE_LIMIT, 'write_limit_for caps bookmark removal' );
is( $access->write_limit_for('thread.subscribe'),
    $CHURN_RATE_LIMIT, 'write_limit_for caps subscribe churn' );
is( $access->write_limit_for('thread.subscription.mute'),
    $CHURN_RATE_LIMIT, 'write_limit_for caps subscription mute' );
is( $access->write_limit_for('thread.unsubscribe'),
    $CHURN_RATE_LIMIT, 'write_limit_for caps unsubscribe churn' );
is( $access->write_limit_for('thread.read'),
    $WRITE_RATE_LIMIT, 'write_limit_for keeps read-marker writes at 20' );

ok(
    $access->requires_participation('thread.create'),
    'requires_participation includes thread create'
);
ok(
    $access->requires_participation('reply.create'),
    'requires_participation includes reply create'
);
ok(
    $access->requires_participation('post.edit'),
    'requires_participation includes post edit'
);
ok(
    $access->requires_participation('post.delete'),
    'requires_participation includes post delete'
);
ok(
    $access->requires_participation('post.restore'),
    'requires_participation includes post restore'
);
ok(
    $access->requires_participation('thread.edit'),
    'requires_participation includes thread edit'
);
ok(
    $access->requires_participation('thread.delete'),
    'requires_participation includes thread delete'
);
ok(
    $access->requires_participation('thread.move'),
    'requires_participation includes thread move'
);
ok(
    $access->requires_participation('thread.restore'),
    'requires_participation includes thread restore'
);
ok(
    !$access->requires_participation('thread.read'),
    'requires_participation ignores read markers'
);
ok(
    !$access->requires_participation('report.create'),
    'requires_participation ignores reports'
);

is_deeply(
    $access->report_field_errors( q{}, q{} ),
    { reason => 'reason is required' },
    'report_field_errors requires a reason'
);
is_deeply(
    $access->report_field_errors( 'x' x ( $REPORT_REASON_MAX + 1 ), q{} ),
    { reason => 'reason is too long' },
    'report_field_errors rejects an overlong reason'
);
is_deeply(
    $access->report_field_errors( 'spam', 'x' x ( $REPORT_DETAILS_MAX + 1 ) ),
    { details => 'details are too long' },
    'report_field_errors rejects overlong details'
);
is_deeply( $access->report_field_errors( 'spam', 'too many quotes' ),
    {}, 'report_field_errors accepts a valid report' );

ok(
    $access->is_non_negative_integer('0'),
    'is_non_negative_integer accepts zero'
);
ok(
    $access->is_non_negative_integer('12'),
    'is_non_negative_integer accepts a digit string'
);
ok(
    !$access->is_non_negative_integer(undef),
    'is_non_negative_integer rejects undef'
);
ok(
    !$access->is_non_negative_integer('-1'),
    'is_non_negative_integer rejects a signed value'
);

is(
    $access->bounded_limit(
        {
            default => $SEARCH_DEFAULT,
            maximum => $SEARCH_MAX,
            value   => undef,
        }
    ),
    $SEARCH_DEFAULT,
    'bounded_limit defaults a missing value'
);
is(
    $access->bounded_limit(
        {
            default => $SEARCH_DEFAULT,
            maximum => $SEARCH_MAX,
            value   => 0,
        }
    ),
    $SEARCH_DEFAULT,
    'bounded_limit defaults a zero value'
);
is(
    $access->bounded_limit(
        {
            default => $SEARCH_DEFAULT,
            maximum => $SEARCH_MAX,
            value   => $SEARCH_OVER_MAX,
        }
    ),
    $SEARCH_MAX,
    'bounded_limit caps an oversized value'
);
is(
    $access->bounded_limit(
        {
            default => $SEARCH_DEFAULT,
            maximum => $SEARCH_MAX,
            value   => $SEARCH_REQUESTED,
        }
    ),
    $SEARCH_REQUESTED,
    'bounded_limit keeps a value inside the window'
);

is_deeply(
    [ $access->search_filter_fields ],
    [qw(category_id author_user_id from to)],
    'search_filter_fields lists the allowed query fields'
);

is( $access->list_page_limit(undef),
    $LIST_DEFAULT, 'list_page_limit defaults a missing size' );
is( $access->list_page_limit(0),
    $LIST_DEFAULT, 'list_page_limit defaults a zero size' );
is( $access->list_page_limit($LIST_REQUESTED),
    $LIST_REQUESTED, 'list_page_limit keeps an explicit size' );

# The public cache key names the page size, and it named the size as asked:
# ?limit=abc, ?limit=007 and ?limit=100000 each minted an entry for a page of
# 25, 7 or 100 that another spelling already had.
is( $access->list_page_limit('abc'),
    $LIST_DEFAULT, 'list_page_limit defaults a size that is no number' );
is( $access->list_page_limit('00'),
    $LIST_DEFAULT, 'list_page_limit defaults a zero spelled with two digits' );
is( $access->list_page_limit('007'),
    $LIST_LEADING_ZERO, 'list_page_limit reads leading zeros as the number' );
is( $access->list_page_limit($LIST_OVER_MAX),
    $LIST_MAX, 'list_page_limit caps an oversized size' );
is( $access->category_list_limit(undef),
    $CATEGORY_DEFAULT, 'category_list_limit defaults a missing size' );
is( $access->category_list_limit('abc'),
    $CATEGORY_DEFAULT,
    'category_list_limit defaults a size that is no number' );
is( $access->category_list_limit('0050'),
    $CATEGORY_REQUESTED, 'category_list_limit keeps an explicit size' );
is( $access->category_list_limit($LIST_OVER_MAX),
    $CATEGORY_MAX, 'category_list_limit caps an oversized size' );

# And what the key names is what the readers list: the controller hands them
# the bounded size, which they leave as it is.
my @requested = (
    undef, q{},  'abc', '-3',  '0',   '00',  '1',   '007',
    '25',  '99', '100', '101', '199', '200', '201', '100000',
);
for my $requested (@requested) {
    my $shown = $requested // 'undef';
    my $page  = $access->list_page_limit($requested);
    is(
        GPForum::Service::Forum::PageWindow->new->plan( { limit => $page } )
          ->{limit},
        $page,
        "a list asked for $shown is read with the size its key names"
    );
    my $index = $access->category_list_limit($requested);
    is( _listed_category_limit($index),
        $index, "an index asked for $shown lists the size its key names" );
}

is( $access->post_target,   'post',   'post_target keeps the report target' );
is( $access->thread_target, 'thread', 'thread_target keeps the report target' );
is( $access->user_target,   'user',   'user_target keeps the report target' );
is( $access->bookmarked_status,
    'bookmarked', 'bookmarked_status keeps the bookmark write status' );
is( $access->bookmark_removed_status,
    'bookmark_removed',
    'bookmark_removed_status keeps the remove write status' );
is( $access->subscribed_status,
    'subscribed', 'subscribed_status keeps the subscribe write status' );
is( $access->subscription_muted_status,
    'subscription_muted',
    'subscription_muted_status keeps the mute write status' );
is( $access->unsubscribed_status,
    'unsubscribed', 'unsubscribed_status keeps the unsubscribe write status' );

is_deeply(
    $access->public_cache_options(
        {
            limit  => 50,
            locale => 'it',
            name   => 'categories',
            path   => '/categories',
            tags   => ['forum:categories'],
            theme  => 'dark',
        }
    ),
    {
        key  => 'forum-ssr:categories:it:dark:/categories:limit=50',
        tags => [ 'forum:public-html', 'forum:categories' ],
    },
    'public_cache_options builds the forum SSR cache key'
);

is_deeply(
    $access->read_position_errors,
    {
        last_read_position =>
          'last_read_position must be a non-negative integer',
    },
    'read_position_errors keeps the write-controller message'
);

is( $access->search_page_limit(undef),
    $SEARCH_DEFAULT, 'search_page_limit defaults a missing size' );
is( $access->search_page_limit(0),
    $SEARCH_DEFAULT, 'search_page_limit defaults a zero size' );
is( $access->search_page_limit($SEARCH_REQUESTED),
    $SEARCH_REQUESTED, 'search_page_limit keeps an explicit size' );
is( $access->search_page_limit($SEARCH_OVER_MAX),
    $SEARCH_MAX, 'search_page_limit caps an oversized size' );

is( $access->autocomplete_limit(undef),
    $AUTOCOMPLETE_DEFAULT, 'autocomplete_limit defaults a missing size' );
is( $access->autocomplete_limit($AUTOCOMPLETE_REQUESTED),
    $AUTOCOMPLETE_REQUESTED, 'autocomplete_limit keeps an explicit size' );
is( $access->autocomplete_limit($SEARCH_OVER_MAX),
    $SEARCH_MAX, 'autocomplete_limit caps an oversized size' );

ok( $access->autocomplete_too_short(q{}),
    'autocomplete_too_short rejects an empty prefix' );
ok( $access->autocomplete_too_short('a'),
    'autocomplete_too_short rejects a one-character prefix' );
ok( !$access->autocomplete_too_short('ab'),
    'autocomplete_too_short accepts a two-character prefix' );

is( $access->search_fetch_limit($SEARCH_DEFAULT),
    $SEARCH_FETCH, 'search_fetch_limit requests one extra row' );
is( $access->search_fetch_limit($SEARCH_MAX),
    $SEARCH_MAX, 'search_fetch_limit keeps the maximum page' );

ok(
    !defined $access->search_more_limit( 0, $SEARCH_DEFAULT ),
    'search_more_limit omits a next page when results are complete'
);
is_deeply(
    {
        more_limit => $access->search_more_limit( 0, $SEARCH_DEFAULT ),
        results    => ['kept'],
    },
    {
        more_limit => undef,
        results    => ['kept'],
    },
    'search_more_limit keeps following hash keys when no next page exists'
);
is( $access->search_more_limit( 1, $SEARCH_DEFAULT ),
    $SEARCH_DOUBLE, 'search_more_limit doubles the current page' );
is( $access->search_more_limit( 1, $SEARCH_DOUBLE ),
    $SEARCH_MAX, 'search_more_limit caps the doubled page' );

ok(
    $access->is_unavailable( { status => 'failed' } ),
    'is_unavailable accepts a failed store write'
);
ok(
    $access->is_unavailable( { system_error => 1 } ),
    'is_unavailable accepts a report system error'
);
ok(
    !$access->is_unavailable( { status => 'invalid' } ),
    'is_unavailable ignores a client validation error'
);
is( $access->write_flash_key('thread_created'),
    'forum.thread_created',
    'write_flash_key maps thread create to the flash key' );
is( $access->write_flash_key('post_restored'),
    'forum.post_restored',
    'write_flash_key maps post restore to the flash key' );
is( $access->write_flash_key('thread_restored'),
    'forum.thread_restored',
    'write_flash_key maps thread restore to the flash key' );
is( $access->write_flash_key('bookmarked'),
    'forum.bookmarked', 'write_flash_key maps bookmark to the flash key' );
is( $access->write_flash_key('read_marked'),
    'forum.posts_marked_read',
    'write_flash_key maps read marker to the flash key' );
is( $access->read_marked_status,
    'read_marked', 'read_marked_status returns read_marked' );
ok(
    !defined $access->write_flash_key('unknown'),
    'write_flash_key ignores an unmapped status'
);

done_testing();

# The limit CategoryReader lists an anonymous index with, read from the key
# it caches the list under.
sub _listed_category_limit {
    my ($limit) = @_;

    my $cache  = GPForum::Service::Operations::LocalCache->new;
    my $reader = GPForum::Service::Forum::CategoryReader->new(
        cache  => $cache,
        schema => GPForum::Test::ForumReadSchema->new(
            resultsets => {
                Category =>
                  GPForum::Test::ForumReadResultSet->new( rows => [] ),
            },
        ),
    );
    $reader->list_categories( { limit => $limit } );
    my ($key) = keys %{ $cache->entries };

    return ( $key // q{} ) =~ /:([[:digit:]]+)\z/msx ? $1 : undef;
}

1;
