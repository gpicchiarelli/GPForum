# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CommunitySchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::TransactionalSchema';

our $VERSION = '0.001';

has resultsets => sub { return {}; };

# Every row this double holds lives in the GPForum::Test::CommunityResultSet
# objects behind `resultsets`, so there is no schema-level row accessor for the
# base to snapshot. The snapshot is extended below instead.
sub storage_accessors {
    return ();
}

sub resultset {
    my ( $self, $name ) = @_;

    if ( !exists $self->resultsets->{$name} ) {
        croak 'unexpected resultset';
    }

    my $resultset = $self->resultsets->{$name};

    # The resultsets are built before the schema, so hand each one the back
    # pointer its aborted-transaction guard reads.
    if ( $resultset && $resultset->can('schema') ) {
        $resultset->schema($self);
    }

    return $resultset;
}

# A savepoint rollback has to put the rows back, and here they sit on the
# resultsets rather than on the schema.
sub snapshot {
    my ($self) = @_;

    my $snapshot = $self->SUPER::snapshot;
    $snapshot->{resultsets} = $self->_resultset_snapshots;

    return $snapshot;
}

sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    $self->_restore_resultsets( $snapshot->{resultsets} || {} );

    return;
}

sub _resultset_snapshots {
    my ($self) = @_;

    my %held;
    for my $name ( keys %{ $self->resultsets } ) {
        my $resultset = $self->resultsets->{$name};
        if ( !$resultset || !$resultset->can('snapshot_rows') ) {
            next;
        }
        $held{$name} = $resultset->snapshot_rows;
    }

    return \%held;
}

sub _restore_resultsets {
    my ( $self, $held ) = @_;

    for my $name ( keys %{$held} ) {
        my $resultset = $self->resultsets->{$name};
        if ( !$resultset || !$resultset->can('restore_rows') ) {
            next;
        }
        $resultset->restore_rows( $held->{$name} );
    }

    return;
}

1;
