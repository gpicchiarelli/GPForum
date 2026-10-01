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

__END__

=head1 NAME

GPForum::Service::Realtime::ConnectionRegistry - The realtime connections one worker holds, and their channels.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $registry = GPForum::Service::Realtime::ConnectionRegistry->new;
    my $row = $registry->register( $connection_id, $actor, $websocket )
      or return;    # over the per-user cap
    my $subscribed = $registry->subscribe( $connection_id, 'thread:42' );
    for my $subscriber ( $registry->subscribers('thread:42') ) {
        $subscriber->{connection}->send($frame);
    }
    $registry->unregister($connection_id);

=head1 DESCRIPTION

An in-memory table of the realtime connections open in this process, kept by
L<GPForum::Service::Realtime::Hub>: for each connection id, the actor, the
connection object, when it connected, and the set of channels it subscribed
to. It answers who is subscribed to a channel, or to any channel of a family
such as C<notifications>, so the hub can fan an event out.

It also bounds memory: at most C<max_connections_per_user> (8) connections
per user and C<max_subscriptions_per_connection> (32) channels per
connection. These are per process, not per user across the cluster: a user
may hold that many sockets on every worker of every node. The cross-node
control is the PostgreSQL-backed C<realtime.connect> rate limit; counting
cluster-wide would need a shared presence table, which ADR 0067 rules out.

The registry does not authorize anything; the hub asks the channel
authorizer before it subscribes a connection.

=head1 SUBROUTINES/METHODS

=head2 register

Takes a connection id, the actor (a hash reference with C<user_id>, a bare
user id, or C<undef>) and the connection object. Returns the stored row
(C<connection_id>, C<actor>, C<connection>, C<connected_at>,
C<subscriptions>), or C<undef> when L</can_register> refuses. A row already
held under the same id is replaced.

=head2 unregister

Removes a connection and returns its row, or C<undef> when there was none.

=head2 subscribe

Takes a connection id and a channel name. Returns
C<< { ok => 1, row => $row } >>,
C<< { ok => 0, reason => 'connection_not_found' } >>, or
C<< { ok => 0, reason => 'subscription_quota_exceeded' } >> when the
connection already holds the maximum and the channel is new to it.
Subscribing again to a held channel succeeds without counting twice.

=head2 connection

Returns the row for a connection id, or C<undef>.

=head2 subscribers

Returns the list of rows subscribed to exactly the channel given.

=head2 subscribers_of_family

Returns the list of rows holding at least one channel that starts with the
family name followed by a colon.

=head2 count

Returns the number of registered connections.

=head2 snapshot

Returns C<connections>, C<subscriptions> (the total over all connections)
and the two limits. The hub merges it into its own snapshot, which the
metrics read.

=head2 can_register

Takes an actor and returns 1 when it may open another connection here: an
actor with no user id always may, and a user may while holding fewer than
C<max_connections_per_user> registered connections. Returns 0 otherwise.

=head1 DIAGNOSTICS

None. Refusals are return values.

=head1 CONFIGURATION AND ENVIRONMENT

None. The limits are constructor attributes.

=head1 DEPENDENCIES

L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Connections without a user id are not capped here. There is no way to drop a
single subscription short of unregistering the connection.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
