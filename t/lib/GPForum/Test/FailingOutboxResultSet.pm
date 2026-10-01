# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingOutboxResultSet;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::OutboxResultSet';

our $VERSION = '0.001';

# An outbox whose query fails when it runs, as DBIx::Class's does: building
# the resultset sends nothing, and the error comes when the rows are read.
has failure =>
  'DBD::Pg::st execute failed: server closed the connection unexpectedly';

sub search_rs {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs($attrs);

    return $self;
}

sub _read_rows {
    my ($self) = @_;

    croak $self->failure;
}

# Named as DBIx::Class names it, which is also a builtin's name.
*GPForum::Test::FailingOutboxResultSet::all = \&_read_rows;

1;
