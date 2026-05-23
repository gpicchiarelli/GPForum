package GPForum::Test::ProjectionOffsetRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data => sub { return {}; };

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

1;
