# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ModerationSchema;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::TransactionalSchema';
use v5.40;

use GPForum::Test::RowState;

our $VERSION = '0.001';

# The rows live on the resultsets rather than on the schema, which is why this
# double has no storage accessors of its own and snapshots the resultsets
# instead.
has resultsets => sub { return {}; };

sub new {
    my ( $class, @arguments ) = @_;

    my $self = $class->SUPER::new(@arguments);
    $self->_adopt_resultsets;
    $self->_adopt_storage;

    return $self;
}

sub resultset {
    my ( $self, $name ) = @_;

    return $self->resultsets->{$name} if exists $self->resultsets->{$name};

    croak 'unexpected resultset';
}

sub storage_accessors {
    return ();
}

sub snapshot {
    my ($self) = @_;

    my $snapshot = $self->SUPER::snapshot;
    $snapshot->{row_sets} = GPForum::Test::RowState::capture_resultsets(
        values %{ $self->resultsets } );

    return $snapshot;
}

sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    if ( $snapshot->{row_sets} ) {
        GPForum::Test::RowState::restore( $snapshot->{row_sets} );
    }

    return;
}

# A resultset double answers queries, so it needs a way back to the schema to
# see whether the transaction is aborted.
sub _adopt_resultsets {
    my ($self) = @_;

    for my $resultset ( values %{ $self->resultsets } ) {
        next if !ref $resultset;
        next if !$resultset->can('schema');
        next if $resultset->schema;
        $resultset->schema($self);
    }

    return;
}

# A test that injects its own storage double, to watch the lock statements a
# store issues, still needs the savepoint surface bound to this schema, or
# conflict recovery degrades to a plain eval and stops testing the real thing.
sub _adopt_storage {
    my ($self) = @_;

    my $storage = $self->storage;
    if ( $storage && $storage->can('schema') && !$storage->schema ) {
        $storage->schema($self);
    }

    return;
}

1;
