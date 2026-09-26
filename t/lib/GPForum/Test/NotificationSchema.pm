# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::NotificationSchema;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base 'GPForum::Test::TransactionalSchema';

our $VERSION = '0.001';

# This double holds no rows of its own: every row set lives on an injected
# resultset. Snapshot and restore therefore walk the resultsets rather than
# schema accessors, which is what GPForum::Test::Transaction used to do for
# the whole transaction and what savepoint rollback now needs as two halves.
const my @ROW_SET_ACCESSOR => qw(created created_objects rows);

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
    $snapshot->{resultsets} =
      [ map { _snapshot_resultset($_) } values %{ $self->resultsets } ];

    return $snapshot;
}

sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    for my $entry ( @{ $snapshot->{resultsets} || [] } ) {
        _restore_entry($entry);
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

sub _snapshot_resultset {
    my ($resultset) = @_;

    my @entries;
    for my $accessor (@ROW_SET_ACCESSOR) {
        next if !_holds_row_set( $resultset, $accessor );
        push @entries,
          {
            accessor  => $accessor,
            held      => _copied( $resultset->$accessor ),
            resultset => $resultset,
          };
    }

    return @entries;
}

sub _holds_row_set {
    my ( $resultset, $accessor ) = @_;

    return 0 if !ref $resultset;
    return 0 if !$resultset->can($accessor);

    return ref $resultset->$accessor ? 1 : 0;
}

sub _copied {
    my ($held) = @_;

    return [ @{$held} ] if ref $held eq 'ARRAY';

    return { %{$held} };
}

# Row membership is put back into the live container, so a reference a test or
# a store already holds still sees the rollback.
sub _restore_entry {
    my ($entry) = @_;

    my $accessor = $entry->{accessor};
    my $live     = $entry->{resultset}->$accessor;
    my $held     = $entry->{held};

    if ( ref $held eq 'ARRAY' ) {
        @{$live} = @{$held};
        return;
    }

    %{$live} = %{$held};

    return;
}

1;
