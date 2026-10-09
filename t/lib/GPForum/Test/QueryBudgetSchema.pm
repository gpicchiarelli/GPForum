# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::QueryBudgetSchema;

use Mojo::Base -base;
use v5.40;

use GPForum::Test::BareStorage;

our $VERSION = '0.001';

# DBIx::Class gives every schema a storage; this one has no database behind it.
has storage => sub { return GPForum::Test::BareStorage->new; };

has budget_resultset => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->budget_resultset;
}

1;
