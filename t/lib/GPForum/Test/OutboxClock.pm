# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxClock;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has now    => '2026-05-23T12:00:00Z';
has future => '2026-05-23T12:01:00Z';
has past   => '2026-05-23T11:45:00Z';

sub now_iso8601 {
    my ($self) = @_;

    return $self->now;
}

# The sign matters. This returned `future` for every non-zero offset,
# including a negative one, so a caller asking for "now minus a lease" was
# handed a time after now -- which made every claim look expired.
sub epoch_plus_iso8601 {
    my ( $self, $seconds ) = @_;

    return $self->now if !$seconds;

    return $seconds < 0 ? $self->past : $self->future;
}

1;
