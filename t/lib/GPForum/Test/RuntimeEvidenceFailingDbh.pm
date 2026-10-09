# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RuntimeEvidenceFailingDbh;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# A database handle that cannot read pg_settings.

sub selectall_arrayref {
    croak 'pg_settings unavailable';
}

1;
