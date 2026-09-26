# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ReadStateSchema;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'GPForum::Test::TransactionalSchema';

our $VERSION = '0.001';

# Row sets a read-state resultset keeps. This double holds no rows of its own,
# so snapshot and restore reach through to the resultsets it was handed.
const my @ROW_SET_ACCESSOR => qw(created created_objects rows);

has resultsets => sub { return {}; };

# Nothing on the schema holds rows; see the snapshot and restore overrides.
sub storage_accessors {
    return ();
}

sub resultset {
    my ( $self, $name ) = @_;

    my $resultset = $self->resultsets->{$name};

    # The resultset needs the schema back so it can see, and report, an
    # aborted transaction.
    if ( $resultset && $resultset->can('schema') && !$resultset->schema ) {
        $resultset->schema($self);
    }

    return $resultset;
}

sub snapshot {
    my ($self) = @_;

    my $snapshot = $self->SUPER::snapshot;
    my $row_sets = $self->resultsets;
    $snapshot->{resultsets} =
      { map { $_ => _held( $row_sets->{$_} ) } keys %{$row_sets} };

    return $snapshot;
}

sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    my $held = $snapshot->{resultsets} || {};
    for my $name ( keys %{$held} ) {
        _put_back( $self->resultsets->{$name}, $held->{$name} );
    }

    return;
}

sub _held {
    my ($resultset) = @_;

    my %held;
    for my $accessor (@ROW_SET_ACCESSOR) {
        next if !_holds_row_set( $resultset, $accessor );
        $held{$accessor} = _copied( $resultset->$accessor );
    }

    return \%held;
}

sub _put_back {
    my ( $resultset, $held ) = @_;

    return if !$resultset;

    for my $accessor ( keys %{$held} ) {
        _restore_row_set( $resultset->$accessor, $held->{$accessor} );
    }

    return;
}

sub _restore_row_set {
    my ( $live, $held ) = @_;

    if ( ref $held eq 'ARRAY' ) {
        @{$live} = @{$held};
        return;
    }
    %{$live} = %{$held};

    return;
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

1;
