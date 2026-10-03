# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::DenyPermissionGate;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

sub allowed {
    return 0;
}

1;
