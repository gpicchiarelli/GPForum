# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::PermissionGate;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my %GLOBAL_BINDING => (
    'me.resource_id' => undef,
    'me.space_id'    => undef,
);

has schema => undef;

sub allowed ( $self, $actor, $permission ) {
    my $user_id = _user_id($actor);
    return 0 if !defined $user_id || !length $user_id;

    my $search = $self->schema->resultset('RoleBinding')->search_rs(
        {
            'me.user_id'               => $user_id,
            'me.revoked_at'            => undef,
            'permission.resource_type' => $permission->{resource_type},
            'permission.action'        => $permission->{action},
            %{ _scope_condition($permission) },
        },
        {
            join => { role => { role_permissions => 'permission' } },
            rows => 1,
        }
    );

    return $search->single ? 1 : 0;
}

sub _scope_condition ($permission) {
    my $resource_id = _scope_value( $permission->{resource_id} );
    my $space_id    = _scope_value( $permission->{space_id} );

    if ( !defined $resource_id && !defined $space_id ) {
        return {%GLOBAL_BINDING};
    }

    return {
        -or => [
            {%GLOBAL_BINDING},
            {
                'me.resource_id' => $resource_id,
                'me.space_id'    => $space_id,
            },
        ],
    };
}

sub _scope_value ($value) {
    my $scope;
    if ( defined $value && length $value ) {
        $scope = $value;
    }

    return $scope;
}

sub _user_id ($actor) {
    return                   if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::PermissionGate - Scope-aware role binding check.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $gate = GPForum::Service::Admin::PermissionGate->new( schema => $schema );

    my $global = $gate->allowed(
        { user_id       => $user_id },
        { resource_type => 'report', action => 'view_queue' },
    );

    my $scoped = $gate->allowed(
        { user_id => $user_id },
        {
            resource_type => 'thread',
            action        => 'moderate',
            resource_id   => $thread_id,
            space_id      => $space_id,
        },
    );

=head1 DESCRIPTION

Answers whether an actor holds a permission through an active role binding.
C<role_bindings> rows carry an optional C<resource_id> and C<space_id>; a row
with both columns NULL is a global grant, any other row is scoped to that
resource or space.

The check is deliberately fail-closed. A caller that supplies no scope is
only satisfied by global bindings, so a binding scoped to one category or
space can never authorize an unscoped action. A caller that supplies a scope
is satisfied by global bindings and by bindings whose C<resource_id> and
C<space_id> both equal the requested scope; a partial match does not count.

=head1 SUBROUTINES/METHODS

=head2 allowed

Takes an actor (a user id, or a hash with C<user_id>) and a permission hash
with C<resource_type> and C<action>, plus optional C<resource_id> and
C<space_id> naming the scope the caller is acting on. Returns 1 when an
unrevoked role binding grants the permission at global scope or at exactly
the requested scope, and 0 otherwise. An empty string scope is treated as no
scope.

=head1 DIAGNOSTICS

None. The gate returns 0 rather than throwing for unknown actors.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a schema with a C<RoleBinding> resultset joined to roles,
role permissions, and permissions. C<gpforum-admin-bootstrap> creates the
first binding with both scope columns NULL, so bootstrap grants stay global.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not resolve a scoped resource to its parent category or space, so a
category-scoped binding does not authorize an action addressed by thread or
post id. Callers pass the scope they are acting on.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
