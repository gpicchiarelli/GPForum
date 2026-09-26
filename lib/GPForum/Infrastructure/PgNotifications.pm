# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::PgNotifications;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

# Per channel. A consumer that stops taking (a cache nobody reads) would
# otherwise grow its queue for as long as the process lives.
const my $DEFAULT_MAX_QUEUED => 1_000;

has max_queued => $DEFAULT_MAX_QUEUED;
has schema     => undef;

# The backend the last take saw. A LISTEN lives on one backend: when this
# changes, every channel has to be listened for again.
has backend_pid => undef;
has channels    => sub { return {}; };
has stats       => sub {
    return {
        dropped         => 0,
        gaps            => 0,
        listen_failures => 0,
        overflowed      => 0,
        received        => 0,
        relistens       => 0,
        unavailable     => 0,
    };
};

sub listen_to ( $self, $channel ) {
    $self->channels->{$channel} ||= { gap => 0, pid => undef, queue => [] };

    my $dbh = $self->_dbh;
    if ( !$dbh ) {
        return 0;
    }
    $self->_sync($dbh);

    return $self->listening($channel);
}

sub unlisten ( $self, $channel ) {
    my $entry = delete $self->channels->{$channel};
    if ( !$entry || !defined $entry->{pid} ) {
        return 1;
    }

    # A LISTEN dies with its backend, so on another one there is nothing
    # left to undo.
    my $dbh = $self->_dbh;
    if (   !$dbh
        || !$dbh->{AutoCommit}
        || _pid_of($dbh) ne $entry->{pid} )
    {
        return 1;
    }

    return eval {
        $dbh->do( 'UNLISTEN ' . $dbh->quote_identifier($channel) );
        return 1;
    } ? 1 : 0;
}

sub registered ( $self, $channel ) {
    return exists $self->channels->{$channel} ? 1 : 0;
}

sub listening ( $self, $channel ) {
    my $entry = $self->channels->{$channel};
    if ( !$entry || !defined $entry->{pid} ) {
        return 0;
    }

    return $entry->{pid} eq ( $self->backend_pid // q{} ) ? 1 : 0;
}

# What arrived for one channel since its last take. Every take reads the
# whole libpq buffer and files each notification under its own channel, so
# one consumer draining the handle no longer swallows another's messages.
sub take ( $self, $channel ) {
    my $entry = $self->channels->{$channel};
    if ( !$entry ) {
        return { available => 0, gap => 0, notifications => [] };
    }

    my $dbh = $self->_dbh;
    if ($dbh) {
        $self->_sync($dbh);
        $self->_pump($dbh);
    }
    else {
        $self->stats->{unavailable} += 1;
    }

    my @notifications = splice @{ $entry->{queue} };
    my $gap           = $entry->{gap};
    $entry->{gap} = 0;

    return {
        available     => $dbh ? 1 : 0,
        gap           => $gap,
        notifications => \@notifications,
    };
}

sub snapshot ($self) {
    my %channels;
    for my $channel ( keys %{ $self->channels } ) {
        $channels{$channel} = {
            listening => $self->listening($channel),
            queued    => scalar @{ $self->channels->{$channel}{queue} },
        };
    }

    return {
        %{ $self->stats },
        backend_pid => $self->backend_pid,
        channels    => \%channels,
    };
}

# Outside a transaction only: PostgreSQL delivers nothing inside one, and a
# LISTEN issued inside one is undone by its rollback.
sub _sync ( $self, $dbh ) {
    if ( !$dbh->{AutoCommit} ) {
        return;
    }

    my $pid = _pid_of($dbh);
    $self->backend_pid($pid);
    for my $channel ( sort keys %{ $self->channels } ) {
        my $entry = $self->channels->{$channel};
        next if defined $entry->{pid} && $entry->{pid} eq $pid;

        $self->_listen_on( $dbh, $channel );
    }

    return;
}

sub _listen_on ( $self, $dbh, $channel ) {
    my $entry = $self->channels->{$channel};

    # The channel was listened for on another backend. That LISTEN went with
    # the old connection, and so did everything NOTIFYed until this one:
    # the consumer is told it missed an unknown number of messages.
    if ( defined $entry->{pid} ) {
        $entry->{gap} = 1;
        $self->stats->{gaps} += 1;
    }

    my $listened = eval {
        $dbh->do( 'LISTEN ' . $dbh->quote_identifier($channel) );
        return 1;
    };
    if ( !$listened ) {
        $self->stats->{listen_failures} += 1;
        return;
    }

    if ( defined $entry->{pid} ) {
        $self->stats->{relistens} += 1;
    }
    $entry->{pid} = $self->backend_pid;

    return;
}

# pg_notifies sends nothing to the server: it reads what the server has
# already pushed onto the socket. At most max_queued are read per take; the
# rest wait in libpq's buffer for the next one.
sub _pump ( $self, $dbh ) {
    if ( !$dbh->{AutoCommit} || !$dbh->can('pg_notifies') ) {
        return;
    }

    for ( 1 .. $self->max_queued ) {
        my $notification = eval { return $dbh->pg_notifies };
        last if !$notification;

        $self->_route($notification);
    }

    return;
}

sub _route ( $self, $notification ) {
    my $channel = ref $notification eq 'ARRAY' ? $notification->[0] : undef;
    my $entry   = defined $channel ? $self->channels->{$channel}    : undef;
    if ( !$entry ) {
        $self->stats->{dropped} += 1;
        return;
    }

    $self->stats->{received} += 1;
    my $queue = $entry->{queue};
    push @{$queue}, $notification;

    # The oldest goes, and the consumer learns that something did.
    if ( @{$queue} > $self->max_queued ) {
        shift @{$queue};
        $entry->{gap} = 1;
        $self->stats->{overflowed} += 1;
    }

    return;
}

# One storage->dbh per call. DBIx::Class pings the handle there and
# reconnects when the ping fails, which is how a lost backend is noticed.
sub _dbh ($self) {
    my $schema = $self->schema;
    if ( !$schema || !$schema->can('storage') ) {
        return;
    }

    my $storage = eval { return $schema->storage };
    if ( !$storage || !$storage->can('dbh') ) {
        return;
    }

    return eval { return $storage->dbh };
}

sub _pid_of ($dbh) {
    return $dbh->{pg_pid} // q{};
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::PgNotifications - One PostgreSQL notification
queue per database handle, routed by channel.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $notifications =
      GPForum::Infrastructure::PgNotifications->new( schema => $schema );

    $notifications->listen_to('gpforum_cache_invalidation');

    my $taken = $notifications->take('gpforum_cache_invalidation');
    clear_everything() if $taken->{gap};
    handle($_) for @{ $taken->{notifications} };

=head1 DESCRIPTION

A PostgreSQL connection has one notification buffer, whatever it LISTENs
to. Each web process shares one handle between the cache invalidation bus
and the realtime listener, and each used to read that buffer whole: the
listener took cache purges and dropped them as malformed, so a worker kept
serving a hidden post from its L1, and the bus took realtime events and
counted them as empty invalidations.

This module owns the buffer. Consumers register their channel with
C<listen_to> and read only their own channel with C<take>; a notification on a
channel nobody registered is counted and dropped.

It also owns the LISTENs. A LISTEN lives on one backend, and DBIx::Class
replaces the handle after a reconnect, so the backend PID identifies the
connection: when it changes, every registered channel is listened for again
and each is marked with a gap. A gap tells the consumer that notifications
were lost -- raised while nobody was listening, or pushed out of a full
queue -- so it can fall back to something that does not need them.

It adds no connection: it reads the handle the application already holds.

=head1 SUBROUTINES/METHODS

=head2 listen_to

Registers a channel and issues its LISTEN. Returns true when the LISTEN is
in effect on the current backend. A channel that could not be listened for
stays registered, and every C<take> tries again.

=head2 unlisten

Forgets a channel, dropping its queue, and issues UNLISTEN when its LISTEN
is still on the current backend.

=head2 registered

True when the channel has been registered with C<listen_to>.

=head2 listening

True when the channel's LISTEN is in effect on the backend the last call
saw.

=head2 take

Reads the handle's buffer and returns C<{ available, gap, notifications }>
for one channel: the notifications that arrived since its last take, as
DBD::Pg returns them (C<[ channel, sender_pid, payload ]>), and whether any
were lost. C<available> is false when the handle could not be obtained.
Notifications are read only outside a transaction.

=head2 snapshot

Counters, the backend PID and each channel's LISTEN state and queue length,
for the metrics surface.

=head1 DIAGNOSTICS

Never throws. A missing schema, an unreachable handle and a failed LISTEN
are counted in C<stats>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the schema's database handle. C<max_queued> bounds each channel's
queue (1000).

=head1 DEPENDENCIES

L<Mojo::Base>, L<Const::Fast>.

=head1 INCOMPATIBILITIES

Requires DBD::Pg for C<pg_notifies> and C<pg_pid>. A handle without them
yields nothing.

=head1 BUGS AND LIMITATIONS

The handle is obtained through C<storage-E<gt>dbh>, which pings the server,
so each take costs one round trip. That ping is also what notices a lost
backend.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
