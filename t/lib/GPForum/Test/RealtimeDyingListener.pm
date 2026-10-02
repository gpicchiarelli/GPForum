# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeDyingListener;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# A listener for the supervisor that dies, as DBI does, instead of answering
# ok => 0: on start, on poll, on reconnect or on snapshot, each as asked.
# start_error replaces the message start dies with.
has die_poll      => 0;
has die_reconnect => 0;
has die_snapshot  => 0;
has die_start     => 0;
has reconnects    => 0;
has start_error   => undef;

sub start {
    my ($self) = @_;

    if ( $self->die_start ) {
        die $self->start_error
          // "could not connect to server: Connection refused\n"
          . "\tIs the server running on that host?\n";
    }

    return { ok => 1 };
}

sub stop {
    return { ok => 1 };
}

sub poll_once {
    my ($self) = @_;

    if ( $self->die_poll ) {
        die "server closed the connection unexpectedly at Pg.pm line 7.\n";
    }

    return { ok => 1 };
}

sub reconnect {
    my ($self) = @_;

    $self->reconnects( $self->reconnects + 1 );
    if ( $self->die_reconnect ) {
        die "FATAL:  the database system is shutting down\n";
    }

    return { ok => 1 };
}

sub snapshot {
    my ($self) = @_;

    if ( $self->die_snapshot ) {
        die "notification queue is gone\n";
    }

    return { status => 'listening' };
}

1;
