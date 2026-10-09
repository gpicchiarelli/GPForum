# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeSupervisorIOLoop;

use v5.40;

our $VERSION = '0.001';

sub new {
    my ($class) = @_;

    return bless {
        finish_callbacks => [],
        recurring_calls  => [],
        removed          => [],
        sequence         => 0,
        timer_calls      => [],
    }, $class;
}

sub recurring_calls {
    my ($self) = @_;

    return $self->{recurring_calls};
}

sub removed {
    my ($self) = @_;

    return $self->{removed};
}

sub timer_calls {
    my ($self) = @_;

    return $self->{timer_calls};
}

sub finish_callbacks {
    my ($self) = @_;

    return $self->{finish_callbacks};
}

sub on {
    my ( $self, $event, $callback ) = @_;

    if ( $event eq 'finish' ) {
        push @{ $self->{finish_callbacks} }, $callback;
    }

    return $self;
}

sub recurring {
    my ( $self, $interval, $callback ) = @_;

    $self->{sequence} += 1;
    my $id = 'recurring-' . $self->{sequence};
    push @{ $self->{recurring_calls} },
      { id => $id, interval => $interval, callback => $callback };

    return $id;
}

sub timer {
    my ( $self, $interval, $callback ) = @_;

    $self->{sequence} += 1;
    my $id = 'timer-' . $self->{sequence};
    push @{ $self->{timer_calls} },
      { id => $id, interval => $interval, callback => $callback };

    return $id;
}

sub remove {
    my ( $self, $id ) = @_;

    push @{ $self->{removed} }, $id;

    return 1;
}

1;
