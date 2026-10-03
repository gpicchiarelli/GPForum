# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxPayloadRow;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has data => sub { return {}; };

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

1;
