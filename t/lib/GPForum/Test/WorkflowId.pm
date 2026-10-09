# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WorkflowId;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# An id generator for the forum bootstrap that always answers the same uuid.
sub uuid {
    return 'uuid-1';
}

1;
