# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::MigrationStorage;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::MigrationDbh;

our $VERSION = '0.001';

has dbh => sub { return GPForum::Test::MigrationDbh->new; };

1;
