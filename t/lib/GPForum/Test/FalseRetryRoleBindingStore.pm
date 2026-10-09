# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FalseRetryRoleBindingStore;

use Mojo::Base 'GPForum::Service::Admin::RoleBindingStore';
use v5.40;

use GPForum::Infrastructure::UniqueConflict;

our $VERSION = '0.001';

# The first insert hits an id conflict; the retry returns a false result
# instead of throwing, so the store must not rethrow a stale error.
has attempts => 0;

sub _create_binding {    ## no critic (Subroutines::ProhibitUnusedPrivateSubroutines) -- overrides the store's insert step
    my ($self) = @_;

    $self->attempts( $self->attempts + 1 );
    if ( $self->attempts == 1 ) {
        GPForum::Infrastructure::UniqueConflict->throw('role_bindings_pkey');
    }

    return 0;
}

1;
