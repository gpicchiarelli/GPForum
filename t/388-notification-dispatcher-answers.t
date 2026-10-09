# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
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

const my $RANK => 7;

# What the dispatcher answers, which no other test failed without: a
# duplicate delivery describes the notification and the inbox row as they
# were stored -- every column, at the time stored -- the inbox row keeps the
# rank the delivery asked for, and a read that found nothing to mark is
# answered without a count and sends no badge.
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
    rank_score        => $RANK,
    recipient_user_id => 'user-1',
    source_id         => 'post-1',
    source_type       => 'post',
);

my $first = $dispatcher->create_notification( {%delivery} );
ok( $first->{ok} && !$first->{duplicate}, 'the first delivery is stored' );
is( $first->{inbox}{rank_score},
    $RANK, 'its inbox row keeps the rank asked for' );
ok( defined $first->{notification}{created_at}, 'at the time it was stored' );

my $again = $dispatcher->create_notification( {%delivery} );
ok( $again->{duplicate}, 'the same delivery is a duplicate' );

# The columns each answer carries. The doubles add their own keys to the
# hashes the first delivery stored, so the first answer is read through them.
my @inbox_columns = qw(created_at notification_id rank_score read_at
  recipient_user_id);
my @notification_columns = qw(created_at notification_id notification_type
  payload recipient_user_id source_id source_type);
is_deeply(
    $again->{inbox},
    { %{ $first->{inbox} }{@inbox_columns} },
    'which answers with the inbox row as stored, every column'
);
is_deeply(
    $again->{notification},
    { %{ $first->{notification} }{@notification_columns} },
    'and with the notification as stored, at its stored time'
);

my $sent = scalar @{ $badges->badges };
for my $case (
    [
        'a notification the reader does not have',
        '0f0e0d0c-0b0a-4908-8706-050403020100'
    ],
    [ 'an id that is not a uuid', 'not-a-uuid' ],
  )
{
    my ( $label, $notification_id ) = @{$case};
    my $read = $dispatcher->mark_read( $notification_id, 'user-1' );
    is_deeply(
        $read,
        { ok => 0, error => 'not_found' },
        "a read of $label is not found, without a count"
    );
}
is( scalar @{ $badges->badges }, $sent, 'and sends no badge' );

done_testing();

1;
