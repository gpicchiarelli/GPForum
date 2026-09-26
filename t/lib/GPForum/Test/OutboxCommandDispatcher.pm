# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxCommandDispatcher;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

# How many messages each call claims, in order; a full batch once these run
# out.
has selected => sub { return []; };

sub dispatch_pending {
    my ( $self, $limit ) = @_;

    push @{ $self->calls }, $limit;
    my $selected = @{ $self->selected } ? shift @{ $self->selected } : $limit;

    return {
        dead_lettered => 0,
        dispatched    => $selected,
        failed        => 0,
        selected      => $selected,
    };
}

1;
