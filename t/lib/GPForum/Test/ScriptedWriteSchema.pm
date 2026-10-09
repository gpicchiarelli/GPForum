# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScriptedWriteSchema;

use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Test::ScriptedWriteResultSet;

our $VERSION = '0.001';

# One GPForum::Test::ScriptedWriteResultSet per source, made on first use.
# No storage and no txn_do: the event recorder writes straight through, with
# no savepoint and no advisory lock, so each scripted error reaches it as the
# create raised it.
has resultsets => sub { return {}; };

sub resultset ( $self, $name ) {
    return $self->resultsets->{$name} //=
      GPForum::Test::ScriptedWriteResultSet->new;
}

1;
