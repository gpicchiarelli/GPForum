# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScopeBindingSchema;

use Mojo::Base -base;
use v5.40;

use GPForum::Test::ScopeBindingResultSet;

our $VERSION = '0.001';

has role_bindings => sub { return GPForum::Test::ScopeBindingResultSet->new; };

sub resultset {
    my ($self) = @_;

    return $self->role_bindings;
}

1;
