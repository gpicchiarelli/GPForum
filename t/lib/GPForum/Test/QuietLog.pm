# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::QuietLog;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has errors => sub { return []; };

# A logger that keeps what it is told, so a test that expects an error does
# not print one.
sub error {
    my ( $self, @message ) = @_;

    push @{ $self->errors }, join q{}, @message;

    return;
}

1;
