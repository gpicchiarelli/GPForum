# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SharedCacheError;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# The part of GlifiStore::Error that SharedCache reads: the category a
# failure is classified by, and a message for whoever prints it.
has category => 'transport';
has message  => q{};

1;
