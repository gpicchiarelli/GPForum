# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeSupervisorListener;

use v5.40;

our $VERSION = '0.001';

sub new {
    my ( $class, %input ) = @_;

    return bless {
        fail_poll  => $input{fail_poll}  ? 1 : 0,
        fail_start => $input{fail_start} ? 1 : 0,
        polls      => 0,
        reconnects => 0,
        starts     => 0,
        stops      => 0,
    }, $class;
}

sub fail_poll {
    my ( $self, $value ) = @_;

    if ( @_ > 1 ) {
        $self->{fail_poll} = $value ? 1 : 0;
    }

    return $self->{fail_poll};
}

sub polls {
    my ($self) = @_;

    return $self->{polls};
}

sub reconnects {
    my ($self) = @_;

    return $self->{reconnects};
}

sub starts {
    my ($self) = @_;

    return $self->{starts};
}

sub stops {
    my ($self) = @_;

    return $self->{stops};
}

sub start {
    my ($self) = @_;

    $self->{starts} += 1;
    return { ok => 0, reason => 'listen_failed' } if $self->{fail_start};

    return { ok => 1 };
}

sub stop {
    my ($self) = @_;

    $self->{stops} += 1;

    return { ok => 1 };
}

sub poll_once {
    my ($self) = @_;

    $self->{polls} += 1;
    return { ok => 0, reason => 'poll_failed' } if $self->{fail_poll};

    return { ok => 1, delivered => 0 };
}

sub reconnect {
    my ($self) = @_;

    $self->{reconnects} += 1;
    return { ok => 1 };
}

sub snapshot {
    return { status => 'test' };
}

1;
