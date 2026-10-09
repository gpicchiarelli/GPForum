# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PhaseDrill;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# One phase of staging-drill-attachments that answers with the status it was
# given, or with no status at all when it was given none.
has status => undef;    # optional: a phase may answer without one

sub run ( $self, $options ) {
    return {} if !defined $self->status;

    return { status => $self->status };
}

1;
