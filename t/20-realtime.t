# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::Hub;
use GPForum::Test::FixedClock;
use GPForum::Test::RealtimeBadgeCounter;
use GPForum::Test::RealtimeConnection;
use GPForum::Test::RealtimePermissionEngine;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 50;
const my $POLL_SECONDS   => 30;
const my $UNREAD_COUNT   => 7;

plan tests => $EXPECTED_TESTS;

my $parsed = GPForum::Service::Realtime::ChannelAuthorizer::parse_channel(
    'thread:thread-1');

is( $parsed->{type},        'thread',   'channel parser extracts type' );
is( $parsed->{resource_id}, 'thread-1', 'channel parser extracts resource id' );
ok( !GPForum::Service::Realtime::ChannelAuthorizer::parse_channel('broken'),
    'channel parser rejects malformed channel' );

my $authorizer = GPForum::Service::Realtime::ChannelAuthorizer->new;
my $own_notifications =
  $authorizer->authorize( { user_id => 'user-1' }, 'notifications:user-1',
    {}, );
ok( $own_notifications->{ok}, 'user can subscribe own notifications' );
is( $own_notifications->{reason},
    'own_notifications', 'own notification reason is explicit' );

my $wrong_notifications =
  $authorizer->authorize( { user_id => 'user-1' }, 'notifications:user-2',
    {}, );
ok( !$wrong_notifications->{ok}, 'user cannot subscribe other notifications' );
is( $wrong_notifications->{reason},
    'wrong_recipient', 'wrong notification recipient reason is explicit' );

my $anonymous_thread =
  $authorizer->authorize( {}, 'thread:thread-1', {}, );
ok( !$anonymous_thread->{ok}, 'anonymous actor cannot subscribe thread' );
is( $anonymous_thread->{reason},
    'authentication_required', 'anonymous denial reason is explicit' );

my $unconfigured_thread =
  $authorizer->authorize( { user_id => 'user-1' }, 'thread:thread-1', {}, );
ok( !$unconfigured_thread->{ok}, 'thread subscription denies without policy' );
is( $unconfigured_thread->{reason},
    'forbidden', 'thread subscription deny-by-default reason is explicit' );

my $unknown_channel =
  $authorizer->authorize( { user_id => 'user-1' }, 'unknown:resource', {}, );
ok( !$unknown_channel->{ok}, 'unknown channel type is denied' );
is( $unknown_channel->{reason},
    'unknown_channel', 'unknown channel reason is explicit' );

# Nothing was ever published to presence, and a shared presence registry is
# ruled out (ADR 0067): the family is gone rather than open to every user.
is(
    $authorizer->authorize( { user_id => 'user-1' }, 'presence:lobby', {} )
      ->{reason},
    'unknown_channel',
    'presence is not a channel family'
);

my $policy_authorizer = GPForum::Service::Realtime::ChannelAuthorizer->new(
    permission_engine => GPForum::Test::RealtimePermissionEngine->new(
        denied => { 'thread-denied' => 1 },
    ),
);
ok(
    $policy_authorizer->authorize( { user_id => 'user-1' },
        'thread:thread-1', {}, )->{ok},
    'policy can allow thread channel'
);
is(
    $policy_authorizer->authorize( { user_id => 'user-1' },
        'thread:thread-denied', {}, )->{reason},
    'forbidden',
    'policy can deny thread channel'
);

my $registry = GPForum::Service::Realtime::ConnectionRegistry->new(
    clock => GPForum::Test::FixedClock->new, );
my $connection = GPForum::Test::RealtimeConnection->new;
my $row =
  $registry->register( 'connection-1', { user_id => 'user-1' }, $connection, );

is( $row->{connection_id},  'connection-1', 'registry stores connection id' );
is( $row->{actor}{user_id}, 'user-1',       'registry stores actor' );
is( $row->{connected_at},
    '2026-05-23T12:00:00Z', 'registry stores connection time' );
ok( $registry->connection('connection-1'), 'connection can be fetched' );

$registry->subscribe( 'connection-1', 'thread:thread-1' );
my @thread_subscribers = $registry->subscribers('thread:thread-1');
is( scalar @thread_subscribers, 1, 'registry lists channel subscribers' );
is( $registry->count,           1, 'registry counts its connections' );
is( scalar $registry->subscribers_of_family('thread'),
    1, 'registry lists the subscribers of a channel family' );
is( scalar $registry->subscribers_of_family('notifications'),
    0, 'and not those of another family' );

my $snapshot = $registry->snapshot;
is( $snapshot->{connections},   1, 'snapshot counts connections' );
is( $snapshot->{subscriptions}, 1, 'snapshot counts subscriptions' );

$registry->unregister('connection-1');
is( $registry->snapshot->{connections}, 0, 'registry unregisters connection' );

my $hub = GPForum::Service::Realtime::Hub->new(
    authorizer    => $policy_authorizer,
    badge_counter => GPForum::Test::RealtimeBadgeCounter->new(
        counts => { 'user-1' => $UNREAD_COUNT },
    ),
    registry => GPForum::Service::Realtime::ConnectionRegistry->new,
);
my $thread_connection = GPForum::Test::RealtimeConnection->new;
my $badge_connection  = GPForum::Test::RealtimeConnection->new;

$hub->register_connection( 'thread-connection', { user_id => 'user-1' },
    $thread_connection, );
$hub->register_connection( 'badge-connection', { user_id => 'user-1' },
    $badge_connection, );

my $thread_subscription = $hub->subscribe(
    {
        connection_id => 'thread-connection',
        actor         => { user_id => 'user-1' },
        channel       => 'thread:thread-1',
        context       => {},
    }
);
ok( $thread_subscription->{ok}, 'hub subscribes thread channel' );
is( $thread_subscription->{channel},
    'thread:thread-1', 'hub returns subscribed channel' );

my $badge_subscription = $hub->subscribe(
    {
        connection_id => 'badge-connection',
        actor         => { user_id => 'user-1' },
        channel       => 'notifications:user-1',
        context       => {},
    }
);
ok( $badge_subscription->{ok}, 'hub subscribes notification channel' );

my $thread_broadcast =
  $hub->broadcast_thread_update( 'thread-1', { post_id => 'post-1' } );
ok( $thread_broadcast->{ok}, 'thread broadcast succeeds' );
is( $thread_broadcast->{delivered}, 1, 'thread broadcast delivers once' );
is( $thread_broadcast->{failed}, 0, 'thread broadcast records zero failures' );
is( $thread_connection->sent->[0]{json}{type},
    'thread.update', 'thread broadcast sends update type' );
is( $thread_connection->sent->[0]{json}{payload}{post_id},
    'post-1', 'thread broadcast sends payload' );

# Badges reach a hub through NOTIFY like every other event; the hub only
# sends snapshots, to one connection at a time.
my $badge_snapshot = $hub->send_badge_snapshot('badge-connection');
ok( $badge_snapshot->{ok}, 'badge snapshot succeeds' );
is( $badge_connection->sent->[0]{json}{type},
    'notification.badge', 'badge snapshot sends the badge type' );
is( $badge_connection->sent->[0]{json}{payload}{unread_count},
    $UNREAD_COUNT, 'badge snapshot carries the counter\'s unread count' );
is( $badge_connection->sent->[0]{json}{aggregate_id},
    'user-1', 'badge snapshot names the connection\'s user' );
is( scalar @{ $thread_connection->sent },
    1, 'a snapshot goes to that connection alone' );
is( $hub->resend_badge_snapshots,
    1,
    'a resend reaches each notifications subscriber and no other connection' );
is( $hub->connection_count, 2, 'hub counts its local connections' );

my $fallback = $hub->fallback_state;
is( $fallback->{realtime_required}, 0, 'realtime is never required' );
is( $fallback->{poll_after_seconds},
    $POLL_SECONDS, 'fallback exposes polling interval' );
is( $fallback->{endpoints}{notifications},
    '/notifications', 'fallback exposes notification endpoint' );

$hub->disconnect('thread-connection');
is( $hub->snapshot->{connections}, 1, 'hub disconnect removes connection' );

my $denied = $hub->subscribe(
    {
        connection_id => 'badge-connection',
        actor         => { user_id => 'user-1' },
        channel       => 'notifications:user-2',
        context       => {},
    }
);
ok( !$denied->{ok}, 'hub returns denied subscription' );
is( $denied->{reason}, 'wrong_recipient', 'hub returns denial reason' );

my $failing_connection = GPForum::Test::RealtimeConnection->new( fail => 1 );
$hub->register_connection( 'failing-connection', { user_id => 'user-1' },
    $failing_connection, );
$hub->subscribe(
    {
        connection_id => 'failing-connection',
        actor         => { user_id => 'user-1' },
        channel       => 'thread:thread-1',
        context       => {},
    }
);
my $degraded_broadcast =
  $hub->broadcast_thread_update( 'thread-1', { post_id => 'post-2' } );
ok( $degraded_broadcast->{ok},
    'realtime broadcast remains non-authoritative on send failure' );
is( $degraded_broadcast->{failed},
    1, 'realtime broadcast records failed local delivery' );

1;
