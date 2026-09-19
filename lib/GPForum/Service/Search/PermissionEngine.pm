package GPForum::Service::Search::PermissionEngine;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has schema => undef;

sub search_visibility_for {
    my ( $self, $actor, $options ) = @_;

    return ('public') if !_user_id($actor);

    return qw(public members private);
}

sub can {
    my ( $self, $actor, $action, $resource, $options ) = @_;

    return 0 if $action ne 'search.view';

    my $visibility = $resource->{visibility} || 'private';
    return 1 if $visibility eq 'public';

    my $user_id = _user_id($actor);
    return 0 if !$user_id;
    return 1 if $visibility eq 'members';
    return 1 if _owns_resource( $user_id, $resource );

    return $self->_has_acl( $user_id, $resource );
}

sub _has_acl {
    my ( $self, $user_id, $resource ) = @_;

    return 0 if !$self->schema;

    my $search = eval {
        return $self->schema->resultset('ResourceAcl')->search(
            {
                user_id          => $user_id,
                resource_type    => $resource->{entity_type},
                resource_id      => $resource->{entity_id},
                revoked_at       => undef,
                moderation_state => { -in => [ 'visible', 'locked' ] },
            },
            { rows => 1 }
        );
    };

    return 0 if !$search;

    return $search->single ? 1 : 0;
}

sub _owns_resource {
    my ( $user_id, $resource ) = @_;

    return defined $resource->{author_user_id}
      && $resource->{author_user_id} eq $user_id ? 1 : 0;
}

sub _user_id {
    my ($actor) = @_;

    return                   if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

1;
