# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ForumReadRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data => sub { return {}; };

sub get_column {
    my ( $self, $name ) = @_;

    return $self->data->{$name};
}

sub get_columns {
    my ($self) = @_;

    return %{ $self->data };
}

1;

