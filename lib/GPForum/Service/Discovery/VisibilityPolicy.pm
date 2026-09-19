package GPForum::Service::Discovery::VisibilityPolicy;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub is_public {
    my ( $self, $resource ) = @_;

    return
         _has_public_visibility($resource)
      && _has_visible_moderation($resource)
      && _is_not_removed($resource);
}

sub _has_public_visibility {
    my ($resource) = @_;

    return ( $resource->{visibility} || q{} ) eq 'public';
}

sub _has_visible_moderation {
    my ($resource) = @_;

    return ( $resource->{moderation_state} || 'visible' ) eq 'visible';
}

sub _is_not_removed {
    my ($resource) = @_;

    return !defined $resource->{deleted_at} && !defined $resource->{hidden_at};
}

1;
