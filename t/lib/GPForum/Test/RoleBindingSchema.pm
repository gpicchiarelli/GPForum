# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RoleBindingSchema;

use Mojo::Base -base;
use v5.40;

use GPForum::Test::RoleBindingResultSet;

our $VERSION = '0.001';

# A schema with no txn_do, so RoleBindingStore writes without a transaction;
# TransactionalRoleBindingSchema adds one. Rows are kept per resultset name,
# and created holds what each create was given.
has created    => sub { return {}; };
has find_attrs => sub { return []; };
has rows       => sub { return {}; };

sub resultset {
    my ( $self, $name ) = @_;

    return GPForum::Test::RoleBindingResultSet->new(
        name   => $name,
        schema => $self,
    );
}

sub created_for {
    my ( $self, $name ) = @_;

    return $self->created->{$name} //= [];
}

sub rows_for {
    my ( $self, $name ) = @_;

    return $self->rows->{$name} //= [];
}

1;
