# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::LocalCache;
use GPForum::Test::OperationsClock;

our $VERSION = '0.001';

const my $EXPECTED_TESTS      => 17;
const my $SHORT_TTL_SECONDS   => 5;
const my $AFTER_TTL_EPOCH     => 106;
const my $CACHE_LIMIT         => 2;
const my $FIRST_VALUE         => 1;
const my $SECOND_VALUE        => 2;
const my $THIRD_VALUE         => 3;
const my $PRODUCER_CALLS      => 1;
const my $INVALIDATED_COUNT   => 2;
const my $EVICTED_ENTRY_COUNT => 1;

plan tests => $EXPECTED_TESTS;

my $clock = GPForum::Test::OperationsClock->new;
my $cache = GPForum::Service::Operations::LocalCache->new(
    clock       => $clock,
    max_entries => $CACHE_LIMIT,
    namespace   => 'test-cache',
    ttl_seconds => $SHORT_TTL_SECONDS,
);

my $producer_calls = 0;
my $first          = $cache->get_or_set(
    'categories:list:10',
    sub {
        $producer_calls += 1;
        return [ { title => 'General' } ];
    },
    { tags => [ 'categories', 'forum-index' ] },
);

is( $first->[0]{title}, 'General',        'cache stores generated value' );
is( $producer_calls,    $PRODUCER_CALLS,  'producer is called on miss' );
is( $cache->snapshot->{stats}{misses}, 1, 'cache records miss' );
is( $cache->snapshot->{stats}{writes}, 1, 'cache records write' );

my $cached_again = $cache->get_or_set(
    'categories:list:10',
    sub {
        $producer_calls += 1;
        return [ { title => 'Unexpected' } ];
    },
);

is( $cached_again->[0]{title},
    'General', 'cache returns existing value on hit' );
is( $producer_calls, $PRODUCER_CALLS,   'producer is not called on hit' );
is( $cache->snapshot->{stats}{hits}, 1, 'cache records hit' );
is( $cache->snapshot->{entries},     1, 'cache snapshot counts entries' );
is( $cache->snapshot->{tags},        2, 'cache snapshot counts tags' );

$clock->epoch($AFTER_TTL_EPOCH);
is( $cache->get('categories:list:10'),  undef, 'expired value is removed' );
is( $cache->snapshot->{stats}{expired}, 1,     'cache records expiration' );

$cache->put( 'thread:1', { id => 1 }, { tags => [ 'thread:1', 'threads' ] } );
$cache->put( 'thread:2', { id => 2 }, { tags => [ 'thread:1', 'threads' ] } );
is( $cache->invalidate_tag('thread:1'),
    $INVALIDATED_COUNT, 'tag invalidation removes matching entries' );
is( $cache->snapshot->{entries}, 0, 'tag invalidation leaves cache empty' );

$cache->put( 'a', $FIRST_VALUE );
$clock->epoch( $clock->epoch + 1 );
$cache->put( 'b', $SECOND_VALUE );
$clock->epoch( $clock->epoch + 1 );
$cache->put( 'c', $THIRD_VALUE );
is( $cache->get('a'), undef, 'max entries evicts least recent entry' );
is( $cache->snapshot->{stats}{evictions},
    $EVICTED_ENTRY_COUNT, 'cache records eviction' );

throws_ok(
    sub {
        $cache->put( q{}, 1 );
    },
    qr/\A cache [ ] key [ ] is [ ] required/msx,
    'empty cache key is rejected'
);
is( $cache->clear, $CACHE_LIMIT, 'clear removes remaining entries' );

1;
