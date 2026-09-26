# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::IdempotencyStore;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has done   => sub { return {}; };
has events => sub { return []; };

# Keys another worker is holding. begin() refuses these, which is how a test
# reaches the branch where the runner declines to duplicate a side effect.
has claimed => sub { return {}; };

sub is_done {
    my ( $self, $key ) = @_;

    return $self->done->{$key} ? 1 : 0;
}

sub begin {
    my ( $self, $key ) = @_;

    push @{ $self->events }, [ begin => $key ];
    return 0 if $self->claimed->{$key};

    $self->claimed->{$key} = 1;

    return 1;
}

sub mark_done {
    my ( $self, $key, $result ) = @_;

    $self->done->{$key} = 1;
    push @{ $self->events }, [ done => $key, $result ];

    return;
}

sub mark_failed {
    my ( $self, $key, $error ) = @_;

    delete $self->claimed->{$key};
    push @{ $self->events }, [ failed => $key, $error ];

    return 1;
}

1;
