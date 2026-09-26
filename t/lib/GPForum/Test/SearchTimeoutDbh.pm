# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchTimeoutDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has storage => undef;

# Records the statement, its binds and the transaction depth it ran at: a
# setting local to a transaction is only local if there was one.
sub do {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my ( $self, $sql, undef, @bind ) = @_;

    my $storage = $self->storage;
    push @{ $storage->statements }, [ $sql, @bind, $storage->txn_depth ];

    return 1;
}

1;
