package GPForum::Test::ForumReadSearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has rows => sub { return []; };

sub single {
    my ($self) = @_;

    return $self->rows->[0];
}

1;
