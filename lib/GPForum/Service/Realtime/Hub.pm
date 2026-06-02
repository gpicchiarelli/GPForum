package GPForum::Service::Realtime::Hub;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::EventEnvelope;

our $VERSION = '0.001';

const my $FALLBACK_POLL_SECONDS => 30;
const my $THREAD_UPDATE         => 'thread.update';
const my $NOTIFICATION_BADGE    => 'notification.badge';
const my $MODERATION_INVALIDATE => 'moderation.queue.invalidate';
const my %CHANNEL_TYPE_FOR_EVENT => (
    $THREAD_UPDATE      => 'thread',
    $NOTIFICATION_BADGE => 'notifications',
);

has authorizer =>
  sub { return GPForum::Service::Realtime::ChannelAuthorizer->new; };
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has registry =>
  sub { return GPForum::Service::Realtime::ConnectionRegistry->new; };
has stats => sub {
    return {
        broadcast          => 0,
        broadcast_failures => 0,
        broadcasts         => 0,
        delivered          => 0,
        failed             => 0,
        malformed          => 0,
        malformed_events   => 0,
    };
};

sub register_connection {
    my ( $self, $connection_id, $actor, $connection ) = @_;

    return $self->registry->register( $connection_id, $actor, $connection );
}

sub disconnect {
    my ( $self, $connection_id ) = @_;

    return $self->registry->unregister($connection_id);
}

sub subscribe {
    my ( $self, $request ) = @_;

    my $authorization =
      $self->authorizer->authorize( $request->{actor}, $request->{channel},
        $request->{context} || {},
      );
    return $authorization if !$authorization->{ok};

    my $subscription = $self->registry->subscribe( $request->{connection_id},
        $request->{channel} );
    return $subscription if !$subscription->{ok};

    return {
        ok      => 1,
        channel => $request->{channel},
        reason  => $authorization->{reason},
    };
}

sub broadcast {
    my ( $self, $channel, $payload ) = @_;

    my @subscribers = $self->registry->subscribers($channel);
    my $delivered   = 0;
    my $failed      = 0;
    $self->stats->{broadcast}  += 1;
    $self->stats->{broadcasts} += 1;

    for my $subscriber (@subscribers) {
        my $sent = _send_json( $subscriber->{connection}, $payload );
        if ($sent) {
            $delivered++;
        }
        else {
            $failed++;
        }
    }
    $self->stats->{delivered}          += $delivered;
    $self->stats->{failed}             += $failed;
    $self->stats->{broadcast_failures} += $failed;

    return {
        ok        => 1,
        channel   => $channel,
        delivered => $delivered,
        failed    => $failed,
    };
}

sub broadcast_thread_update {
    my ( $self, $thread_id, $payload ) = @_;

    my $event = $self->event_contract->build(
        type           => $THREAD_UPDATE,
        aggregate_type => 'thread',
        aggregate_id   => $thread_id,
        payload        => $payload || {},
        metadata       => { channel_type => 'thread' },
    );
    $event->{thread_id} = $thread_id;

    return $self->broadcast( _channel( 'thread', $thread_id ), $event, );
}

sub broadcast_notification_badge {
    my ( $self, $user_id, $count ) = @_;

    my $event = $self->event_contract->build(
        type           => $NOTIFICATION_BADGE,
        aggregate_type => 'user',
        aggregate_id   => $user_id,
        payload        => { unread_count => $count },
        metadata       => { channel_type => 'notifications' },
    );
    $event->{user_id}      = $user_id;
    $event->{unread_count} = $count;

    return $self->broadcast( _channel( 'notifications', $user_id ), $event, );
}

sub broadcast_event {
    my ( $self, $event ) = @_;

    my $rejection = $self->_event_rejection($event);
    return $rejection if $rejection;

    my @channels = _channels_for_event($event);
    return _empty_broadcast_event_summary() if !@channels;

    return $self->_broadcast_to_channels( $event, @channels );
}

sub _event_rejection {
    my ( $self, $event ) = @_;

    my $validation = $self->event_contract->validate($event);
    return if $validation->{ok};

    $self->stats->{malformed}        += 1;
    $self->stats->{malformed_events} += 1;

    return { ok => 0, reason => $validation->{reason} };
}

sub _broadcast_to_channels {
    my ( $self, $event, @channels ) = @_;

    my %summary = (
        ok        => 1,
        delivered => 0,
        failed    => 0,
        channels  => \@channels,
    );

    for my $channel (@channels) {
        my $result = $self->broadcast( $channel, $event );
        $summary{delivered} += $result->{delivered} || 0;
        $summary{failed}    += $result->{failed}    || 0;
    }

    return \%summary;
}

sub _empty_broadcast_event_summary {
    return { ok => 1, delivered => 0, failed => 0, channels => [] };
}

sub fallback_state {
    my ($self) = @_;

    return {
        realtime_required  => 0,
        poll_after_seconds => $FALLBACK_POLL_SECONDS,
        endpoints          => {
            notifications => '/notifications',
            thread        => '/thread/:thread_id',
        },
    };
}

sub snapshot {
    my ($self) = @_;

    return { %{ $self->registry->snapshot }, %{ $self->stats }, };
}

sub _send_json {
    my ( $connection, $payload ) = @_;

    return if !$connection;

    return eval { return $connection->send( { json => $payload } ); };
}

sub _channel {
    my ( $type, $id ) = @_;

    return join q{:}, $type, $id;
}

sub _channels_for_event {
    my ($event) = @_;

    my $event_type = $event->{type} || q{};
    if ( exists $CHANNEL_TYPE_FOR_EVENT{$event_type} ) {
        my $channel_type = $CHANNEL_TYPE_FOR_EVENT{$event_type};
        return _aggregate_channel( $channel_type, $event );
    }

    return _moderation_channels($event);
}

sub _aggregate_channel {
    my ( $channel_type, $event ) = @_;

    return if !defined $event->{aggregate_id};

    return ( _channel( $channel_type, $event->{aggregate_id} ) );
}

sub _moderation_channels {
    my ($event) = @_;

    if ( ( $event->{type} || q{} ) eq $MODERATION_INVALIDATE ) {
        return ('moderation:queue');
    }

    return;
}

1;
