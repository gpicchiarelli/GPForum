# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::DenyLimiter;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

sub check {
    return { ok => 0 };
}

1;
