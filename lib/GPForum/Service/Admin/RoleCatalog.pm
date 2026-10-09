# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::RoleCatalog;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;
use Scalar::Util qw(blessed);

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Admin::Event;
use GPForum::Service::Clock;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $ROW_LIMIT_ONE                => 1;
const my $ROLE_ID_CONSTRAINT           => 'roles_pkey';
const my $ROLE_NAME_CONSTRAINT         => 'roles_name_key';
const my $PERMISSION_ID_CONSTRAINT     => 'permissions_pkey';
const my $PERMISSION_NAME_CONSTRAINT   => 'permissions_name_key';
const my $PERMISSION_ACTION_CONSTRAINT => 'permissions_resource_action_key';
const my $ROLE_PERMISSION_CONSTRAINT   => 'role_permissions_pkey';
const my $ATTACHED_ACTION              => 'role_permission.attached';
const my $UUID_DIGITS                  => 32;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
__PACKAGE__->requires(qw(schema));
has events => sub { return GPForum::Service::Admin::Event->new; };

# Each create reuses the row already stored -- committed by an earlier
# attempt, or by a concurrent request that won the unique key -- completing
# its audit entry if that attempt left none. A minted id already stored with
# no such row is minted once more.
sub create_role ( $self, $input ) {
    my $find =
      sub { return $self->_single_row( 'Role', { name => $input->{name} } ); };
    my $existing = $find->();
    if ($existing) {
        return $self->_finish_leftover_role( $existing, $input );
    }

    my $create = sub { return $self->_create_role_row($input); };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    my $id_taken = $conflict && $conflict->on($ROLE_ID_CONSTRAINT);
    if ( $id_taken || ( $conflict && $conflict->on($ROLE_NAME_CONSTRAINT) ) ) {
        $existing = $find->();
        if ($existing) {
            return $self->_finish_leftover_role( $existing, $input );
        }
        if ($id_taken) {
            return $self->_once_more($create);
        }
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

# The second attempt after a minted id collided: any failure is final.
sub _once_more ( $self, $create ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _create_role_row ( $self, $input ) {
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

# A permission is one per resource type and action, whatever its name: a
# conflict on either key is answered by the permission stored for the pair.
sub create_permission ( $self, $input ) {
    my $find = sub {
        return $self->_single_row(
            'Permission',
            {
                action        => $input->{action},
                resource_type => $input->{resource_type},
            }
        );
    };
    my $existing = $find->();
    if ($existing) {
        return $self->_finish_leftover_permission( $existing, $input );
    }

    my $create = sub { return $self->_create_permission_row($input); };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    my $conflict   = GPForum::X::Conflict->caught($error);
    my $id_taken   = $conflict && $conflict->on($PERMISSION_ID_CONSTRAINT);
    my $pair_taken = $conflict
      && ( $conflict->on($PERMISSION_NAME_CONSTRAINT)
        || $conflict->on($PERMISSION_ACTION_CONSTRAINT) );
    if ( $id_taken || $pair_taken ) {
        $existing = $find->();
        if ($existing) {
            return $self->_finish_leftover_permission( $existing, $input );
        }
        if ($id_taken) {
            return $self->_once_more($create);
        }
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _create_permission_row ( $self, $input ) {
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

sub attach_permission ( $self, $input ) {
    my $find = sub {
        return $self->_single_row(
            'RolePermission',
            {
                role_id       => $input->{role_id},
                permission_id => $input->{permission_id},
            }
        );
    };
    my $existing = $find->();
    if ($existing) {
        return $self->_finish_leftover_attachment( $existing, $input );
    }

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_attach_permission_row($input); } );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( $conflict && $conflict->on($ROLE_PERMISSION_CONSTRAINT) ) {
        $existing = $find->();
        if ($existing) {
            return $self->_finish_leftover_attachment( $existing, $input );
        }
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _attach_permission_row ( $self, $input ) {
    my $role_permission = {
        role_id       => $input->{role_id},
        permission_id => $input->{permission_id},
        created_at    => $self->clock->now_iso8601,
    };
    $self->schema->resultset('RolePermission')->create($role_permission);
    $self->_record_admin_audit(
        {
            action        => $ATTACHED_ACTION,
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

sub list_roles ( $self, $options ) {
    $options ||= {};

    my $search = $self->schema->resultset('Role')->search_rs(
        {},
        {
            order_by => [ { -asc => 'name' } ],
            rows     => $options->{limit},
        }
    );

    return [ _rows($search) ];
}

sub list_permissions ( $self, $options ) {
    $options ||= {};

    my $search = $self->schema->resultset('Permission')->search_rs(
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

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _finish_leftover_role ( $self, $existing, $input ) {
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

sub _finish_leftover_permission ( $self, $existing, $input ) {
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

sub _finish_leftover_attachment ( $self, $existing, $input ) {
    $self->_ensure_catalog_audit(
        {
            action        => $ATTACHED_ACTION,
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

# An attachment's entry targets the role, as the entry of every other
# permission attached to that role does; only its metadata names the
# permission. Matched on the role alone, an attachment whose entry was lost
# passed for audited as soon as any other permission of the role had been.
# So the role's attachment entries are read -- one per permission attached
# to it, and only on this leftover path -- and the pair is matched here.
sub _ensure_catalog_audit ( $self, $job ) {
    my $query = { action => $job->{action}, target_id => $job->{target_id} };
    my $recorded =
        $job->{action} eq $ATTACHED_ACTION
      ? $self->_attachment_audit_exists($job)
      : $self->_single_row( q{AuditLog}, $query );
    if ($recorded) {
        return undef;
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

sub _attachment_audit_exists ( $self, $job ) {
    my $search = $self->schema->resultset('AuditLog')->search_rs(
        {
            action      => $job->{action},
            target_id   => $job->{target_id},
            target_type => $job->{target_type},
        },
        { columns => [qw(metadata)] },
    );

    my $wanted = $job->{metadata};
    for my $audit ( _rows($search) ) {
        my $metadata = _audit_metadata($audit);
        if (   _same_id( $metadata->{role_id}, $wanted->{role_id} )
            && _same_id( $metadata->{permission_id}, $wanted->{permission_id} )
          )
        {
            return 1;
        }
    }

    return 0;
}

# Ids are UUIDs, and the metadata keeps one as the command spelled it.
# PostgreSQL also reads a uuid in upper case, in braces or with its hyphens
# moved or left out, and hands back the canonical form; lower-casing alone
# missed the other spellings and wrote a second entry on every repeat.
sub _same_id ( $recorded, $wanted ) {
    return 0 if !defined $recorded || !defined $wanted;

    return _id_key($recorded) eq _id_key($wanted) ? 1 : 0;
}

# The bare lower-case digits of a uuid. Anything else -- the test doubles'
# ids -- is compared lower-cased as it is.
sub _id_key ($id) {
    my $digits = ( lc $id ) =~ tr/{}-//dr;

    return
      length $digits == $UUID_DIGITS && $digits !~ m/[^[:xdigit:]]/msx
      ? $digits
      : lc $id;
}

# get_column answers a jsonb column with its JSON text; the decoded hash is
# the inflated column. The in-memory doubles keep the hash itself.
sub _audit_metadata ($audit) {
    my $metadata =
      blessed($audit)
      && $audit->can('get_inflated_column')
      ? $audit->get_inflated_column('metadata')
      : _column( $audit, 'metadata' );

    return ref $metadata eq 'HASH' ? $metadata : {};
}

sub _single_row ( $self, $resultset_name, $query ) {
    my $search = $self->schema->resultset($resultset_name)
      ->search_rs( $query, { rows => $ROW_LIMIT_ONE } );

    return $search->single if $search->can('single');

    my @rows = _rows($search);

    return $rows[0];
}

sub _idempotent_hash ( $row, @columns ) {
    return { %{ _row_hash( $row, @columns ) }, idempotent => 1 };
}

sub _record_admin_audit ( $self, $input ) {
    $self->recorder->record_audit( %{ $self->events->catalog_audit($input) } );

    return;
}

sub _row_hash ( $row, @columns ) {
    return {} if !$row;

    return { map { $_ => _column( $row, $_ ) } @columns };
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
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

__END__

=head1 NAME

GPForum::Service::Admin::RoleCatalog - Creates roles and permissions and attaches one to the other.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $catalog = GPForum::Service::Admin::RoleCatalog->new( schema => $schema );
    my $role = $catalog->create_role(
        {
            actor_user_id => $admin_id,
            name          => 'moderator',
            description   => 'Moderates the public categories',
        }
    );
    my $permission = $catalog->create_permission(
        {
            actor_user_id => $admin_id,
            name          => 'thread.hide',
            resource_type => 'thread',
            action        => 'hide',
        }
    );
    $catalog->attach_permission(
        {
            actor_user_id => $admin_id,
            role_id       => $role->{role_id},
            permission_id => $permission->{permission_id},
        }
    );
    my $roles = $catalog->list_roles( { limit => 50 } );

=head1 DESCRIPTION

The persistence behind the console's role catalog: C<roles>,
C<permissions> and C<role_permissions>, each write with its audit entry
(C<role.created>, C<permission.created>, C<role_permission.attached>).
L<GPForum::Service::Admin::Workflow> calls it for the console's commands.
It opens no transaction around a row and its audit entry: that is the
caller's.

Every write is idempotent. A role is found by name, a permission by
resource type and action, an attachment by role and permission; when the
row is already there it is returned as it is, marked C<idempotent>, and
the audit entry is written only if none exists yet, so a command that
stopped between its row and its audit is completed rather than repeated.

A new row is inserted inside a savepoint
(L<GPForum::Infrastructure::UniqueConflict/attempt>). When the insert
loses a race on the natural key, the row the other request inserted is
returned instead. When it collides on the generated id, the natural key is
looked up again and, if there is still no row, the insert is retried once
with a fresh id.

=head1 SUBROUTINES/METHODS

=head2 create_role

Takes a hash reference with C<name>, an optional C<description> (empty
when omitted) and the C<actor_user_id> to audit. Returns a hash reference
with C<role_id>, C<name>, C<description> and C<created_at>; for a role
that already had that name, the existing row's values with
C<< idempotent => 1 >>.

=head2 create_permission

Takes a hash reference with C<name>, C<resource_type>, C<action> and the
C<actor_user_id> to audit. Returns a hash reference with
C<permission_id>, C<name>, C<resource_type>, C<action> and C<created_at>;
for a resource type and action that already had a permission, the
existing row's values with C<< idempotent => 1 >>.

=head2 attach_permission

Takes a hash reference with C<role_id>, C<permission_id> and the
C<actor_user_id> to audit. Returns a hash reference with C<role_id>,
C<permission_id> and C<created_at>; for a pair already attached, the
existing row's values with C<< idempotent => 1 >>.

An attachment's audit entry targets the role and names the permission in
its metadata, so the check for a missing entry reads the role's
C<role_permission.attached> entries and matches the role and permission
pair; an entry for another permission of the same role does not count.
The metadata keeps each id as the command spelled it, so ids are compared
as PostgreSQL reads a uuid: whatever the case, braces or hyphens.

=head2 list_roles

Takes a hash reference (or undef) with an optional C<limit>; without one
every role is returned. Returns an array reference of C<Role> rows ordered
by name.

=head2 list_permissions

Takes a hash reference (or undef) with an optional C<limit>; without one
every permission is returned. Returns an array reference of C<Permission>
rows ordered by resource type, action and name.

=head1 DIAGNOSTICS

A database error, and any unique violation that cannot be resolved to an
existing row, is rethrown with L<Carp/croak>: a second id collision, or a
permission name already used for a different resource type and action.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<GPForum::Base>, L<Scalar::Util>,
L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::Id>, L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict>,
L<GPForum::Service::Admin::Event>, L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Repeating C<create_role> with a different description returns the
existing role unchanged; nothing is updated.

The check for a lost attachment entry reads every
C<role_permission.attached> entry of the role, one per permission attached
to it, because only the metadata names the permission. It runs only when
the pair is already attached, never on a first attachment.

Completing a lost entry is not serialised. The existing role, permission or
attachment is read without a row lock and its entry looked for before
anything is written, so two commands that find the same row without its
entry at the same moment can both write one.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
