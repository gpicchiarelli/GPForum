# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WorkflowThreadDetailReader;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A thread reader for PostingWorkflow that finds the thread it was built
# with, whatever id it is asked for.
has 'thread';

sub find_thread ( $self, @ ) {
    return $self->thread;
}

sub find_thread_row ( $self, @ ) {
    return $self->thread;
}

1;
