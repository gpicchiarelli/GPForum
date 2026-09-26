# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::PgNotifications;
use GPForum::Service::Operations::CacheInvalidationBus;
use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Realtime::PgListener;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Test::RealtimeBadgeCounter;
use GPForum::Test::RealtimeBusDbh;
use GPForum::Test::RealtimeBusSchema;
use GPForum::Test::RealtimeConnection;
use GPForum::Test::RealtimePermissionEngine;

our $VERSION = '0.001';

const my $WORKER_PID      => 101;
const my $RECONNECTED_PID => 102;
const my $PEER_PID        => 303;
const my $UNREAD_COUNT    => 4;
const my $SMALL_QUEUE     => 2;
const my $CACHE_CHANNEL   => 'gpforum_cache_invalidation';
const my $DOMAIN_CHANNEL  => 'gpforum_domain_events';

# One web process: the cache bus and the realtime listener on one handle,
# sharing one queue, as Bootstrap wires them. A peer backend of the same
# PostgreSQL publishes.
sub _process {
    my $peer    = GPForum::Test::RealtimeBusDbh->new( pg_pid => $PEER_PID );
    my $backend = GPForum::Test::RealtimeBusDbh->new( pg_pid => $WORKER_PID )
      ->join_network($peer);
    my $schema = GPForum::Test::RealtimeBusSchema->new( dbh => $backend );
    my $queue =
      GPForum::Infrastructure::PgNotifications->new( schema => $schema );
    my $thread = GPForum::Test::RealtimeConnection->new;
    my $badge  = GPForum::Test::RealtimeConnection->new;
    my $hub    = GPForum::Service::Realtime::Hub->new(
        authorizer => GPForum::Service::Realtime::ChannelAuthorizer->new(
            permission_engine => GPForum::Test::RealtimePermissionEngine->new,
        ),
        badge_counter => GPForum::Test::RealtimeBadgeCounter->new(
            counts => { 'user-1' => $UNREAD_COUNT },
        ),
        registry => GPForum::Service::Realtime::ConnectionRegistry->new,
    );
    _subscribe( $hub, 'thread-socket', 'thread:thread-1',      $thread );
    _subscribe( $hub, 'badge-socket',  'notifications:user-1', $badge );

    my $peer_schema = GPForum::Test::RealtimeBusSchema->new( dbh => $peer );

    return {
        backend => $backend,
        badge   => $badge,
        bus     => GPForum::Service::Operations::CacheInvalidationBus->new(
            notifications => $queue,
            schema        => $schema,
        ),
        listener => GPForum::Service::Realtime::PgListener->new(
            hub           => $hub,
            notifications => $queue,
            schema        => $schema,
        ),
        peer     => $peer,
        peer_bus => GPForum::Service::Operations::CacheInvalidationBus->new(
            schema => $peer_schema
        ),
        peer_notifier =>
          GPForum::Service::Realtime::PgNotifier->new( schema => $peer_schema ),
        queue  => $queue,
        schema => $schema,
        thread => $thread,
    };
}

sub _subscribe {
    my ( $hub, $connection_id, $channel, $connection ) = @_;

    $hub->register_connection( $connection_id, { user_id => 'user-1' },
        $connection );
    $hub->subscribe(
        {
            actor         => { user_id => 'user-1' },
            channel       => $channel,
            connection_id => $connection_id,
            context       => {},
        }
    );

    return;
}

sub _thread_event {
    my ($post_id) = @_;

    return GPForum::Service::Realtime::EventEnvelope->new->build(
        type           => 'thread.update',
        aggregate_type => 'thread',
        aggregate_id   => 'thread-1',
        payload        => { post_id => $post_id, thread_id => 'thread-1' },
    );
}

sub _start {
    my ($process) = @_;

    $process->{listener}->start;
    $process->{bus}->drain;

    return;
}

# The listener read every notification on the handle and dropped the cache
# purges as malformed, so that worker served a hidden post from L1 until it
# expired. The bus read every notification too and took realtime events as
# empty invalidations.
subtest 'the listener polls first: the cache purges wait for the bus' => sub {
    my $process = _process();
    _start($process);

    $process->{peer_bus}->publish( { tags => ['thread:thread-1'] } );
    $process->{peer_notifier}->notify( _thread_event('post-1') );
    $process->{peer_bus}->publish( { keys => ['public:/t/thread-1'] } );

    my $poll = $process->{listener}->poll_once;
    is( $poll->{received}, 1, 'the listener receives only its own event' );
    is( $process->{listener}->snapshot->{malformed_payloads},
        0, 'and rejects nothing as malformed' );
    is( $process->{thread}->sent->[0]{json}{payload}{post_id},
        'post-1', 'the event reaches the socket' );

    my $requests = $process->{bus}->drain;
    is_deeply(
        [ map { [ $_->{tags}, $_->{keys} ] } @{$requests} ],
        [ [ ['thread:thread-1'], [] ], [ [], ['public:/t/thread-1'] ] ],
        'the bus still gets both invalidations, in order'
    );
};

subtest 'the bus drains first: the event waits for the listener' => sub {
    my $process = _process();
    _start($process);

    $process->{peer_notifier}->notify( _thread_event('post-2') );
    $process->{peer_bus}->publish( { tags => ['thread:thread-1'] } );

    my $requests = $process->{bus}->drain;
    is( scalar @{$requests}, 1, 'the bus gets only the cache purge' );
    is( $process->{bus}->stats->{applied},
        1, 'and applies no realtime event as an empty invalidation' );

    my $poll = $process->{listener}->poll_once;
    is( $poll->{received},  1, 'the listener still receives its event' );
    is( $poll->{delivered}, 1, 'and delivers it' );
};

# DBIx::Class replaces the handle after a reconnect, and a LISTEN lives on
# one backend. The listener's was never re-issued; it kept reporting
# "listening" and received nothing.
subtest 'a new backend is listened to again and reported as a gap' => sub {
    my $process = _process();
    _start($process);

    my $reconnected =
      GPForum::Test::RealtimeBusDbh->new( pg_pid => $RECONNECTED_PID )
      ->join_network( $process->{peer} );
    $process->{schema}->dbh($reconnected);

    is_deeply(
        $process->{bus}->drain,
        [ { clear => 1, keys => [], tags => [] } ],
        'the bus clears L1 once: what was NOTIFYed meanwhile is gone'
    );
    is_deeply(
        [ sort keys %{ $reconnected->listening } ],
        [ $CACHE_CHANNEL, $DOMAIN_CHANNEL ],
        'both channels are listened to on the new backend'
    );
    is_deeply( $process->{bus}->drain, [], 'one clear, not one per drain' );

    $process->{listener}->poll_once;
    is( $process->{badge}->sent->[-1]{json}{type},
        'notification.badge', 'the listener re-sends the badge snapshots' );
    is( $process->{badge}->sent->[-1]{json}{payload}{unread_count},
        $UNREAD_COUNT, 'with the current unread count' );
    is( scalar @{ $process->{thread}->sent },
        0, 'and nothing to the sockets of other channels' );
    is( $process->{listener}->status, 'listening', 'it is listening again' );

    $process->{peer_notifier}->notify( _thread_event('post-3') );
    $process->{listener}->poll_once;
    is( $process->{thread}->sent->[-1]{json}{payload}{post_id},
        'post-3', 'and delivery resumes' );
    is( $process->{queue}->snapshot->{relistens},
        2, 'the queue counts the channels it listened to again' );
};

subtest 'a full queue drops its oldest and reports a gap' => sub {
    my $backend = GPForum::Test::RealtimeBusDbh->new;
    my $schema  = GPForum::Test::RealtimeBusSchema->new( dbh => $backend );
    my $queue   = GPForum::Infrastructure::PgNotifications->new(
        max_queued => $SMALL_QUEUE,
        schema     => $schema,
    );
    my $bus = GPForum::Service::Operations::CacheInvalidationBus->new(
        notifications => $queue,
        schema        => $schema,
    );
    my $publisher = GPForum::Service::Operations::CacheInvalidationBus->new(
        schema => GPForum::Test::RealtimeBusSchema->new(
            dbh => GPForum::Test::RealtimeBusDbh->new( pg_pid => $PEER_PID )
              ->join_network($backend)
        ),
    );
    $bus->drain;

    for my $tag (qw(a b c)) {
        $publisher->publish( { tags => [$tag] } );
    }

    # Another consumer on the handle pumps every channel, including this
    # one it does not take, and each take reads at most max_queued. The bus
    # is not read before its queue overflows.
    $queue->listen_to($DOMAIN_CHANNEL);
    for ( 1 .. 2 ) {
        $queue->take($DOMAIN_CHANNEL);
    }

    is( $queue->snapshot->{overflowed}, 1, 'the queue overflows once' );
    is_deeply(
        $bus->drain,
        [ { clear => 1, keys => [], tags => [] } ],
        'the bus clears L1 rather than apply what is left'
    );
};

subtest 'notifications nobody registered are dropped, not queued' => sub {
    my $backend = GPForum::Test::RealtimeBusDbh->new;
    my $queue   = GPForum::Infrastructure::PgNotifications->new(
        schema => GPForum::Test::RealtimeBusSchema->new( dbh => $backend ) );
    $queue->listen_to($CACHE_CHANNEL);
    push @{ $backend->notifies }, [ 'gpforum_elsewhere', 1, '{}' ];

    is_deeply( $queue->take($CACHE_CHANNEL)->{notifications},
        [], 'the registered channel gets nothing' );
    is( $queue->snapshot->{dropped}, 1, 'and the stray one is counted' );
    is( $queue->take('gpforum_unregistered')->{available},
        0, 'a channel never registered is not read at all' );
};

subtest 'nothing is read or listened to inside a transaction' => sub {
    my $backend = GPForum::Test::RealtimeBusDbh->new;
    my $queue   = GPForum::Infrastructure::PgNotifications->new(
        schema => GPForum::Test::RealtimeBusSchema->new( dbh => $backend ) );
    $backend->{AutoCommit} = 0;

    ok( !$queue->listen_to($CACHE_CHANNEL),
        'a LISTEN a rollback could undo is not issued' );
    is_deeply( $backend->listening, {}, 'so nothing is listened to yet' );

    $backend->{AutoCommit} = 1;
    $queue->take($CACHE_CHANNEL);
    ok( $queue->listening($CACHE_CHANNEL),
        'the next take outside the transaction issues it' );
};

subtest 'the bus still skips its own notifications' => sub {
    my $process = _process();
    _start($process);

    $process->{bus}->publish( { tags => ['thread:thread-1'] } );

    is_deeply( $process->{bus}->drain, [], 'its own purge is not replayed' );
    is( $process->{bus}->stats->{skipped_self}, 1, 'and is counted' );
};

done_testing();

1;
