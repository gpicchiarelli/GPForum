# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PostReader;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has post => undef;

sub find_post {
    my ($self) = @_;

    return $self->post;
}

1;
