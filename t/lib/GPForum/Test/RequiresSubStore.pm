# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RequiresSubStore;

use Mojo::Base 'GPForum::Test::RequiresStore', -signatures;
use v5.40;

our $VERSION = '0.001';

# A subclass that adds a required attribute of its own and declares an
# inherited one again, which required_attributes lists once.
__PACKAGE__->requires(qw(recorder schema));

1;
