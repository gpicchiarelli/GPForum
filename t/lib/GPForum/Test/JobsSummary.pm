# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::JobsSummary;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A scheduled-jobs runner that answers with the summary given, with no
# attachment store to lend the storage to.
has summary          => sub { return { ok => 1 } };
has attachment_store => undef;

sub run ( $self, $input ) {
    return $self->summary;
}

1;
