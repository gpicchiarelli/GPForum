# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::StatementTimeoutReadability;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

# What DBI reports when PostgreSQL cancels a statement, up to the statement
# and bind values it appends (ShowErrorStatement, which DBIx::Class sets).
const my $MESSAGE => 'DBI Exception: DBD::Pg::st execute failed: '
  . 'ERROR:  canceling statement due to statement timeout';

# The notification dispatcher's readability, which every source passes
# until fail is set; then building the condition dies as DBI reports the
# cancelled count, its statement and its bind value -- the reader -- on the
# same line, so each member's failure carries a different message. With
# fail_with set it croaks with that text instead.
has fail      => 0;
has fail_with => undef;

sub message {
    return $MESSAGE;
}

sub sources_condition {
    my ( $self, $reader ) = @_;

    if ( defined $self->fail_with ) {
        croak $self->fail_with;
    }
    if ( $self->fail ) {
        die $MESSAGE
          . ' [for Statement "SELECT COUNT( * ) FROM notification_inbox me'
          . ' WHERE ( me.recipient_user_id = ? )" with ParamValues: 1='
          . "'$reader'] at lib/GPForum/Service/Notification/Dispatcher.pm"
          . " line 1.\n";
    }

    return ();
}

1;
