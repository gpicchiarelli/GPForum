# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::MetricsSnapshot;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has collected => 0;

sub collect {
    my ($self) = @_;

    $self->collected( $self->collected + 1 );

    return { status => 'ok', counters => { requests => 1 } };
}

1;
