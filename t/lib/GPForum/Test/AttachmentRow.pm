# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::AttachmentRow;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has data => sub { return {}; };

sub get_column {
    my ( $self, $name ) = @_;

    return $self->data->{$name};
}

sub update {
    my ( $self, $changes ) = @_;

    $self->data( { %{ $self->data }, %{$changes} } );

    return $self;
}

1;

