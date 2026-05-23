package GPForum::Service::Realtime::ConnectionRegistry;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock       => sub { return GPForum::Service::Clock->new; };
has connections => sub { return {}; };

sub register {
    my ( $self, $connection_id, $actor, $connection ) = @_;

    my $row = {
        connection_id => $connection_id,
        actor         => $actor,
        connection    => $connection,
        connected_at  => $self->clock->now_iso8601,
        subscriptions => {},
    };
    $self->connections->{$connection_id} = $row;

    return $row;
}

sub unregister {
    my ( $self, $connection_id ) = @_;

    return delete $self->connections->{$connection_id};
}

sub subscribe {
    my ( $self, $connection_id, $channel ) = @_;

    my $row = $self->connection($connection_id);
    return if !$row;

    $row->{subscriptions}{$channel} = 1;

    return $row;
}

sub connection {
    my ( $self, $connection_id ) = @_;

    return $self->connections->{$connection_id};
}

sub subscribers {
    my ( $self, $channel ) = @_;

    return
      grep { $_->{subscriptions}{$channel} } values %{ $self->connections };
}

sub snapshot {
    my ($self) = @_;

    my @connections        = values %{ $self->connections };
    my $subscription_count = 0;

    for my $connection (@connections) {
        $subscription_count += scalar keys %{ $connection->{subscriptions} };
    }

    return {
        connections   => scalar @connections,
        subscriptions => $subscription_count,
    };
}

1;

