# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxFailure;

use strict;
use warnings;

use Carp qw(croak);
use overload q{""} => 'message', fallback => 1;

our $VERSION = '0.001';

sub new {
    my ( $class, $message, $failure_type ) = @_;

    return bless {
        failure_type => $failure_type,
        message      => $message,
    }, $class;
}

sub throw {
    my ( $class, $message, $failure_type ) = @_;

    croak $class->new( $message, $failure_type );
}

sub message {
    my ($self) = @_;

    return $self->{message};
}

sub failure_type {
    my ($self) = @_;

    return $self->{failure_type};
}

1;
