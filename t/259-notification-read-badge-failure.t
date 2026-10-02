# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::AllowLimiter;
use GPForum::Test::BadgeBroadcastSpy;
use GPForum::Test::FailingNotificationReadability;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationTxnSchema;
use GPForum::Test::PermissionEngine;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

# A mark-read commits, then the badge is counted. A count that failed was
# raised past the commit, and the request answered as a server failure
# although the read was stored: the member, retrying, found it read already.
# The write's answer stands; only the badge is missing.
my $inbox  = GPForum::Test::NotificationResultSet->new;
my $schema = GPForum::Test::NotificationTxnSchema->new(
    resultsets => {
        Notification      => GPForum::Test::NotificationResultSet->new,
        NotificationInbox => $inbox,
        NotificationRead  => GPForum::Test::NotificationResultSet->new,
    },
);
my $readability = GPForum::Test::FailingNotificationReadability->new;
my $badges      = GPForum::Test::BadgeBroadcastSpy->new( schema => $schema );
my $dispatcher  = GPForum::Service::Notification::Dispatcher->new(
    clock             => GPForum::Test::FixedClock->new,
    id_service        => GPForum::Test::Id->new,
    permission_engine => GPForum::Test::PermissionEngine->new,
    readability       => $readability,
    realtime_notifier => $badges,
    schema            => $schema,
    stats             => { badge_failures => 0 },
);
my $delivered = $dispatcher->create_notification(
    {
        notification_type => 'reply',
        payload           => { thread_id => 'thread-1' },
        recipient_user_id => 'user-1',
        source_id         => 'post-1',
        source_type       => 'post',
    }
);
my $notification_id = $delivered->{notification}{notification_id};
ok( $notification_id, 'the member has a notification to read' );

my $test = Test::Mojo->new('GPForum');
$test->app->helper( gp_notification_dispatcher => sub { return $dispatcher; } );
$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );
_install_test_routes($test);

$test->get_ok('/__test/session/user-1');
my $csrf_token = _csrf_token($test);

$readability->fail(1);
$test->post_ok( "/notifications/$notification_id/read" =>
      { Accept => 'application/json' } => form => { csrf_token => $csrf_token }
);
$test->status_is( $HTTP_OK,
    'a mark-read whose badge count fails after the commit answers 200' );
$test->json_is( '/status'       => 'read' );
$test->json_is( '/unread_count' => undef, 'with no unread count' );

is(
    $inbox->find(
        {
            notification_id   => $notification_id,
            recipient_user_id => 'user-1',
        }
    )->get_column('read_at'),
    '2026-05-23T12:00:00Z',
    'the read is stored'
);
is( $dispatcher->snapshot->{badge_failures},
    1, 'the badge that could not be counted is counted' );
is( scalar @{ $badges->badges }, 1, 'and no badge is sent without a count' );

done_testing();

sub _install_test_routes {
    my ($test_object) = @_;

    my $routes        = $test_object->app->routes;
    my $session_route = $routes->get('/__test/session/:user_id');
    $session_route->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );
    my $csrf_route = $routes->get('/__test/csrf');
    $csrf_route->to(
        cb => sub {
            my ($controller) = @_;

            return $controller->render(
                json => { csrf_token => $controller->csrf_token } );
        }
    );

    return;
}

sub _csrf_token {
    my ($test_object) = @_;

    $test_object->get_ok( '/__test/csrf' => { Accept => 'application/json' } );
    $test_object->status_is($HTTP_OK);

    return $test_object->tx->res->json->{csrf_token};
}

1;
