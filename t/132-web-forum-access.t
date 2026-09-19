package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
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
            name       => 'categories',
            path_query => '/categories?page=1',
            tags       => ['forum:categories'],
        }
    ),
    {
        key  => 'forum-ssr:categories:/categories?page=1',
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

done_testing();

1;
