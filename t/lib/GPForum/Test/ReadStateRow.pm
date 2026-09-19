package GPForum::Test::ReadStateRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data => sub { return {}; };

sub get_column {
    my ( $self, $name ) = @_;

    return $self->data->{$name};
}

sub update {
    my ( $self, $values ) = @_;

    $self->data( { %{ $self->data }, %{$values} } );

    return $self;
}

1;
