# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RoleBindingSearch;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# The rows one RoleBindingResultSet search matched.
has matched => sub { return []; };

sub single {
    my ($self) = @_;

    return $self->matched->[0];
}

1;
