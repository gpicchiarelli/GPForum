# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ModerationRow;

use Mojo::Base 'GPForum::Test::Row';
use v5.40;

our $VERSION = '0.001';

# The resultset refuses a row whose columns its result class does not have,
# as an INSERT naming an unknown column fails.
sub assert_columns {
    my ( $self, @columns ) = @_;

    for my $column (@columns) {
        $self->_assert_column($column);
    }

    return;
}

# Its resultset keeps the hash it created the row from, so an update builds
# a new one rather than writing through to it.
sub write_columns {
    my ( $self, $changes ) = @_;

    $self->data( { %{ $self->data }, %{$changes} } );

    return;
}

1;
