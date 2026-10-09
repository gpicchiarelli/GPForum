# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WindowLifecycle;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# A partition lifecycle whose ensure_partitions returns the result it was
# given, or dies with failure, and records what it was asked.
has calls   => sub { return []; };
has failure => undef;                # optional: returns the result without one
has result  => sub {
    return {
        conflicts        => [],
        created          => [],
        errors           => [],
        existing         => [],
        lookahead_months => 3,
        ok               => 1,
        planned          => [],
        skipped          => 0,
    };
};

sub ensure_partitions {
    my ( $self, $input ) = @_;

    push @{ $self->calls }, $input;
    croak $self->failure if defined $self->failure;

    return $self->result;
}

1;
