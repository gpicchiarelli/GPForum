# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::DbQueryStatsSchema;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::DbQueryStatsStorage;

our $VERSION = '0.001';

has storage => sub { return GPForum::Test::DbQueryStatsStorage->new; };

1;
