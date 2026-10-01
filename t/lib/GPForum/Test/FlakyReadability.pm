# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FlakyReadability;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# Thread or post ids whose readers cannot be asked: readers_of dies for
# them, as Readability does when its query fails. Everyone reads the rest.
has unreachable => sub { return {}; };

sub readers_of {
    my ( $self, undef, $id, @readers ) = @_;

    if ( $self->unreachable->{$id} ) {
        die "readability query failed\n";
    }

    return @readers;
}

1;
