# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxSchema;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base 'GPForum::Test::TransactionalSchema';

our $VERSION = '0.001';

# Row sets a fake outbox resultset keeps. This double holds no rows of its own:
# they live on the resultsets, which is why storage_accessors is empty and
# snapshot reaches through to them instead.
const my @ROW_SET_ACCESSOR => qw(created created_objects rows);

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
    $snapshot->{row_sets} = [ map { _copied($_) } $self->_row_sets ];
    $snapshot->{row_data} = [ map { _row_state($_) } $self->_rows ];

    return $snapshot;
}

# Copying the row set alone put the same row objects back, so a rolled back
# transaction left every column change the failed attempt had made. A test
# could not tell a rollback from a commit, which is precisely what a
# transactional defect looks like.
sub _rows {
    my ($self) = @_;

    my @rows;
    for my $set ( $self->_row_sets ) {
        next if ref $set ne 'ARRAY';
        push @rows, grep { ref $_ && ref $_ ne 'HASH' } @{$set};
    }

    return @rows;
}

sub _row_state {
    my ($row) = @_;

    return { row => $row } if !$row->can('data');

    return { row => $row, data => { %{ $row->data } } };
}

sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    my @live = $self->_row_sets;
    my $held = $snapshot->{row_sets} || [];
    for my $index ( 0 .. $#live ) {
        _restore_row_set( $live[$index], $held->[$index] );
    }
    for my $state ( @{ $snapshot->{row_data} || [] } ) {
        _restore_row_state($state);
    }

    return;
}

sub _restore_row_state {
    my ($state) = @_;

    return if !$state->{data};

    %{ $state->{row}->data } = %{ $state->{data} };

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

sub _row_sets {
    my ($self) = @_;

    my @sets;
    for my $resultset ( $self->outbox_resultset, $self->dead_letter_resultset )
    {
        push @sets, _resultset_row_sets($resultset);
    }

    return @sets;
}

sub _resultset_row_sets {
    my ($resultset) = @_;

    if ( !ref $resultset ) {
        return ();
    }

    my @sets;
    for my $accessor (@ROW_SET_ACCESSOR) {
        next if !$resultset->can($accessor);
        my $held = $resultset->$accessor;
        next if !ref $held;
        push @sets, $held;
    }

    return @sets;
}

sub _copied {
    my ($held) = @_;

    return [ @{$held} ] if ref $held eq 'ARRAY';

    return { %{$held} };
}

sub _restore_row_set {
    my ( $live, $held ) = @_;

    if ( !defined $held ) {
        return;
    }
    if ( ref $held eq 'ARRAY' ) {
        @{$live} = @{$held};
        return;
    }
    %{$live} = %{$held};

    return;
}

1;
