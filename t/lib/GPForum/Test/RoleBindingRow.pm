# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RoleBindingRow;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# A stored role binding or audit row: columns read by name, updated in place.
has columns => sub { return {}; };

sub get_column {
    my ( $self, $name ) = @_;

    return $self->columns->{$name};
}

sub update {
    my ( $self, $changes ) = @_;

    @{ $self->columns }{ keys %{$changes} } = values %{$changes};

    return $self;
}

1;
