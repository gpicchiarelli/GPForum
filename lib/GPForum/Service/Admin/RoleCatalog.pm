package GPForum::Service::Admin::RoleCatalog;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Admin::Event;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $ROW_LIMIT_ONE                => 1;
const my $ROLE_ID_CONSTRAINT           => 'roles_pkey';
const my $ROLE_NAME_CONSTRAINT         => 'roles_name_key';
const my $PERMISSION_ID_CONSTRAINT     => 'permissions_pkey';
const my $PERMISSION_NAME_CONSTRAINT   => 'permissions_name_key';
const my $PERMISSION_ACTION_CONSTRAINT => 'permissions_resource_action_key';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;
has events => sub { return GPForum::Service::Admin::Event->new; };

sub create_role {
    my ( $self, $input ) = @_;

    my $existing = $self->_single_row( 'Role', { name => $input->{name} } );
    if ($existing) {
        return $self->_finish_leftover_role( $existing, $input );
    }

    return $self->_insert_or_reuse_role($input);
}

sub _insert_or_reuse_role {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_role_row($input); };
    if ($created) {
        return $created;
    }

    return $self->_role_after_conflict( $input, $EVAL_ERROR );
}

sub _role_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_role_after_unique( $input, $error );
}

sub _role_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _role_id_conflict($error) ) {
        return $self->_role_after_id_conflict($input);
    }
    if ( _role_name_conflict($error) ) {
        return $self->_reuse_role_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _role_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_single_row( 'Role', { name => $input->{name} } );
    if ($existing) {
        return $self->_finish_leftover_role( $existing, $input );
    }

    return $self->_retry_role_id($input);
}

sub _retry_role_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_role_row($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_role_row {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_single_row( 'Role', { name => $input->{name} } );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_role( $existing, $input );
}

sub _role_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ROLE_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _role_name_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ROLE_NAME_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_role_row {
    my ( $self, $input ) = @_;

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
    if ($existing) {
        return $self->_finish_leftover_permission( $existing, $input );
    }

    return $self->_insert_or_reuse_permission($input);
}

sub _insert_or_reuse_permission {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_permission_row($input); };
    if ($created) {
        return $created;
    }

    return $self->_permission_after_conflict( $input, $EVAL_ERROR );
}

sub _permission_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_permission_after_unique( $input, $error );
}

sub _permission_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _permission_id_conflict($error) ) {
        return $self->_permission_after_id_conflict($input);
    }
    if ( _permission_allocated_conflict($error) ) {
        return $self->_reuse_permission_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _permission_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_permission_by_action($input);
    if ($existing) {
        return $self->_finish_leftover_permission( $existing, $input );
    }

    return $self->_retry_permission_id($input);
}

sub _retry_permission_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_permission_row($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_permission_row {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_permission_by_action($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_permission( $existing, $input );
}

sub _permission_by_action {
    my ( $self, $input ) = @_;

    return $self->_single_row(
        'Permission',
        {
            action        => $input->{action},
            resource_type => $input->{resource_type},
        }
    );
}

sub _permission_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $PERMISSION_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _permission_allocated_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }
    if ( index( $error, $PERMISSION_NAME_CONSTRAINT ) >= 0 ) {
        return 1;
    }

    return index( $error, $PERMISSION_ACTION_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_permission_row {
    my ( $self, $input ) = @_;

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
    if ($existing) {
        return $self->_finish_leftover_attachment( $existing, $input );
    }

    return $self->_insert_or_reuse_attachment($input);
}

sub _insert_or_reuse_attachment {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_attach_permission_row($input); };
    if ($created) {
        return $created;
    }

    return $self->_attachment_after_conflict( $input, $EVAL_ERROR );
}

sub _attachment_after_conflict {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_existing_after_conflict(
        'RolePermission',
        {
            role_id       => $input->{role_id},
            permission_id => $input->{permission_id},
        },
        $error
    );

    return $self->_finish_leftover_attachment( $existing, $input );
}

sub _attach_permission_row {
    my ( $self, $input ) = @_;

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

sub _finish_leftover_role {
    my ( $self, $existing, $input ) = @_;

    $self->_ensure_catalog_audit(
        {
            action        => 'role.created',
            actor_user_id => $input->{actor_user_id},
            created_at    => _column( $existing, 'created_at' ),
            metadata      => {
                description => _column( $existing, 'description' ),
                name        => _column( $existing, 'name' ),
            },
            target_id   => _column( $existing, 'role_id' ),
            target_type => 'role',
        }
    );

    return _idempotent_hash( $existing, _role_columns() );
}

sub _finish_leftover_permission {
    my ( $self, $existing, $input ) = @_;

    $self->_ensure_catalog_audit(
        {
            action        => 'permission.created',
            actor_user_id => $input->{actor_user_id},
            created_at    => _column( $existing, 'created_at' ),
            metadata      => {
                action        => _column( $existing, 'action' ),
                name          => _column( $existing, 'name' ),
                resource_type => _column( $existing, 'resource_type' ),
            },
            target_id   => _column( $existing, 'permission_id' ),
            target_type => 'permission',
        }
    );

    return _idempotent_hash( $existing, _permission_columns() );
}

sub _finish_leftover_attachment {
    my ( $self, $existing, $input ) = @_;

    $self->_ensure_catalog_audit(
        {
            action        => 'role_permission.attached',
            actor_user_id => $input->{actor_user_id},
            created_at    => _column( $existing, 'created_at' ),
            metadata      => {
                permission_id => _column( $existing, 'permission_id' ),
                role_id       => _column( $existing, 'role_id' ),
            },
            target_id   => _column( $existing, 'role_id' ),
            target_type => 'role',
        }
    );

    return _idempotent_hash( $existing, _role_permission_columns() );
}

sub _ensure_catalog_audit {
    my ( $self, $job ) = @_;

    if ( $self->_catalog_audit_exists($job) ) {
        return;
    }

    return $self->_record_admin_audit(
        {
            action        => $job->{action},
            actor_user_id => $job->{actor_user_id},
            created_at    => $job->{created_at} || $self->clock->now_iso8601,
            metadata      => $job->{metadata},
            target_id     => $job->{target_id},
            target_type   => $job->{target_type},
        }
    );
}

sub _catalog_audit_exists {
    my ( $self, $job ) = @_;

    return $self->_single_row(
        'AuditLog',
        {
            action    => $job->{action},
            target_id => $job->{target_id},
        }
    );
}

sub _single_row {
    my ( $self, $resultset_name, $query ) = @_;

    my $search = $self->schema->resultset($resultset_name)
      ->search( $query, { rows => $ROW_LIMIT_ONE } );

    return $search->single if $search->can('single');

    my @rows = _rows($search);

    return $rows[0];
}

sub _existing_after_conflict {
    my ( $self, $resultset_name, $query, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_single_row( $resultset_name, $query );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $existing;
}

sub _idempotent_hash {
    my ( $row, @columns ) = @_;

    return { %{ _row_hash( $row, @columns ) }, idempotent => 1 };
}

sub _record_admin_audit {
    my ( $self, $input ) = @_;

    $self->recorder->record_audit( %{ $self->events->catalog_audit($input) } );

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
