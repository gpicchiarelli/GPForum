package GPForum::Test::RealtimePermissionEngine;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has denied => sub { return {}; };

sub can {
    my ( $self, @arguments ) = @_;

    my $resource = $arguments[2];

    return !$self->denied->{ $resource->{id} };
}

1;

