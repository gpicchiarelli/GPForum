# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimePermissionEngine;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has denied => sub { return {}; };

sub permits {
    my ( $self, @arguments ) = @_;

    my $resource = $arguments[2];

    return !$self->denied->{ $resource->{id} };
}

1;

