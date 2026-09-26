# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxSearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has rows => sub { return []; };

1;
