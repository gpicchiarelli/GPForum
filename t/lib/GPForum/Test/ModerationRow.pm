# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ModerationRow;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;
use Mojo::Loader qw(load_class);

our $VERSION = '0.001';

has data         => sub { return {}; };
has result_class => undef;
has updates      => sub { return []; };

sub get_column {
    my ( $self, $column ) = @_;

    $self->assert_columns($column);

    return $self->data->{$column};
}

sub update {
    my ( $self, $changes ) = @_;

    $self->assert_columns( keys %{$changes} );
    push @{ $self->updates }, $changes;
    $self->data( { %{ $self->data }, %{$changes} } );

    return $self;
}

# With a result class, a column it does not have dies with DBIx::Class's own
# words; without one, any column goes, as before.
sub assert_columns {
    my ( $self, @columns ) = @_;

    my $class = $self->result_class;
    return if !$class;

    my $error = load_class($class);
    croak "cannot load $class: $error" if $error;
    for my $column (@columns) {
        croak "No such column '$column' on $class"
          if !$class->has_column($column);
    }

    return;
}

1;
