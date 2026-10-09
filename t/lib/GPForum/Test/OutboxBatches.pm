# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxBatches;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# An outbox dispatcher that answers each call with the next summary given,
# and with an empty batch once they run out.
has summaries => sub { return [] };

sub dispatch_pending ( $self, $limit ) {
    return shift @{ $self->summaries } // { selected => 0 };
}

1;
