# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxSchema;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::TransactionalSchema';
use v5.40;

use GPForum::Test::RowState;

our $VERSION = '0.001';

# This double holds no rows of its own: they live on the resultsets, which is
# why storage_accessors is empty and snapshot reaches through to them instead.

has outbox_resultset      => undef;
has dead_letter_resultset => undef;

# Deliberately not the base's savepoint storage. The dispatcher chooses between
# the PostgreSQL claim and the resultset claim by asking the schema for a
# handle, so a default storage reporting a Pg driver would move every test onto
# the SQL claim path. Tests that want that path inject their own storage.
has storage => undef;

sub storage_accessors {
    return ();
}

sub snapshot {
    my ($self) = @_;

    my $snapshot = $self->SUPER::snapshot;
    $snapshot->{row_sets} =
      GPForum::Test::RowState::capture_resultsets( $self->outbox_resultset,
        $self->dead_letter_resultset );

    return $snapshot;
}

# Copying the row set alone put the same row objects back, so a rolled back
# transaction left every column change the failed attempt had made. A test
# could not tell a rollback from a commit, which is precisely what a
# transactional defect looks like. RowState puts the columns back too.
sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    if ( $snapshot->{row_sets} ) {
        GPForum::Test::RowState::restore( $snapshot->{row_sets} );
    }

    return;
}

sub resultset {
    my ( $self, $name ) = @_;

    return $self->_wired( $self->outbox_resultset ) if $name eq 'OutboxMessage';
    return $self->_wired( $self->dead_letter_resultset )
      if $name eq 'DeadLetter';

    croak 'unexpected resultset';
}

# The tests build the resultsets standalone, so the schema introduces itself
# here. Without the back-reference a resultset cannot ask whether the
# transaction is aborted.
sub _wired {
    my ( $self, $resultset ) = @_;

    if ( !$resultset || !$resultset->can('schema') ) {
        return $resultset;
    }
    if ( !$resultset->schema ) {
        $resultset->schema($self);
    }

    return $resultset;
}

1;
