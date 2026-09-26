# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::ConnectionRegistry;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock                    => sub { return GPForum::Service::Clock->new; };
has connections              => sub { return {}; };
has max_connections_per_user => 8;
has max_subscriptions_per_connection => 32;
has idle_timeout_seconds             => 300;

sub register ( $self, $connection_id, $actor, $connection ) {
    my $undefined;
    return $undefined if !$self->can_register($actor);

    my $epoch = $self->clock->now_epoch;
    my $row   = {
        connection_id   => $connection_id,
        actor           => $actor,
        connection      => $connection,
        connected_at    => $self->clock->now_iso8601,
        last_seen_at    => $self->clock->now_iso8601,
        last_seen_epoch => $epoch,
        subscriptions   => {},
    };
    $self->connections->{$connection_id} = $row;

    return $row;
}

sub unregister ( $self, $connection_id ) {
    return delete $self->connections->{$connection_id};
}

sub subscribe ( $self, $connection_id, $channel ) {
    my $row = $self->connection($connection_id);
    return { ok => 0, reason => 'connection_not_found' } if !$row;

    if (
        scalar keys %{ $row->{subscriptions} } >=
        $self->max_subscriptions_per_connection
        && !$row->{subscriptions}{$channel} )
    {
        return { ok => 0, reason => 'subscription_quota_exceeded' };
    }

    $row->{subscriptions}{$channel} = 1;
    $self->touch($connection_id);

    return { ok => 1, row => $row };
}

sub touch ( $self, $connection_id ) {
    my $row = $self->connection($connection_id);
    my $undefined;
    return $undefined if !$row;

    $row->{last_seen_at}    = $self->clock->now_iso8601;
    $row->{last_seen_epoch} = $self->clock->now_epoch;

    return $row;
}

sub connection ( $self, $connection_id ) {
    return $self->connections->{$connection_id};
}

sub subscribers ( $self, $channel ) {
    return
      grep { $_->{subscriptions}{$channel} } values %{ $self->connections };
}

sub snapshot ($self) {
    my @connections        = values %{ $self->connections };
    my $subscription_count = 0;

    for my $connection (@connections) {
        $subscription_count += scalar keys %{ $connection->{subscriptions} };
    }

    return {
        connections                      => scalar @connections,
        subscriptions                    => $subscription_count,
        max_connections_per_user         => $self->max_connections_per_user,
        max_subscriptions_per_connection =>
          $self->max_subscriptions_per_connection,
    };
}

sub can_register ( $self, $actor ) {
    my $user_id = _user_id($actor);
    return 1 if !defined $user_id;

    my $count = 0;
    for my $connection ( values %{ $self->connections } ) {
        $count++ if ( _user_id( $connection->{actor} ) || q{} ) eq $user_id;
    }

    return $count < $self->max_connections_per_user ? 1 : 0;
}

sub cleanup_stale ($self) {
    my $now     = $self->clock->now_epoch;
    my $removed = 0;

    for my $connection_id ( keys %{ $self->connections } ) {
        my $row = $self->connections->{$connection_id};
        next
          if $now - ( $row->{last_seen_epoch} || $now ) <=
          $self->idle_timeout_seconds;

        delete $self->connections->{$connection_id};
        $removed++;
    }

    return $removed;
}

sub _user_id ($actor) {
    my $undefined;
    return $undefined        if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

1;
