package GPForum::Test::Minion;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has tasks => sub { return {}; };

sub add_task {
    my ( $self, $name, $code ) = @_;

    $self->tasks->{$name} = $code;

    return $self;
}

1;
