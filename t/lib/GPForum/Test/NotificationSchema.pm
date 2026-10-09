# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::NotificationSchema;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::TransactionalSchema';
use v5.40;

use GPForum::Test::RowState;

our $VERSION = '0.001';

# This double holds no rows of its own: every row set lives on an injected
# resultset. Snapshot and restore therefore walk the resultsets rather than
# schema accessors, which is what GPForum::Test::Transaction used to do for
# the whole transaction and what savepoint rollback now needs as two halves.

has resultsets => sub { return {}; };

sub storage_accessors {
    return ();
}

# The resultsets are built before the schema and handed to it, so the schema
# back-reference that lets a resultset see an aborted transaction has to be
# wired here.
sub new {
    my ( $class, @arguments ) = @_;

    my $self = $class->SUPER::new(@arguments);
    for my $resultset ( values %{ $self->resultsets } ) {
        $self->_attach_schema($resultset);
    }

    return $self;
}

sub resultset {
    my ( $self, $name ) = @_;

    if ( !exists $self->resultsets->{$name} ) {
        croak 'unexpected resultset';
    }

    my $resultset = $self->resultsets->{$name};
    $self->_attach_schema($resultset);

    return $resultset;
}

sub snapshot {
    my ($self) = @_;

    my $snapshot = $self->SUPER::snapshot;
    $snapshot->{resultsets} = GPForum::Test::RowState::capture_resultsets(
        values %{ $self->resultsets } );

    return $snapshot;
}

sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    if ( $snapshot->{resultsets} ) {
        GPForum::Test::RowState::restore( $snapshot->{resultsets} );
    }

    return;
}

sub _attach_schema {
    my ( $self, $resultset ) = @_;

    if ( !ref $resultset || !$resultset->can('schema') ) {
        return;
    }
    if ( $resultset->schema ) {
        return;
    }
    $resultset->schema($self);

    return;
}

1;
