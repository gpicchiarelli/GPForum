# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ProjectionGenerationSchema;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has generation_resultset => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->generation_resultset if $name eq 'ProjectionGeneration';

    croak 'unexpected resultset';
}

1;
