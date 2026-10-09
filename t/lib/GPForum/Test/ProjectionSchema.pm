# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ProjectionSchema;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has offset_resultset => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->offset_resultset if $name eq 'ProjectionOffset';

    croak 'unexpected resultset';
}

1;
