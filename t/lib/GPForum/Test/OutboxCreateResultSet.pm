package GPForum::Test::OutboxCreateResultSet;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has created => sub { return []; };

sub create {
    my ( $self, $row ) = @_;

    push @{ $self->created }, $row;

    return $row;
}

1;
