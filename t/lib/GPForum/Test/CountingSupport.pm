# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CountingSupport;

use Mojo::Base 'GPForum::Service::Identity::Support';
use v5.40;

our $VERSION = '0.001';

has updates => 0;

sub update_row {
    my ( $self, $row, $values ) = @_;

    $self->updates( $self->updates + 1 );

    return $self->SUPER::update_row( $row, $values );
}

1;
