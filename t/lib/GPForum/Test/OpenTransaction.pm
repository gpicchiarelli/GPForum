# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OpenTransaction;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# What GPForum::Test::BadgeBroadcastSpy asks its schema -- whether a
# transaction is open -- answered for a real one: the PostgreSQL handle is
# out of AutoCommit from BEGIN until COMMIT or ROLLBACK.
has schema => undef;

sub in_transaction {
    my ($self) = @_;

    return $self->schema->storage->dbh->{AutoCommit} ? 0 : 1;
}

1;
