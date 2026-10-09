# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScriptedWriteResultSet;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# The errors the next creates die with, in order; once they run out, a create
# stores its row. t/355-event-recorder-conflicts.t scripts a conflict -- an
# exception or the plain text a fake ORM raises -- and counts the writes that
# followed it.
has failures => sub { return []; };
has created  => sub { return []; };

# What a lookup finds: nothing until a create has failed, then this row -- the
# row another writer stored first, which the failed insert collided with.
has found_after_failure => undef;    # optional: then lookups find nothing
has found               => undef;    # optional: set by a failed create

sub create ( $self, $row ) {
    if ( @{ $self->failures } ) {
        my $error = shift @{ $self->failures };
        $self->found( $self->found_after_failure );
        die $error;    ## no critic (ErrorHandling::RequireCarping)
    }
    push @{ $self->created }, $row;

    return $row;
}

sub find ( $self, @ ) {
    return $self->found;
}

sub search_rs ( $self, @ ) {
    return $self;
}

sub search ( $self, @ ) {
    return $self;
}

sub single ($self) {
    return $self->found;
}

1;
