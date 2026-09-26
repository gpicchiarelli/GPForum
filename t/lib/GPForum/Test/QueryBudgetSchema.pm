# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::QueryBudgetSchema;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has budget_resultset => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->budget_resultset;
}

1;
