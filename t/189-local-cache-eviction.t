# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Time::HiRes qw(time);

use lib 'lib';

use GPForum::Service::Operations::LocalCache;

our $VERSION = '0.001';

const my $CAPACITY      => 2_000;
const my $OVERFLOW      => 500;
const my $SMALL         => 3;
const my $MS_PER_SECOND => 1000;
const my %VALUE         => ( a => 1, b => 2, c => 3, d => 4, e => 5, f => 6 );
const my $REWRITTEN     => 33;
const my $MAX_SLOWDOWN  => 20;

# Eviction scanned every key to find the least recently used one, so a write to
# a full cache was O(n). Measured before the fix at 0.005 ms while filling and
# 4.375 ms once full -- a 960x cliff that only appears under the load the cache
# exists to serve, which is why nothing noticed.
my $cache =
  GPForum::Service::Operations::LocalCache->new( max_entries => $CAPACITY );

my $fill_start = time;
for my $index ( 1 .. $CAPACITY ) {
    $cache->put( "warm-$index", $index );
}
my $fill = ( time - $fill_start ) / $CAPACITY;

my $evict_start = time;
for my $index ( 1 .. $OVERFLOW ) {
    $cache->put( "cold-$index", $index );
}
my $evict = ( time - $evict_start ) / $OVERFLOW;

cmp_ok(
    $evict,
    '<',
    $fill * $MAX_SLOWDOWN,
    sprintf 'a write to a full cache stays within %dx of a write to an empty '
      . 'one (%.4f ms vs %.4f ms)',
    $MAX_SLOWDOWN,
    $evict * $MS_PER_SECOND,
    $fill * $MS_PER_SECOND
);

is( scalar keys %{ $cache->entries },
    $CAPACITY, 'the cache stays at its entry bound' );
is( $cache->stats->{evictions}, $OVERFLOW, 'every overflow write evicted one' );

# Speed is worth nothing if it evicts the wrong entry. The list must reflect
# reads, not just writes.
my $order =
  GPForum::Service::Operations::LocalCache->new( max_entries => $SMALL );
$order->put( a => $VALUE{a} );
$order->put( b => $VALUE{b} );
$order->put( c => $VALUE{c} );
$order->get('a');
$order->put( d => $VALUE{d} );

is( $order->get('a'), $VALUE{a}, 'the recently read entry survives' );
is( $order->get('b'), undef,
    'the least recently used entry is the one evicted' );
is( $order->get('c'), $VALUE{c}, 'the untouched newer entry survives' );
is( $order->get('d'), $VALUE{d}, 'the new entry is present' );

# Re-writing an existing key must not grow the cache or corrupt the list.
$order->put( c => $REWRITTEN );
$order->put( e => $VALUE{e} );
is( scalar keys %{ $order->entries },
    $SMALL, 'rewriting a key does not exceed the bound' );
is( $order->get('c'), $REWRITTEN, 'the rewritten value is the one kept' );

# Clearing must reset the list, or the next eviction walks freed keys.
$order->clear;
is( scalar keys %{ $order->entries }, 0, 'clear empties the cache' );
$order->put( f => $VALUE{f} );
is( $order->get('f'), $VALUE{f}, 'the cache still works after a clear' );

done_testing();

1;
