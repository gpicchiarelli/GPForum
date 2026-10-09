# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WorkflowCategoryReader;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A category reader for PostingWorkflow that finds the general category, or
# nothing when built with found => 0.
has found => 1;

sub find_category ( $self, @ ) {
    return $self->found ? { category_id => 'general' } : undef;
}

1;
