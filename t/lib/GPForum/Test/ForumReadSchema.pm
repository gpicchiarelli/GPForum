# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ForumReadSchema;

use Mojo::Base -base;
use v5.40;

use GPForum::Test::BareStorage;

our $VERSION = '0.001';

# DBIx::Class gives every schema a storage; this one has no database behind it.
has storage => sub { return GPForum::Test::BareStorage->new; };

has resultsets => sub { return {}; };

sub resultset {
    my ( $self, $name ) = @_;

    return $self->resultsets->{$name};
}

1;

