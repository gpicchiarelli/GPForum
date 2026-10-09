# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::NoServiceUnits;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# The service units of a host doctor does not look at.
sub applies ($self) {
    return 0;
}

1;
