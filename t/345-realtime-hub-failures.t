# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::Hub;
use GPForum::Test::RealtimeBadgeCounter;
use GPForum::Test::RealtimeConnection;
use Test::More;

our $VERSION = '0.001';

const my $UNREAD => 3;

# A badge counter that dies used to make send_badge_snapshot die too: the
# count was read with "return eval {...}" in an argument list, where a failed
# eval is an empty list, so _send_badge got two arguments for three.
my $counter  = GPForum::Test::RealtimeBadgeCounter->new( fail => 1 );
my $registry = GPForum::Service::Realtime::ConnectionRegistry->new;
my $hub      = GPForum::Service::Realtime::Hub->new(
    badge_counter => $counter,
    registry      => $registry,
);
my $connection = GPForum::Test::RealtimeConnection->new;
$registry->register( 'c-1', { user_id => 'user-1' }, $connection );

is_deeply(
    $hub->send_badge_snapshot('c-1'),
    { ok => 0, reason => 'badge_unavailable' },
    'a counter that dies answers badge_unavailable'
);
is_deeply( $connection->sent, [], 'and nothing is sent' );
is( $hub->resend_badge_snapshots, 0, 'a resend sends nothing either' );

$counter->fail(0);
$counter->counts( { 'user-1' => $UNREAD } );
$connection->fail(1);
my $snapshot = $hub->send_badge_snapshot('c-1');
is( $snapshot->{ok},           0, 'a socket that dies is a send not made' );
is( $snapshot->{unread_count}, $UNREAD, 'with the count it carried' );

$connection->fail(0);
$snapshot = $hub->send_badge_snapshot('c-1');
is( $snapshot->{ok},               1, 'a socket that answers gets the badge' );
is( scalar @{ $connection->sent }, 1, 'once' );

done_testing();

1;
