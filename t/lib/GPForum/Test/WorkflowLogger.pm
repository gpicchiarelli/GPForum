# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WorkflowLogger;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A logger for PostingWorkflow that counts its warnings.
has warnings => 0;

sub error ( $, @ ) {
    return undef;
}

sub warn ( $self, @ ) {    ## no critic (Subroutines::ProhibitBuiltinHomonyms) -- Mojo::Log names the level warn
    $self->warnings( $self->warnings + 1 );

    return undef;
}

1;
