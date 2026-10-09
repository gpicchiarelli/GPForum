# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::MinionJob;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has finished => undef;    # optional: state, set by finish

sub finish {
    my ( $self, $payload ) = @_;

    $self->finished($payload);

    return $self;
}

1;
