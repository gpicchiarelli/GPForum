package GPForum::Service::Realtime::Hub;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;

our $VERSION = '0.001';

const my $FALLBACK_POLL_SECONDS => 30;

has authorizer =>
  sub { return GPForum::Service::Realtime::ChannelAuthorizer->new; };
has registry =>
  sub { return GPForum::Service::Realtime::ConnectionRegistry->new; };

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

    $self->registry->subscribe( $request->{connection_id},
        $request->{channel} );

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

    for my $subscriber (@subscribers) {
        my $sent = _send_json( $subscriber->{connection}, $payload );
        if ($sent) {
            $delivered++;
        }
        else {
            $failed++;
        }
    }

    return {
        ok        => 1,
        channel   => $channel,
        delivered => $delivered,
        failed    => $failed,
    };
}

sub broadcast_thread_update {
    my ( $self, $thread_id, $payload ) = @_;

    return $self->broadcast(
        _channel( 'thread', $thread_id ),
        {
            type      => 'thread.update',
            thread_id => $thread_id,
            payload   => $payload || {},
        }
    );
}

sub broadcast_notification_badge {
    my ( $self, $user_id, $count ) = @_;

    return $self->broadcast(
        _channel( 'notifications', $user_id ),
        {
            type         => 'notification.badge',
            user_id      => $user_id,
            unread_count => $count,
        }
    );
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

    return $self->registry->snapshot;
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

1;
