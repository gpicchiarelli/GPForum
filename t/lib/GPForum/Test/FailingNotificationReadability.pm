# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingNotificationReadability;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# The notification dispatcher's readability, which every source passes
# until fail is set; then building the condition dies, as the query does
# when PostgreSQL cancels it. The unread count is the only reader of it
# after a mark-read, so a test can fail that count and nothing else. With
# fail_in_sql set instead, the condition is SQL that PostgreSQL refuses, so
# the statement fails in the database and aborts the transaction it is in.
has fail        => 0;
has fail_in_sql => 0;

sub sources_condition {
    my ($self) = @_;

    if ( $self->fail ) {
        die "canceling statement due to statement timeout\n";
    }
    if ( $self->fail_in_sql ) {
        return \'1 / 0 = 1';
    }

    return ();
}

1;
