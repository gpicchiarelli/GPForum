# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Realtime::PgListener;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Test::OutboxPayloadRow;
use GPForum::Test::OutboxRealtimeNotificationHandler;
use GPForum::Test::OutboxResultSet;
use GPForum::Test::OutboxRow;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::RealtimeBusDbh;
use GPForum::Test::RealtimeBusSchema;
use GPForum::Test::RealtimeConnection;
use GPForum::Test::RealtimePermissionEngine;

our $VERSION = '0.001';

const my $BADGE_COUNT => 4;

_assert_thread_update_crosses_processes();
_assert_notification_badge_crosses_processes();
_assert_moderation_invalidation_crosses_processes();
_assert_outbox_polling_fallback();
_assert_outbox_polling_cursor_advances();
_assert_outbox_polling_badge_from_source();

done_testing();

sub _assert_thread_update_crosses_processes {
    my $bus        = GPForum::Test::RealtimeBusDbh->new;
    my $connection = GPForum::Test::RealtimeConnection->new;
    my $listener   = _listener_for( $bus, 'thread:thread-1', $connection );
    my $transport  = _transport_for_bus($bus);

    $listener->start;
    $transport->dispatch(
        _outbox_message(
            {
                event_id       => 'event-post-1',
                event_type     => 'post.created',
                aggregate_type => 'post',
                aggregate_id   => 'post-1',
                actor_id       => 'user-author',
                domain_payload => { thread_id => 'thread-1' },
            }
        )
    );
    my $poll = $listener->poll_once;

    is( $poll->{received},  1, 'listener receives worker NOTIFY event' );
    is( $poll->{delivered}, 1, 'listener delivers remote worker event' );
    is( $connection->sent->[0]{json}{type},
        'thread.update', 'remote worker event reaches local websocket' );
    is( $connection->sent->[0]{json}{payload}{post_id},
        'post-1', 'thread update payload survives cross-process fanout' );

    return;
}

sub _assert_notification_badge_crosses_processes {
    my $bus        = GPForum::Test::RealtimeBusDbh->new;
    my $connection = GPForum::Test::RealtimeConnection->new;
    my $listener   = _listener_for( $bus, 'notifications:user-1', $connection );
    my $transport  = _transport_for_bus(
        $bus,
        [
            GPForum::Test::OutboxRealtimeNotificationHandler->new(
                unread_count => $BADGE_COUNT,
            ),
        ],
    );

    $listener->start;
    $transport->dispatch(
        _outbox_message(
            {
                event_id       => 'event-post-badge',
                event_type     => 'post.created',
                aggregate_type => 'post',
                aggregate_id   => 'post-2',
                actor_id       => 'user-author',
                domain_payload => { thread_id => 'thread-1' },
            }
        )
    );
    my $poll = $listener->poll_once;

    is( $poll->{received}, 2,
        'listener receives thread update and notification badge' );
    is( $connection->sent->[0]{json}{type},
        'notification.badge', 'notification badge reaches remote process' );
    is( $connection->sent->[0]{json}{payload}{unread_count},
        $BADGE_COUNT, 'notification badge carries unread count' );

    return;
}

sub _assert_moderation_invalidation_crosses_processes {
    my $bus        = GPForum::Test::RealtimeBusDbh->new;
    my $connection = GPForum::Test::RealtimeConnection->new;
    my $listener   = _listener_for( $bus, 'moderation:queue', $connection );
    my $transport  = _transport_for_bus($bus);

    $listener->start;
    $transport->dispatch(
        _outbox_message(
            {
                event_id       => 'event-report-1',
                event_type     => 'report.created',
                aggregate_type => 'report',
                aggregate_id   => 'report-1',
                actor_id       => 'user-reporter',
            }
        )
    );
    $listener->poll_once;

    is( $connection->sent->[0]{json}{type},
        'moderation.queue.invalidate',
        'moderation invalidation reaches remote process' );

    return;
}

sub _assert_outbox_polling_fallback {
    my $connection = GPForum::Test::RealtimeConnection->new;
    my $outbox_row = GPForum::Test::OutboxRow->new(
        data => {
            outbox_id       => 'outbox-fallback-1',
            status          => 'done',
            next_attempt_at => '2026-05-28T12:00:00Z',
            created_at      => '2026-05-28T12:00:00Z',
            payload         => {
                event_id       => 'event-fallback-1',
                event_type     => 'post.created',
                aggregate_type => 'post',
                aggregate_id   => 'post-fallback',
                domain_payload => { thread_id => 'thread-fallback' },
            },
        },
    );
    my $schema = GPForum::Test::RealtimeBusSchema->new( outbox_resultset =>
          GPForum::Test::OutboxResultSet->new( rows => [$outbox_row] ), );
    my $listener =
      _listener_for_schema( $schema, 'thread:thread-fallback', $connection );

    my $start = $listener->start;
    my $poll  = $listener->poll_once;

    ok( $start->{degraded}, 'listener starts in polling fallback mode' );
    is( $poll->{received}, 1, 'outbox polling receives fallback event' );
    is( $connection->sent->[0]{json}{type},
        'thread.update', 'outbox polling delivers fallback event' );

    return;
}

sub _assert_outbox_polling_cursor_advances {
    my $connection = GPForum::Test::RealtimeConnection->new;
    my $schema     = GPForum::Test::RealtimeBusSchema->new(
        outbox_resultset => GPForum::Test::OutboxResultSet->new(
            rows => [
                _done_outbox_row(
                    'outbox-cursor-1', 'event-cursor-1',
                    'post-cursor-1',   'thread-cursor'
                ),
                _done_outbox_row(
                    'outbox-cursor-2', 'event-cursor-2',
                    'post-cursor-2',   'thread-cursor'
                ),
            ],
        ),
    );
    my $listener = GPForum::Service::Realtime::PgListener->new(
        batch_limit => 1,
        hub         => _hub_for( 'thread:thread-cursor', $connection ),
        schema      => $schema,
    );

    $listener->start;
    my $first_poll  = $listener->poll_once;
    my $second_poll = $listener->poll_once;

    is( $first_poll->{received}, 1, 'outbox polling reads first cursor batch' );
    is( $second_poll->{received}, 1,
        'outbox polling advances to second batch' );
    is( scalar @{ $connection->sent },
        2, 'outbox polling cursor avoids replaying the first row' );
    is( $connection->sent->[1]{json}{payload}{post_id},
        'post-cursor-2', 'second cursor batch reaches websocket' );

    return;
}

sub _assert_outbox_polling_badge_from_source {
    my $connection    = GPForum::Test::RealtimeConnection->new;
    my $notifications = GPForum::Test::NotificationResultSet->new;
    my $inbox         = GPForum::Test::NotificationResultSet->new;

    $notifications->create(
        {
            notification_id   => 'notification-db-1',
            recipient_user_id => 'user-1',
            source_type       => 'post',
            source_id         => 'post-db-badge',
            notification_type => 'reply',
            created_at        => '2026-05-28T12:00:01Z',
        }
    );
    $inbox->create(
        {
            recipient_user_id => 'user-1',
            notification_id   => 'notification-db-1',
            created_at        => '2026-05-28T12:00:01Z',
            read_at           => undef,
        }
    );
    $inbox->create(
        {
            recipient_user_id => 'user-1',
            notification_id   => 'notification-db-2',
            created_at        => '2026-05-28T12:00:02Z',
            read_at           => undef,
        }
    );

    my $schema = GPForum::Test::RealtimeBusSchema->new(
        notification_inbox_resultset => $inbox,
        notification_resultset       => $notifications,
        outbox_resultset             => GPForum::Test::OutboxResultSet->new(
            rows => [
                _done_outbox_row(
                    'outbox-db-badge', 'event-db-badge',
                    'post-db-badge',   'thread-db-badge'
                ),
            ],
        ),
    );
    my $listener =
      _listener_for_schema( $schema, 'notifications:user-1', $connection );

    $listener->start;
    my $poll = $listener->poll_once;

    is( $poll->{received}, 2,
        'outbox polling reconstructs thread update and badge events' );
    is( $connection->sent->[0]{json}{type},
        'notification.badge', 'outbox polling reconstructs badge from DB' );
    is( $connection->sent->[0]{json}{payload}{unread_count},
        2, 'reconstructed badge uses unread count source of truth' );

    return;
}

sub _transport_for_bus {
    my ( $bus, $handlers ) = @_;

    my $schema = GPForum::Test::RealtimeBusSchema->new( dbh => $bus );

    return GPForum::Service::Outbox::DomainEventTransport->new(
        handlers          => $handlers || [],
        realtime_notifier => GPForum::Service::Realtime::PgNotifier->new(
            schema => $schema,
        ),
    );
}

sub _listener_for {
    my ( $bus, $channel, $connection ) = @_;

    return _listener_for_schema(
        GPForum::Test::RealtimeBusSchema->new( dbh => $bus ),
        $channel, $connection, );
}

sub _listener_for_schema {
    my ( $schema, $channel, $connection ) = @_;

    my $hub = _hub_for( $channel, $connection );

    return GPForum::Service::Realtime::PgListener->new(
        batch_limit => 10,
        hub         => $hub,
        schema      => $schema,
    );
}

sub _hub_for {
    my ( $channel, $connection ) = @_;

    my $hub = GPForum::Service::Realtime::Hub->new(
        registry   => GPForum::Service::Realtime::ConnectionRegistry->new,
        authorizer => GPForum::Service::Realtime::ChannelAuthorizer->new(
            permission_engine => GPForum::Test::RealtimePermissionEngine->new,
        ),
    );
    $hub->register_connection( 'connection-1', { user_id => 'user-1' },
        $connection );
    $hub->subscribe(
        {
            actor         => { user_id => 'user-1' },
            channel       => $channel,
            connection_id => 'connection-1',
            context       => {},
        }
    );

    return $hub;
}

sub _outbox_message {
    my ($payload) = @_;

    return GPForum::Test::OutboxPayloadRow->new(
        data => {
            payload => $payload,
        },
    );
}

sub _done_outbox_row {
    my ( $outbox_id, $event_id, $post_id, $thread_id ) = @_;

    return GPForum::Test::OutboxRow->new(
        data => {
            outbox_id       => $outbox_id,
            status          => 'done',
            next_attempt_at => '2026-05-28T12:00:00Z',
            created_at      => '2026-05-28T12:00:00Z',
            payload         => {
                event_id       => $event_id,
                event_type     => 'post.created',
                aggregate_type => 'post',
                aggregate_id   => $post_id,
                domain_payload => { thread_id => $thread_id },
            },
        },
    );
}

1;
