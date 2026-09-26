# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::ConnectionRegistry;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock       => sub { return GPForum::Service::Clock->new; };
has connections => sub { return {}; };

# Per process, not per user across the cluster: a memory bound on what one
# user can hold open in one worker, so a user may have this many sockets on
# every worker of every node. The cross-node control is the PostgreSQL-backed
# realtime.connect rate limit. Counting cluster-wide would need a shared
# presence table, which ADR 0067 rules out.
has max_connections_per_user         => 8;
has max_subscriptions_per_connection => 32;

sub register ( $self, $connection_id, $actor, $connection ) {
    my $undefined;
    return $undefined if !$self->can_register($actor);

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

    return { ok => 1, row => $row };
}

sub connection ( $self, $connection_id ) {
    return $self->connections->{$connection_id};
}

sub subscribers ( $self, $channel ) {
    return
      grep { $_->{subscriptions}{$channel} } values %{ $self->connections };
}

# Connections with at least one channel of a family, such as notifications.
sub subscribers_of_family ( $self, $family ) {
    my $prefix = $family . q{:};

    return grep {
        grep { index( $_, $prefix ) == 0 }
          keys %{ $_->{subscriptions} }
    } values %{ $self->connections };
}

sub count ($self) {
    return scalar keys %{ $self->connections };
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

sub _user_id ($actor) {
    my $undefined;
    return $undefined        if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

1;
