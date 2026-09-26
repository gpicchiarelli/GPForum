# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::Bootstrapper;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $DEFAULT_ROLE_NAME        => 'gpforum_owner';
const my $DEFAULT_ROLE_DESCRIPTION => 'Full GPForum administrative governance';
const my $GLOBAL_RESOURCE_TYPE     => 'global';
const my $ROW_LIMIT_ONE            => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has schema     => undef;

sub bootstrap ( $self, $input ) {
    $input ||= {};
    croak 'admin bootstrap requires user_id' if !_has_text( $input->{user_id} );

    return $self->schema->txn_do(
        sub {
            return $self->_bootstrap_in_transaction($input);
        }
    );
}

sub default_permissions ($self) {
    return [
        _permission( 'admin_console',     'view' ),
        _permission( 'category',          'read' ),
        _permission( 'admin_console',     'manage' ),
        _permission( 'report',            'view_queue' ),
        _permission( 'report',            'assign' ),
        _permission( 'report',            'resolve' ),
        _permission( 'post',              'moderate' ),
        _permission( 'thread',            'moderate' ),
        _permission( 'moderation_action', 'view' ),
        _permission( 'moderation_action', 'reverse' ),
        _permission( 'suspension',        'view' ),
        _permission( 'user',              'suspend' ),
        _permission( 'privacy_rights',    'view' ),
        _permission( 'privacy_rights',    'manage' ),
    ];
}

sub _bootstrap_in_transaction ( $self, $input ) {
    my $role_result       = $self->_ensure_role($input);
    my $permission_result = $self->_ensure_role_permissions(
        {
            actor_user_id => $input->{actor_user_id} || $input->{user_id},
            role_id       => $role_result->{role}{role_id},
            permissions   => $self->default_permissions,
        }
    );
    my $binding_result = $self->_ensure_global_binding(
        {
            user_id       => $input->{user_id},
            role_id       => $role_result->{role}{role_id},
            actor_user_id => $input->{actor_user_id} || $input->{user_id},
        }
    );

    return {
        role        => $role_result->{role},
        permissions => $permission_result->{permissions},
        binding     => $binding_result->{binding},
        counts      => {
            roles_created       => _bool_to_count( $role_result->{created} ),
            permissions_created => $permission_result->{permissions_created},
            role_permissions_attached =>
              $permission_result->{role_permissions_attached},
            bindings_created => _bool_to_count( $binding_result->{created} ),
        },
    };
}

sub _ensure_role ( $self, $input ) {
    my $role_name = $input->{role_name} || $DEFAULT_ROLE_NAME;
    my $existing  = $self->_single_row( 'Role', { name => $role_name } );

    return {
        role    => _row_hash( $existing, _role_columns() ),
        created => 0,
      }
      if $existing;

    my $role = $self->_role_catalog->create_role(
        {
            actor_user_id => $input->{actor_user_id} || $input->{user_id},
            name          => $role_name,
            description   => $input->{role_description}
              || $DEFAULT_ROLE_DESCRIPTION,
        }
    );

    return {
        role    => $role,
        created => 1,
    };
}

sub _ensure_role_permissions ( $self, $input ) {
    my @permissions;
    my $created_permissions       = 0;
    my $attached_role_permissions = 0;

    for my $permission_definition ( @{ $input->{permissions} } ) {
        my $permission = $self->_ensure_permission(
            {
                %{$permission_definition},
                actor_user_id => $input->{actor_user_id},
            }
        );
        my $attached = $self->_ensure_role_permission(
            {
                actor_user_id => $input->{actor_user_id},
                role_id       => $input->{role_id},
                permission_id => $permission->{permission}{permission_id},
            }
        );
        $created_permissions       += _bool_to_count( $permission->{created} );
        $attached_role_permissions += _bool_to_count( $attached->{created} );
        push @permissions,
          {
            permission => $permission->{permission},
            attached   => $attached->{created},
            created    => $permission->{created},
          };
    }

    return {
        permissions               => \@permissions,
        permissions_created       => $created_permissions,
        role_permissions_attached => $attached_role_permissions,
    };
}

sub _ensure_permission ( $self, $definition ) {
    my $existing = $self->_single_row(
        'Permission',
        {
            resource_type => $definition->{resource_type},
            action        => $definition->{action},
        }
    );

    return {
        permission => _row_hash( $existing, _permission_columns() ),
        created    => 0,
      }
      if $existing;

    my $permission = $self->_role_catalog->create_permission($definition);

    return {
        permission => $permission,
        created    => 1,
    };
}

sub _ensure_role_permission ( $self, $input ) {
    my $existing = $self->_single_row(
        'RolePermission',
        {
            role_id       => $input->{role_id},
            permission_id => $input->{permission_id},
        }
    );

    return { created => 0 } if $existing;

    $self->_role_catalog->attach_permission($input);

    return { created => 1 };
}

sub _ensure_global_binding ( $self, $input ) {
    my $existing = $self->_single_row(
        'RoleBinding',
        {
            user_id       => $input->{user_id},
            role_id       => $input->{role_id},
            resource_type => $GLOBAL_RESOURCE_TYPE,
            resource_id   => undef,
            space_id      => undef,
            revoked_at    => undef,
        }
    );

    return {
        binding => _row_hash( $existing, _binding_columns() ),
        created => 0,
      }
      if $existing;

    my $bound = $self->_role_binding_store->bind_role(
        {
            actor_user_id => $input->{actor_user_id},
            user_id       => $input->{user_id},
            role_id       => $input->{role_id},
            resource_type => $GLOBAL_RESOURCE_TYPE,
            resource_id   => undef,
            space_id      => undef,
        }
    );

    return {
        binding => $bound->{binding},
        created => 1,
    };
}

sub _single_row ( $self, $resultset_name, $query ) {
    my $search = $self->schema->resultset($resultset_name)
      ->search_rs( $query, { rows => $ROW_LIMIT_ONE } );

    return $search->single if $search->can('single');

    if ( $search->can('all') ) {
        my @rows = $search->all;
        return $rows[0];
    }

    return $search->rows->[0] if $search->can('rows');

    my $undefined;
    return $undefined;
}

sub _role_catalog ($self) {
    return GPForum::Service::Admin::RoleCatalog->new(
        schema     => $self->schema,
        clock      => $self->clock,
        id_service => $self->id_service,
    );
}

sub _role_binding_store ($self) {
    return GPForum::Service::Admin::RoleBindingStore->new(
        schema     => $self->schema,
        clock      => $self->clock,
        id_service => $self->id_service,
    );
}

sub _permission ( $resource_type, $action ) {
    return {
        name          => $resource_type . q{.} . $action,
        resource_type => $resource_type,
        action        => $action,
    };
}

sub _row_hash ( $row, @columns ) {
    my $undefined;
    return $undefined if !$row;

    my %hash = map { $_ => _row_value( $row, $_ ) } @columns;

    return \%hash;
}

sub _row_value ( $row, $column ) {
    return $row->{$column} if ref $row eq 'HASH';

    return $row->get_column($column);
}

sub _role_columns {
    return qw(role_id name description created_at);
}

sub _permission_columns {
    return qw(permission_id name resource_type action created_at);
}

sub _binding_columns {
    return
      qw(binding_id user_id role_id resource_type resource_id space_id created_by_user_id created_at revoked_at);
}

sub _bool_to_count ($value) {
    return $value ? 1 : 0;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;
