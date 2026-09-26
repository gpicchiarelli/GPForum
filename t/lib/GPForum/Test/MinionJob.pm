# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::MinionJob;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has finished => undef;

sub finish {
    my ( $self, $payload ) = @_;

    $self->finished($payload);

    return $self;
}

1;
