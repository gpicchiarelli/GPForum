# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::PermissionReview;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 50;

has schema => undef;

sub roles_for_user ( $self, $user_id, $options ) {
    my $search = $self->schema->resultset('RoleBinding')->search_rs(
        {
            user_id    => $user_id,
            revoked_at => undef,
        },
        {
            order_by => [ { -asc => 'resource_type' }, { -asc => 'role_id' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );

    return [ _rows($search) ];
}

sub permissions_for_role ( $self, $role_id, $options ) {
    my $search = $self->schema->resultset('RolePermission')->search_rs(
        {
            role_id => $role_id,
        },
        {
            order_by => [ { -asc => 'permission_id' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );

    return [ _rows($search) ];
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
