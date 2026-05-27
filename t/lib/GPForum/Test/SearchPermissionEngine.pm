package GPForum::Test::SearchPermissionEngine;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has denied_entities => sub { return {}; };
has visibility      => sub { return ['public']; };

sub search_visibility_for {
    my ( $self, $actor, $options ) = @_;

    return @{ $self->visibility };
}

sub can {
    my ( $self, @arguments ) = @_;

    my $resource = $arguments[2];
    return !$self->denied_entities->{ $resource->{entity_id} };
}

1;
