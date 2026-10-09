# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationTxnSchema;
use GPForum::Test::PermissionEngine;
use GPForum::Test::RefusingNotifier;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

# A badge NOTIFY the notifier refused was raised with die and a string, only
# so that the savepoint around it rolls back. It is an X::Unavailable (ADR
# 0118): the notifier is a dependency that did not answer. The delivery
# stands and the failure is counted with the same message.
my $schema = GPForum::Test::NotificationTxnSchema->new(
    resultsets => {
        Notification      => GPForum::Test::NotificationResultSet->new,
        NotificationInbox => GPForum::Test::NotificationResultSet->new,
        NotificationRead  => GPForum::Test::NotificationResultSet->new,
    },
);
my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
    badge_errors      => {},
    clock             => GPForum::Test::FixedClock->new,
    id_service        => GPForum::Test::Id->new,
    permission_engine => GPForum::Test::PermissionEngine->new,
    realtime_notifier => GPForum::Test::RefusingNotifier->new,
    schema            => $schema,
    stats             => { badge_failures => 0 },
);

my @raised;
my $attempt = \&GPForum::Infrastructure::UniqueConflict::attempt;
{
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings) -- the spy wraps attempt for this block only
    local *GPForum::Infrastructure::UniqueConflict::attempt = sub {
        my @answer = $attempt->(@_);
        if ( defined $answer[1] ) {
            push @raised, $answer[1];
        }
        return @answer;
    };

    my $delivered = $dispatcher->create_notification(
        {
            notification_type => 'reply',
            payload           => { thread_id => 'thread-1' },
            recipient_user_id => 'user-1',
            source_id         => 'post-1',
            source_type       => 'post',
        }
    );
    ok( $delivered->{ok}, 'a delivery whose NOTIFY is refused succeeds' );
    is( $delivered->{unread_count}, 1, 'and keeps the count it read' );
}

is( scalar @raised,
    1, 'the refused NOTIFY is the one error its savepoint caught' );
ok( GPForum::X::Unavailable->caught( $raised[0] ),
    'as a GPForum::X::Unavailable' );
is(
    "$raised[0]",
    'badge NOTIFY failed: listener gone',
    'with the message the string carried'
);
is( $dispatcher->snapshot->{badge_failures}, 1, 'the failure is counted' );
is(
    $dispatcher->snapshot->{last_badge_error}{message},
    'badge NOTIFY failed: listener gone',
    'and kept for /metrics with the same text'
);

done_testing();

1;
