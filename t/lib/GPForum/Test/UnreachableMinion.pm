package GPForum::Test::UnreachableMinion;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub backend {
    my ($self) = @_;

    return $self;
}

sub pg {
    my ($self) = @_;

    return $self;
}

sub db {
    my ($self) = @_;

    return $self;
}

sub ping {
    return 0;
}

1;
