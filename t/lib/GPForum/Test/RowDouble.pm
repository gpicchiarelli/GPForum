# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RowDouble;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

# The get_column half of what GPForum::Infrastructure::Row accepts: a row that
# is an object rather than a hashref.
has columns => sub { return {}; };

sub get_column ( $self, $name ) {
    return $self->columns->{$name};
}

1;
