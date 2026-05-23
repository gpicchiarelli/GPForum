package GPForum::Test::AdminWebServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub list_roles {
    return [
        {
            role_id     => 'role-1',
            name        => 'admin',
            description => 'Administrative governance',
            created_at  => '2026-05-23T12:00:00Z',
        },
    ];
}

sub list_permissions {
    return [
        {
            permission_id => 'permission-1',
            name          => 'admin_console.view',
            resource_type => 'admin_console',
            action        => 'view',
            created_at    => '2026-05-23T12:00:00Z',
        },
    ];
}

sub create_role {
    my ( $self, $input ) = @_;

    return {
        role_id     => 'role-created',
        name        => $input->{name},
        description => $input->{description},
        created_at  => '2026-05-23T12:00:00Z',
    };
}

sub create_permission {
    my ( $self, $input ) = @_;

    return {
        permission_id => 'permission-created',
        name          => $input->{name},
        resource_type => $input->{resource_type},
        action        => $input->{action},
        created_at    => '2026-05-23T12:00:00Z',
    };
}

sub attach_permission {
    my ( $self, $input ) = @_;

    return {
        role_id       => $input->{role_id},
        permission_id => $input->{permission_id},
        created_at    => '2026-05-23T12:00:00Z',
    };
}

sub roles_for_user {
    my ( $self, $user_id ) = @_;

    return [
        {
            binding_id         => 'binding-1',
            user_id            => $user_id,
            role_id            => 'role-1',
            resource_type      => 'global',
            resource_id        => undef,
            space_id           => undef,
            created_by_user_id => 'admin-1',
            created_at         => '2026-05-23T12:00:00Z',
            revoked_at         => undef,
        },
    ];
}

sub bind_role {
    my ( $self, $input ) = @_;

    return {
        ok      => 1,
        binding => {
            binding_id         => 'binding-created',
            user_id            => $input->{user_id},
            role_id            => $input->{role_id},
            resource_type      => $input->{resource_type},
            resource_id        => $input->{resource_id},
            space_id           => $input->{space_id},
            created_by_user_id => $input->{actor_user_id},
            created_at         => '2026-05-23T12:00:00Z',
            revoked_at         => undef,
        },
    };
}

sub revoke_binding {
    my ( $self, $binding_id, $actor_user_id ) = @_;

    return if $binding_id ne 'binding-1';

    return {
        binding_id         => $binding_id,
        created_by_user_id => $actor_user_id,
        revoked_at         => '2026-05-23T12:00:00Z',
    };
}

sub recent {
    return [
        {
            audit_id       => 'audit-1',
            action         => 'role_binding.created',
            actor_id       => 'admin-1',
            target_type    => 'role_binding',
            target_id      => 'binding-1',
            correlation_id => 'correlation-1',
            metadata       => {},
            created_at     => '2026-05-23T12:00:00Z',
        },
    ];
}

sub for_target {
    return recent();
}

1;
