package GPForum::Service::Admin::RoleCatalog;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;
const my $ROW_LIMIT_ONE  => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub create_role {
    my ( $self, $input ) = @_;

    my $existing = $self->_single_row( 'Role', { name => $input->{name} } );
    return { %{ _row_hash( $existing, _role_columns() ) }, idempotent => 1 }
      if $existing;

    my $role = {
        role_id     => $self->id_service->uuid,
        name        => $input->{name},
        description => $input->{description} || q{},
        created_at  => $self->clock->now_iso8601,
    };
    $self->schema->resultset('Role')->create($role);
    $self->_record_admin_audit(
        {
            action        => 'role.created',
            actor_user_id => $input->{actor_user_id},
            target_type   => 'role',
            target_id     => $role->{role_id},
            metadata      => {
                description => $role->{description},
                name        => $role->{name},
            },
            created_at => $role->{created_at},
        }
    );

    return $role;
}

sub create_permission {
    my ( $self, $input ) = @_;

    my $existing = $self->_single_row(
        'Permission',
        {
            resource_type => $input->{resource_type},
            action        => $input->{action},
        }
    );
    return { %{ _row_hash( $existing, _permission_columns() ) },
        idempotent => 1, }
      if $existing;

    my $permission = {
        permission_id => $self->id_service->uuid,
        name          => $input->{name},
        resource_type => $input->{resource_type},
        action        => $input->{action},
        created_at    => $self->clock->now_iso8601,
    };
    $self->schema->resultset('Permission')->create($permission);
    $self->_record_admin_audit(
        {
            action        => 'permission.created',
            actor_user_id => $input->{actor_user_id},
            target_type   => 'permission',
            target_id     => $permission->{permission_id},
            metadata      => {
                action        => $permission->{action},
                name          => $permission->{name},
                resource_type => $permission->{resource_type},
            },
            created_at => $permission->{created_at},
        }
    );

    return $permission;
}

sub attach_permission {
    my ( $self, $input ) = @_;

    my $existing = $self->_single_row(
        'RolePermission',
        {
            role_id       => $input->{role_id},
            permission_id => $input->{permission_id},
        }
    );
    return {
        %{ _row_hash( $existing, _role_permission_columns() ) },
        idempotent => 1,
      }
      if $existing;

    my $role_permission = {
        role_id       => $input->{role_id},
        permission_id => $input->{permission_id},
        created_at    => $self->clock->now_iso8601,
    };
    $self->schema->resultset('RolePermission')->create($role_permission);
    $self->_record_admin_audit(
        {
            action        => 'role_permission.attached',
            actor_user_id => $input->{actor_user_id},
            target_type   => 'role',
            target_id     => $role_permission->{role_id},
            metadata      => {
                permission_id => $role_permission->{permission_id},
                role_id       => $role_permission->{role_id},
            },
            created_at => $role_permission->{created_at},
        }
    );

    return $role_permission;
}

sub list_roles {
    my ( $self, $options ) = @_;

    $options ||= {};

    my $search = $self->schema->resultset('Role')->search(
        {},
        {
            order_by => [ { -asc => 'name' } ],
            rows     => $options->{limit},
        }
    );

    return [ _rows($search) ];
}

sub list_permissions {
    my ( $self, $options ) = @_;

    $options ||= {};

    my $search = $self->schema->resultset('Permission')->search(
        {},
        {
            order_by => [
                { -asc => 'resource_type' },
                { -asc => 'action' },
                { -asc => 'name' },
            ],
            rows => $options->{limit},
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

sub _single_row {
    my ( $self, $resultset_name, $query ) = @_;

    my $search = $self->schema->resultset($resultset_name)
      ->search( $query, { rows => $ROW_LIMIT_ONE } );

    return $search->single if $search->can('single');

    my @rows = _rows($search);

    return $rows[0];
}

sub _record_admin_audit {
    my ( $self, $input ) = @_;

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => $input->{action},
            schema_version => $SCHEMA_VERSION,
            actor_id       => $input->{actor_user_id},
            target_type    => $input->{target_type},
            target_id      => $input->{target_id},
            correlation_id => $self->id_service->uuid,
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => $input->{metadata} || {},
            created_at     => $input->{created_at},
        }
    );

    return;
}

sub _row_hash {
    my ( $row, @columns ) = @_;

    return {} if !$row;

    return { map { $_ => _column( $row, $_ ) } @columns };
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _role_columns {
    return qw(role_id name description created_at);
}

sub _permission_columns {
    return qw(permission_id name resource_type action created_at);
}

sub _role_permission_columns {
    return qw(role_id permission_id created_at);
}

1;
