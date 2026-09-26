# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingSearchResultSet;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::SearchResultSet';

our $VERSION = '0.001';

# The error the next search dies with, as the database's would: a statement
# cancelled at its timeout is an exception like any other.
has failure => undef;

sub search {
    my ( $self, @arguments ) = @_;

    croak $self->failure if defined $self->failure;

    return $self->SUPER::search(@arguments);
}

1;
