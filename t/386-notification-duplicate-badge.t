# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::BadgeBroadcastSpy;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationTxnSchema;
use GPForum::Test::PermissionEngine;

our $VERSION = '0.001';

# A delivery the recipient already had changes no count, so it sends no
# badge, though its answer still carries the count. A read sends one even
# when it was a read already: the reader's other tabs may hold an older
# count. No test failed when a duplicate delivery broadcast its badge.
my $schema = GPForum::Test::NotificationTxnSchema->new(
    resultsets => {
        Notification      => GPForum::Test::NotificationResultSet->new,
        NotificationInbox => GPForum::Test::NotificationResultSet->new,
        NotificationRead  => GPForum::Test::NotificationResultSet->new,
    },
);
my $badges     = GPForum::Test::BadgeBroadcastSpy->new( schema => $schema );
my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
    clock             => GPForum::Test::FixedClock->new,
    id_service        => GPForum::Test::Id->new,
    permission_engine => GPForum::Test::PermissionEngine->new,
    realtime_notifier => $badges,
    schema            => $schema,
    stats             => { badge_failures => 0 },
);
my %delivery = (
    notification_type => 'reply',
    payload           => { event_id => 'event-1' },
    recipient_user_id => 'user-1',
    source_id         => 'post-1',
    source_type       => 'post',
);

my $first = $dispatcher->create_notification( {%delivery} );
ok( $first->{ok} && !$first->{duplicate}, 'the first delivery is stored' );
is( scalar @{ $badges->badges }, 1, 'and sends a badge' );
is( $badges->badges->[0]{count}, 1, 'with the new count' );

my $again = $dispatcher->create_notification( {%delivery} );
ok( $again->{ok} && $again->{duplicate}, 'the same delivery is a duplicate' );
is( $again->{unread_count},      1, 'whose answer still carries the count' );
is( scalar @{ $badges->badges }, 1, 'and which sends no badge' );

my $notification_id = $first->{notification}{notification_id};
my $read            = $dispatcher->mark_read( $notification_id, 'user-1' );
ok( $read->{ok} && !$read->{duplicate}, 'the read is stored' );
is( scalar @{ $badges->badges }, 2, 'and sends a badge' );
is( $badges->badges->[1]{count}, 0, 'with nothing unread' );

my $sent   = scalar @{ $badges->badges };
my $reread = $dispatcher->mark_read( $notification_id, 'user-1' );
ok( $reread->{ok} && $reread->{duplicate}, 'a second read is a duplicate' );
is( scalar @{ $badges->badges }, $sent + 1,
    'which sends a badge all the same' );

done_testing();

1;
