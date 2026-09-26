# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Id;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has value => 0;

sub uuid {
    my ($self) = @_;

    $self->value( $self->value + 1 );

    return 'generated-' . $self->value;
}

1;
