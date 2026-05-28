package GPForum::Query::ReadModel;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data => sub { return {}; };

sub as_hash {
    my ($self) = @_;

    return { %{ $self->data } };
}

sub value {
    my ( $self, $name ) = @_;

    return $self->data->{$name};
}

1;
