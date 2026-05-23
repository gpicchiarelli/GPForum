package GPForum::Service::Admin::PermissionGate;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has schema => undef;

sub allowed {
    my ( $self, $actor, $permission ) = @_;

    my $user_id = _user_id($actor);
    return 0 if !defined $user_id || !length $user_id;

    my $search = $self->schema->resultset('RoleBinding')->search(
        {
            'me.user_id'               => $user_id,
            'me.revoked_at'            => undef,
            'permission.resource_type' => $permission->{resource_type},
            'permission.action'        => $permission->{action},
        },
        {
            join => { role => { role_permissions => 'permission' } },
            rows => 1,
        }
    );

    return $search->single ? 1 : 0;
}

sub _user_id {
    my ($actor) = @_;

    return                   if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

1;
