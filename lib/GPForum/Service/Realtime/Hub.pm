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

has authorizer =>
  sub { return GPForum::Service::Realtime::ChannelAuthorizer->new; };
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has registry =>
  sub { return GPForum::Service::Realtime::ConnectionRegistry->new; };
has stats => sub {
    return {
        broadcast_failures => 0,
        broadcasts         => 0,
        delivered          => 0,
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

    my $validation = $self->event_contract->validate($event);
    if ( !$validation->{ok} ) {
        $self->stats->{malformed_events} += 1;
        return { ok => 0, reason => $validation->{reason} };
    }

    my @channels = _channels_for_event($event);
    return { ok => 1, delivered => 0, failed => 0, channels => [] }
      if !@channels;

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

    return ( _channel( 'thread', $event->{aggregate_id} ) )
      if $event->{type} eq $THREAD_UPDATE
      && defined $event->{aggregate_id};

    return ( _channel( 'notifications', $event->{aggregate_id} ) )
      if $event->{type} eq $NOTIFICATION_BADGE
      && defined $event->{aggregate_id};

    return ('moderation:queue')
      if $event->{type} eq 'moderation.queue.invalidate';

    return;
}

1;
