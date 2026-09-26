# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ProjectionGenerationSearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has rows => sub { return []; };

sub single {
    my ($self) = @_;

    return $self->rows->[0];
}

1;
