# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::AppliedRunner;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# A migration runner whose apply_pending reports the migrations it was given
# as applied, for testing what bin/gpforum-migrate does after them.
has applied => sub { return []; };
has schema  => undef;                # optional: held, never read

sub apply_pending {
    my ($self) = @_;

    return $self->applied;
}

1;
