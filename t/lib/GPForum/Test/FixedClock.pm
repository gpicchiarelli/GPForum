# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FixedClock;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has epoch   => 1_716_464_000;
has iso8601 => '2026-05-23T12:00:00Z';

sub now_epoch {
    my ($self) = @_;

    return $self->epoch;
}

sub now_iso8601 {
    my ($self) = @_;

    return $self->iso8601;
}

1;
