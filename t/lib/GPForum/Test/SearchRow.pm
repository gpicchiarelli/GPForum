# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has category     => undef;
has current_body => undef;
has data         => sub { return {}; };
has thread       => undef;

sub get_column {
    my ( $self, $name ) = @_;

    return $self->data->{$name};
}

sub has_column {
    my ( $self, $name ) = @_;

    return exists $self->data->{$name};
}

sub update {
    my ( $self, $changes ) = @_;

    $self->data( { %{ $self->data }, %{$changes} } );

    return $self;
}

1;
