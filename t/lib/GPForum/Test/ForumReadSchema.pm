# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ForumReadSchema;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has resultsets => sub { return {}; };

sub resultset {
    my ( $self, $name ) = @_;

    return $self->resultsets->{$name};
}

1;

