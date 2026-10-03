# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::QueryBudgetSchema;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has budget_resultset => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->budget_resultset;
}

1;
