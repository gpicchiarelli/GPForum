package GPForum::Test::ForumReadSchema;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has resultsets => sub { return {}; };

sub resultset {
    my ( $self, $name ) = @_;

    return $self->resultsets->{$name};
}

1;

