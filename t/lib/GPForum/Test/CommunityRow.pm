# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CommunityRow;

use Mojo::Base 'GPForum::Test::Row';
use v5.40;

our $VERSION = '0.001';

# Its resultset keeps the hash it created the row from, so an update builds
# a new one rather than writing through to it.
sub write_columns {
    my ( $self, $changes ) = @_;

    $self->data( { %{ $self->data }, %{$changes} } );

    return;
}

1;
