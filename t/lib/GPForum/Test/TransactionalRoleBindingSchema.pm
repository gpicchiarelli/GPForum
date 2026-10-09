# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::TransactionalRoleBindingSchema;

use Mojo::Base 'GPForum::Test::RoleBindingSchema';
use v5.40;

our $VERSION = '0.001';

# A RoleBindingSchema with txn_do, counting the transactions it ran.
has transactions => 0;

sub txn_do {
    my ( $self, $code ) = @_;

    $self->transactions( $self->transactions + 1 );

    return $code->();
}

1;
