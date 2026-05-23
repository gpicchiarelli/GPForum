package GPForum::Service::Admin::RoleCatalog;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub create_role {
    my ( $self, $input ) = @_;

    my $role = {
        role_id     => $self->id_service->uuid,
        name        => $input->{name},
        description => $input->{description} || q{},
        created_at  => $self->clock->now_iso8601,
    };
    $self->schema->resultset('Role')->create($role);

    return $role;
}

sub create_permission {
    my ( $self, $input ) = @_;

    my $permission = {
        permission_id => $self->id_service->uuid,
        name          => $input->{name},
        resource_type => $input->{resource_type},
        action        => $input->{action},
        created_at    => $self->clock->now_iso8601,
    };
    $self->schema->resultset('Permission')->create($permission);

    return $permission;
}

sub attach_permission {
    my ( $self, $input ) = @_;

    my $role_permission = {
        role_id       => $input->{role_id},
        permission_id => $input->{permission_id},
        created_at    => $self->clock->now_iso8601,
    };
    $self->schema->resultset('RolePermission')->create($role_permission);

    return $role_permission;
}

sub list_roles {
    my ( $self, $options ) = @_;

    my $search = $self->schema->resultset('Role')->search(
        {},
        {
            order_by => [ { -asc => 'name' } ],
            rows     => $options->{limit},
        }
    );

    return [ _rows($search) ];
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
