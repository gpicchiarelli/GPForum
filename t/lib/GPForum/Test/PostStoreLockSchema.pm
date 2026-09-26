# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PostStoreLockSchema;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::Schema';

use GPForum::Test::PostStoreLockStorage;

our $VERSION = '0.001';

has lock_dbh => undef;

# Cached, because a savepoint opened by one call has to be findable by the
# next one: a fresh storage object per call would lose the stack.
has storage => sub {
    my ($self) = @_;

    return GPForum::Test::PostStoreLockStorage->new(
        dbh    => $self->lock_dbh,
        schema => $self,
    );
};

1;
