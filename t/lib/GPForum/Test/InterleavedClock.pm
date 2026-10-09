# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::InterleavedClock;

use Mojo::Base 'GPForum::Test::FixedClock';
use v5.40;

our $VERSION = '0.001';

# A fixed clock that runs a piece of work, once, the next time it is read.
# The notification stores read the clock after looking for a row and before
# inserting it, so the work can commit a competing row from another
# connection in exactly that window: the race the fake ORM played by
# missing a find, with PostgreSQL raising the conflict itself.
has before_next_read => undef;

sub now_iso8601 {
    my ($self) = @_;

    my $work = $self->before_next_read;
    if ($work) {
        $self->before_next_read(undef);
        $work->();
    }

    return $self->SUPER::now_iso8601;
}

1;
