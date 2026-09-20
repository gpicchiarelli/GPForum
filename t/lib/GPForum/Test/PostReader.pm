package GPForum::Test::PostReader;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has post => undef;

sub find_post {
    my ($self) = @_;

    return $self->post;
}

1;
