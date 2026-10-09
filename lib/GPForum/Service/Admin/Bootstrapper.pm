# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::Bootstrapper;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Registration;
use GPForum::Service::Identity::Store;
use GPForum::Infrastructure::Id;
use GPForum::X::Argument;

our $VERSION = '0.001';

const my $DEFAULT_ROLE_NAME        => 'gpforum_owner';
const my $DEFAULT_ROLE_DESCRIPTION => 'Full GPForum administrative governance';
const my $GLOBAL_RESOURCE_TYPE     => 'global';
const my $ROW_LIMIT_ONE            => 1;
const my $CREATED_ACTION           => 'admin.bootstrap_created';
const my $USER_TARGET              => 'user';
const my $ACTIVE                   => 'active';

# The columns of a member that a caller is told about.
const my @MEMBER_COLUMNS =>
  qw(id username email_normalized status email_verified_at);

# The columns of a row found already there that the result reports.
const my @ROLE_COLUMNS => qw(role_id name description created_at);
const my @PERMISSION_COLUMNS =>
  qw(permission_id name resource_type action created_at);
const my @BINDING_COLUMNS => qw(binding_id user_id role_id resource_type
  resource_id space_id created_by_user_id created_at revoked_at);

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };

# Where create_owner writes the account and its audit: the identity store
# a sign-up writes through, on this schema.
has identity_store => sub ($self) {
    return GPForum::Service::Identity::Store->new(
        clock      => $self->clock,
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
__PACKAGE__->requires(qw(schema));

sub bootstrap ( $self, $input ) {
    $input ||= {};
    if ( !defined $input->{user_id} || !length $input->{user_id} ) {
        GPForum::X::Argument->throw(
            message => 'admin bootstrap requires user_id' );
    }
    my $actor_user_id = $input->{actor_user_id} || $input->{user_id};

    return $self->schema->txn_do(
        sub {
            my $role_result = $self->_ensure_role( $input, $actor_user_id );
            my $role_id     = $role_result->{role}{role_id};
            my $permission_result =
              $self->_ensure_role_permissions( $role_id, $actor_user_id );
            my $binding_result =
              $self->_ensure_global_binding( $input->{user_id}, $role_id,
                $actor_user_id );

            return {
                role        => $role_result->{role},
                permissions => $permission_result->{permissions},
                binding     => $binding_result->{binding},
                counts      => {
                    roles_created => _bool_to_count( $role_result->{created} ),
                    permissions_created =>
                      $permission_result->{permissions_created},
                    role_permissions_attached =>
                      $permission_result->{role_permissions_attached},
                    bindings_created =>
                      _bool_to_count( $binding_result->{created} ),
                },
            };
        }
    );
}

# The forum's first account, made from the host's shell: active and verified
# at once, since the operator vouches for it with their access to the host
# and its database (owner decision D6), and bound to the owner role. A new
# install used to need a registration, a mail server for the verification
# link and a psql query for the new account's id before anyone could sign
# in. One transaction: an account is never left without its role. Audited
# as admin.bootstrap_created, beside the role binding's own audit.
sub create_owner ( $self, $input ) {
    my $prepared = $self->_prepared($input);
    return $prepared if !$prepared->{ok};

    my $user = $prepared->{registration}{user};
    return $self->schema->txn_do(
        sub {
            my $created = $self->identity_store->create_registration(
                $prepared->{registration} );
            return { errors => $created->{errors}, ok => 0 } if !$created->{ok};

            my $granted = $self->bootstrap(
                { role_name => $input->{role_name}, user_id => $user->{id} } );
            $self->identity_store->audit->record_action(
                {
                    action   => $CREATED_ACTION,
                    actor_id => $user->{id},
                    metadata => {
                        role     => $granted->{role}{name},
                        username => $user->{username},
                    },
                    target_id   => $user->{id},
                    target_type => $USER_TARGET,
                }
            );
            return { %{$granted}, ok => 1, user => _member_hash($user) };
        }
    );
}

# What create_owner would refuse, without writing: the account's fields as
# a sign-up checks them, and a username or address already taken. The
# password is checked only when it is given.
sub check_owner ( $self, $input ) {
    my $prepared = $self->_prepared($input);
    my %errors   = %{ $prepared->{errors} // {} };
    if ( !defined $input->{password} ) {
        delete $errors{password};
    }
    return { errors => \%errors, ok => 0 } if keys %errors;

    my $user =
        $prepared->{registration}
      ? $prepared->{registration}{user}
      : $prepared->{values};
    %errors = %{ $self->_taken($user) };
    return { errors => \%errors, ok => 0 } if keys %errors;

    return { ok => 1, user => _member_hash($user) };
}

# A member by email address or username, as the operator typed it, or undef.
sub find_member ( $self, $identifier ) {
    my $typed  = lc( $identifier // q{} ) =~ s/\A \s+ | \s+ \z//grmsx;
    my $column = index( $typed, q{@} ) >= 0 ? 'email_normalized' : 'username';
    return undef if !length $typed;

    my $row = $self->_single_row( 'User', { $column => $typed } );
    return $row ? _row_hash( $row, @MEMBER_COLUMNS ) : undef;
}

# Whether anyone holds the owner role, globally and unrevoked: what a fresh
# install lacks until its first owner is made.
sub has_owner ( $self, $role_name = $DEFAULT_ROLE_NAME ) {
    my $role = _row_hash( $self->_single_row( 'Role', { name => $role_name } ),
        'role_id' );
    return 0 if !$role;

    return $self->_single_row(
        'RoleBinding',
        {
            resource_type => $GLOBAL_RESOURCE_TYPE,
            revoked_at    => undef,
            role_id       => $role->{role_id},
        }
    ) ? 1 : 0;
}

# Whether this member holds the owner role (or the role named), globally and
# unrevoked: what `gpforum admin create`, run again for the owner it made,
# answers with instead of refusing an address already taken.
sub is_owner ( $self, $member, $role_name = $DEFAULT_ROLE_NAME ) {
    my $role = _row_hash( $self->_single_row( 'Role', { name => $role_name } ),
        'role_id' );
    return 0 if !$role || !defined $member->{id};

    return $self->_single_row(
        'RoleBinding',
        {
            resource_type => $GLOBAL_RESOURCE_TYPE,
            revoked_at    => undef,
            role_id       => $role->{role_id},
            user_id       => $member->{id},
        }
    ) ? 1 : 0;
}

# Whether a member can sign in: an active account with a verified address.
sub can_sign_in ( $self, $member ) {
    return ( $member->{status} // q{} ) eq $ACTIVE
      && defined $member->{email_verified_at} ? 1 : 0;
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

sub _ensure_role ( $self, $input, $actor_user_id ) {
    my $role_name = $input->{role_name} || $DEFAULT_ROLE_NAME;
    my $existing  = $self->_single_row( 'Role', { name => $role_name } );
    if ($existing) {
        return {
            role    => _row_hash( $existing, @ROLE_COLUMNS ),
            created => 0,
        };
    }

    my $role = $self->_role_catalog->create_role(
        {
            actor_user_id => $actor_user_id,
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

# Each default permission is found or created, then found attached to the
# role or attached.
sub _ensure_role_permissions ( $self, $role_id, $actor_user_id ) {
    my @permissions;
    my $created_permissions       = 0;
    my $attached_role_permissions = 0;

    for my $definition ( @{ $self->default_permissions } ) {
        my $permission = _row_hash(
            $self->_single_row(
                'Permission',
                {
                    resource_type => $definition->{resource_type},
                    action        => $definition->{action},
                }
            ),
            @PERMISSION_COLUMNS
        );
        my $created = $permission ? 0 : 1;
        if ($created) {
            $permission = $self->_role_catalog->create_permission(
                { %{$definition}, actor_user_id => $actor_user_id } );
        }

        my $attachment = {
            actor_user_id => $actor_user_id,
            role_id       => $role_id,
            permission_id => $permission->{permission_id},
        };
        my $attached = $self->_single_row(
            'RolePermission',
            {
                role_id       => $role_id,
                permission_id => $attachment->{permission_id},
            }
        ) ? 0 : 1;
        if ($attached) {
            $self->_role_catalog->attach_permission($attachment);
        }

        $created_permissions       += $created;
        $attached_role_permissions += $attached;
        push @permissions,
          {
            permission => $permission,
            attached   => $attached,
            created    => $created,
          };
    }

    return {
        permissions               => \@permissions,
        permissions_created       => $created_permissions,
        role_permissions_attached => $attached_role_permissions,
    };
}

sub _ensure_global_binding ( $self, $user_id, $role_id, $actor_user_id ) {
    my $existing = $self->_single_row(
        'RoleBinding',
        {
            user_id       => $user_id,
            role_id       => $role_id,
            resource_type => $GLOBAL_RESOURCE_TYPE,
            resource_id   => undef,
            space_id      => undef,
            revoked_at    => undef,
        }
    );
    if ($existing) {
        return {
            binding => _row_hash( $existing, @BINDING_COLUMNS ),
            created => 0,
        };
    }

    my $bound = GPForum::Service::Admin::RoleBindingStore->new(
        schema     => $self->schema,
        clock      => $self->clock,
        id_service => $self->id_service,
    )->bind_role(
        {
            actor_user_id => $actor_user_id,
            user_id       => $user_id,
            role_id       => $role_id,
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

    return undef;
}

# The registration create_owner writes: the member's fields checked and the
# password hashed as a sign-up does, then the account active and verified.
sub _prepared ( $self, $input ) {
    my $username = $input->{username};
    my $prepared =
      GPForum::Service::Identity::Registration->new(
        id_service => $self->id_service )->prepare(
        {
            display_name => $input->{display_name} // $username,
            email        => $input->{email},
            password     => $input->{password},
            username     => $username,
        }
        );
    if ( !$prepared->{ok} ) {
        return {
            errors => $prepared->{errors},
            ok     => 0,
            values => $prepared->{values},
        };
    }

    my $registration = $prepared->{registration};
    $registration->{user} = {
        %{ $registration->{user} },
        email_verified_at => $self->clock->now_iso8601,
        status            => $ACTIVE,
    };

    return { ok => 1, registration => $registration };
}

sub _taken ( $self, $user ) {
    my %errors;
    if ( $self->_single_row( 'User', { username => $user->{username} } ) ) {
        $errors{username} = 'username is already registered';
    }
    if (
        $self->_single_row(
            'User', { email_normalized => $user->{email_normalized} }
        )
      )
    {
        $errors{email} = 'email is already registered';
    }

    return \%errors;
}

sub _member_hash ($user) {
    return {
        map  { $_ => $user->{$_} }
        grep { exists $user->{$_} } @MEMBER_COLUMNS
    };
}

sub _role_catalog ($self) {
    return GPForum::Service::Admin::RoleCatalog->new(
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
    return undef if !$row;

    my %hash =
      map { $_ => ref $row eq 'HASH' ? $row->{$_} : $row->get_column($_) }
      @columns;

    return \%hash;
}

sub _bool_to_count ($value) {
    return $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::Bootstrapper - Makes the forum's owner, or grants the owner role.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $bootstrapper =
      GPForum::Service::Admin::Bootstrapper->new( schema => $schema );
    my $result = $bootstrapper->bootstrap( { user_id => $user_id } );
    printf "created %d binding(s)\n", $result->{counts}{bindings_created};

=head1 DESCRIPTION

A new install has no administrator, and the console refuses everyone until
someone holds a role with its permissions. This is what
L<GPForum::Command::AdminBootstrap> runs to break that circle: in one
transaction it makes sure the owner role exists, that it carries every
permission in L</default_permissions>, and that the given user holds it
globally (no resource, no space, not revoked).

Each step finds what is already there before it creates anything, so running
it again on a bootstrapped install changes nothing and reports zero
creations. The role and permissions are created through
L<GPForum::Service::Admin::RoleCatalog> and the binding through
L<GPForum::Service::Admin::RoleBindingStore>, so they are audited as any
console change is.

L</create_owner> goes one step further for a fresh install: it makes the
owner's account too, active and verified, so the first sign-in needs
neither a mail server nor a database query (C<gpforum admin create>).
L</find_member> and L</has_owner> answer what C<gpforum admin grant> and
C<gpforum migrate> ask.

=head1 SUBROUTINES/METHODS

=head2 bootstrap

Takes a hash reference: C<user_id> (required), C<actor_user_id> (recorded
as the actor; defaults to C<user_id>), C<role_name> (defaults to
C<gpforum_owner>) and C<role_description> (used only when the role is
created; defaults to C<Full GPForum administrative governance>).

Runs inside C<< $schema->txn_do >> and returns a hash reference with C<role>
(C<role_id>, C<name>, C<description>, C<created_at>), C<permissions> (one
entry per default permission: the C<permission> row, and C<created> and
C<attached> flags saying whether this run made it and linked it to the
role), C<binding> (the global binding's columns) and C<counts>
(C<roles_created>, C<permissions_created>, C<role_permissions_attached>,
C<bindings_created>).

=head2 create_owner

Takes a hash reference with C<email>, C<username>, C<password> and the
optional C<display_name> (the username by default) and C<role_name>, and
makes the forum's owner in one transaction: an account checked and hashed
as a sign-up's is, but C<active> with its address verified now, written
through L<GPForum::Service::Identity::Store> (so it is audited as
C<user.registered>), then L</bootstrap> for it, then an
C<admin.bootstrap_created> audit row. Returns what L</bootstrap> returns plus
C<ok> 1 and C<user> (C<id>, C<username>, C<email_normalized>, C<status>,
C<email_verified_at>); or C<ok> 0 and C<errors>, by field, as a sign-up
words them (C<username is already registered>, C<email format is
invalid>, ...), having written nothing.

=head2 check_owner

What L</create_owner> would answer, without writing or hashing: C<ok> 0
and C<errors> for a field it would refuse or a username or address already
taken, else C<ok> 1 and C<user>. A missing C<password> is not an error
here.

=head2 find_member

Takes an email address or a username, as typed (case and surrounding space
do not matter), and returns the member (C<id>, C<username>,
C<email_normalized>, C<status>, C<email_verified_at>), or undef.

=head2 has_owner

True when someone holds the owner role (or the role named) globally and
unrevoked; false on an install that has none yet, or no such role.

=head2 is_owner

Takes a member, as L</find_member> returns one, and optionally a role name;
true when that member holds the owner role (or the role named) globally and
unrevoked.

=head2 can_sign_in

Takes a member as L</find_member> returns one and is true when the account
is active with a verified address.

=head2 default_permissions

Returns an array reference of the permissions the owner role is given, each
a hash reference with C<name> (C<resource_type.action>), C<resource_type> and
C<action>: C<admin_console> view and manage; C<category> read; C<report>
view_queue, assign and resolve; C<post> and C<thread> moderate;
C<moderation_action> view and reverse; C<suspension> view; C<user> suspend;
C<privacy_rights> view and manage.

=head1 DIAGNOSTICS

Throws L<GPForum::X::Argument> (C<admin bootstrap requires user_id>) when
C<user_id> is missing or empty. Database errors propagate, and the
transaction rolls back everything the run had created.

=head1 CONFIGURATION AND ENVIRONMENT

None. The caller supplies the schema; C<identity_store> defaults to a
L<GPForum::Service::Identity::Store> on it.

=head1 DEPENDENCIES

L<GPForum::Service::Admin::RoleCatalog>,
L<GPForum::Service::Admin::RoleBindingStore>,
L<GPForum::Service::Identity::Registration>,
L<GPForum::Service::Identity::Store>,
L<GPForum::Service::Clock>,
L<GPForum::Infrastructure::Id>,
L<GPForum::X::Argument>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

L</create_owner> makes the account active without the verification mail a
sign-up sends: the address is the operator's word.

The role is found by name alone: an existing role of that name is used as it
is, and its description is not updated. Permissions are only ever added, so
one removed from L</default_permissions> stays attached on an install that
already has it. The user id is not checked against the users table here.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
