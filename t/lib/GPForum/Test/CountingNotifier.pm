# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CountingNotifier;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub notify {
    my ( $self, $event ) = @_;

    push @{ $self->calls }, $event;

    return { ok => 1 };
}

1;
