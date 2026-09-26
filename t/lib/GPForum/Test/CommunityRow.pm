# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CommunityRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data    => sub { return {}; };
has updates => sub { return []; };

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

sub update {
    my ( $self, $changes ) = @_;

    push @{ $self->updates }, $changes;
    $self->data( { %{ $self->data }, %{$changes} } );

    return $self;
}

1;
