# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Minion;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has tasks => sub { return {}; };

sub add_task {
    my ( $self, $name, $code ) = @_;

    $self->tasks->{$name} = $code;

    return $self;
}

1;
