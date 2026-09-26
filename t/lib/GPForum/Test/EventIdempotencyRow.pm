# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::EventIdempotencyRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# Stands in for a DBIx::Class row so the store can call update and delete on
# what find() hands back, instead of receiving a bare hash it cannot mutate.

has key  => undef;
has rows => sub { return {}; };

sub completed_at {
    my ($self) = @_;

    return $self->rows->{ $self->key }->{completed_at};
}

sub created_at {
    my ($self) = @_;

    return $self->rows->{ $self->key }->{created_at};
}

sub event_id {
    my ($self) = @_;

    return $self->rows->{ $self->key }->{event_id};
}

sub update {
    my ( $self, $changes ) = @_;

    my $row = $self->rows->{ $self->key };
    @{$row}{ keys %{$changes} } = values %{$changes};

    return 1;
}

## no critic (Subroutines::ProhibitBuiltinHomonyms)
# Named for the DBIx::Class row method this stands in for. Renaming it would
# make the double diverge from the interface under test, which is worse than
# shadowing a builtin inside a test class.
sub delete {
    my ($self) = @_;

    delete $self->rows->{ $self->key };

    return 1;
}
## use critic

1;
