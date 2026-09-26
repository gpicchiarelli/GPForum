# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::JSON qw(decode_json);
use Mojolicious;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Operations::SecurityTelemetry;
use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::Hub;
use GPForum::Test::AllowLimiter;
use GPForum::Test::Id;
use GPForum::Test::RealtimeBadgeCounter;
use GPForum::Test::RealtimePermissionEngine;

our $VERSION = '0.001';

const my $UNREAD_COUNT => 4;
const my $HTTP_OK      => 200;

# A socket that drops -- an idle timeout, a node that failed -- reconnects,
# possibly to another node, and there is no replay log (ADR 0110). A badge
# changed while it was away stayed wrong until the next change. A
# notifications subscription is now answered with the current count.
my $counter = GPForum::Test::RealtimeBadgeCounter->new(
    counts => { 'user-1' => $UNREAD_COUNT } );
my $test = Test::Mojo->new( _application($counter) );

$test->get_ok('/sign-in/user-1')->status_is($HTTP_OK);
$test->websocket_ok('/realtime');
is( _next_frame($test)->{type}, 'realtime.connected', 'the socket connects' );

_subscribe( $test, 'thread:t-1' );
is_deeply(
    [ @{ _next_frame($test) }{qw(type channel)} ],
    [ 'subscribed', 'thread:t-1' ],
    'a thread subscription is confirmed'
);

_subscribe( $test, 'notifications:user-1' );
is_deeply(
    [ @{ _next_frame($test) }{qw(type channel)} ],
    [ 'subscribed', 'notifications:user-1' ],
    'and answered with no badge: the next frame confirms the next one'
);
my $badge = _next_frame($test);
is( $badge->{type}, 'notification.badge',
    'a notifications subscription is followed by a badge' );
is( $badge->{aggregate_id}, 'user-1', 'for the subscriber' );
is( $badge->{payload}{unread_count},
    $UNREAD_COUNT, 'carrying the current count' );
is_deeply( $counter->calls, ['user-1'],
    'counted once, by the inbox\'s own count' );

_subscribe( $test, 'notifications:user-2' );
is_deeply(
    [ @{ _next_frame($test) }{qw(type reason)} ],
    [ 'error', 'wrong_recipient' ],
    'another user\'s notifications are refused'
);
is( scalar @{ $counter->calls },
    1, 'and a denied subscription sends no one\'s count' );

$test->finish_ok;

done_testing();

sub _subscribe {
    my ( $client, $channel ) = @_;

    $client->send_ok(
        { json => { type => 'subscribe', channel => $channel } } );

    return;
}

sub _next_frame {
    my ($client) = @_;

    $client->message_ok;

    return decode_json( $client->message->[1] );
}

sub _application {
    my ($badge_counter) = @_;

    my $application = Mojolicious->new;
    $application->secrets( ['realtime-subscribe-snapshot'] );
    $application->log->level('fatal');
    push @{ $application->routes->namespaces }, 'GPForum::Controller';

    my $hub = GPForum::Service::Realtime::Hub->new(
        authorizer => GPForum::Service::Realtime::ChannelAuthorizer->new(
            permission_engine => GPForum::Test::RealtimePermissionEngine->new,
        ),
        badge_counter => $badge_counter,
        registry      => GPForum::Service::Realtime::ConnectionRegistry->new,
    );
    my $id        = GPForum::Test::Id->new;
    my $config    = GPForum::Config->new;
    my $limiter   = GPForum::Test::AllowLimiter->new;
    my $telemetry = GPForum::Service::Operations::SecurityTelemetry->new;
    $application->helper( gp_config             => sub { return $config; } );
    $application->helper( gp_id                 => sub { return $id; } );
    $application->helper( gp_realtime_hub       => sub { return $hub; } );
    $application->helper( gp_rate_limiter       => sub { return $limiter; } );
    $application->helper( gp_security_telemetry => sub { return $telemetry; } );

    $application->routes->get(
        '/sign-in/:user_id' => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( text => 'signed in' );
        }
    );
    $application->routes->websocket('/realtime')->to('Realtime#stream');

    return $application;
}

1;
