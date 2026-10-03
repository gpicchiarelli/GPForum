# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RequiresStore;

use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

# A class with one required attribute, a lazy default and an optional
# attribute: what t/323-base-requires.t builds GPForum::Base objects from.
__PACKAGE__->requires(qw(schema));

has clock => sub { return 'clock'; };
has 'logger';

1;
