# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::UnreachableSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

# A schema a test must never reach: a command that refuses misuse has to do
# so before it touches the database, and any call here says it did not.
sub resultset {
    croak 'the database was reached';
}

sub storage {
    croak 'the database was reached';
}

sub txn_do {
    croak 'the database was reached';
}

1;
