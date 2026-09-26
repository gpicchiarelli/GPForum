# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeBusDbh;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $CHANNEL_ARGUMENT => 2;
const my $PAYLOAD_ARGUMENT => 3;
const my $DEFAULT_PID      => 4_242;

has notifies   => sub { return []; };
has statements => sub { return []; };

# The channels this backend has LISTENed to. PostgreSQL delivers a NOTIFY
# only to the backends listening on its channel, the sender included.
has listening => sub { return {}; };

# Every handle on one network is a backend of the same PostgreSQL. A handle
# built alone is its own network.
has network => sub {
    my ($self) = @_;

    return [$self];
};

# What a DBD::Pg handle carries outside a transaction. Plain hash keys, as
# on a real handle, so code that reads $dbh->{AutoCommit} sees them.
sub new {
    my ( $class, @arguments ) = @_;

    return $class->SUPER::new(
        AutoCommit => 1,
        pg_pid     => $DEFAULT_PID,
        @arguments,
    );
}

# Another backend of the same server as $peer.
sub join_network {
    my ( $self, $peer ) = @_;

    my $network = $peer->network;
    push @{$network}, $self;
    $self->network($network);

    return $self;
}

sub quote_identifier {
    my ( undef, $identifier ) = @_;

    return q{"} . $identifier . q{"};
}

sub _dbi_do {
    my ( $self, @arguments ) = @_;

    push @{ $self->statements }, \@arguments;
    $self->_capture_listen(@arguments);
    $self->_capture_notify(@arguments);

    return 1;
}

sub pg_notifies {
    my ($self) = @_;

    return shift @{ $self->notifies };
}

sub _capture_listen {
    my ( $self, $statement ) = @_;

    if ( $statement =~ /\A LISTEN \s+ "? ([^"]+) "? \z/msx ) {
        $self->listening->{$1} = 1;
    }
    elsif ( $statement =~ /\A UNLISTEN \s+ "? ([^"]+) "? \z/msx ) {
        delete $self->listening->{$1};
    }

    return;
}

sub _capture_notify {
    my ( $self, @arguments ) = @_;

    return if $arguments[0] !~ /pg_notify/msx;

    my $channel = $arguments[$CHANNEL_ARGUMENT];
    for my $backend ( @{ $self->network } ) {
        next if !$backend->listening->{$channel};

        push @{ $backend->notifies },
          [ $channel, $self->{pg_pid}, $arguments[$PAYLOAD_ARGUMENT] ];
    }

    return;
}

*GPForum::Test::RealtimeBusDbh::do = \&_dbi_do;

1;
