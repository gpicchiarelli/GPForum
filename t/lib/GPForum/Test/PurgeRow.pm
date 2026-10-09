# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PurgeRow;

use Mojo::Base 'GPForum::Test::Row';
use v5.40;

our $VERSION = '0.001';

has deleted   => 0;
has on_delete => undef;
has values    => sub { return {}; };

sub column_data {
    my ($self) = @_;

    return $self->values;
}

sub remove_from_storage {
    my ($self) = @_;

    $self->deleted(1);
    if ( $self->on_delete ) {
        $self->on_delete->($self);
    }

    return;
}

1;
