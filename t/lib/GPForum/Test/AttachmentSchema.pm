# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::AttachmentSchema;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'GPForum::Test::TransactionalSchema';

our $VERSION = '0.001';

# Row sets a fake resultset keeps. This double owns no rows itself, so a
# rollback - of the whole transaction or of a savepoint - has to reach into
# the resultsets it was handed.
const my @ROW_SET_ACCESSOR => qw(created created_objects rows);

has resultsets => sub { return {}; };

# Nothing on the schema holds rows; snapshot and restore extend the base's
# instead of declaring accessors here.
sub storage_accessors {
    return ();
}

sub resultset {
    my ( $self, $name ) = @_;

    my $resultset = $self->resultsets->{$name};
    $self->_adopt($resultset);

    return $resultset;
}

sub snapshot {
    my ($self) = @_;

    my $snapshot = $self->SUPER::snapshot;
    $snapshot->{resultsets} =
      [ map { _row_sets($_) } values %{ $self->resultsets } ];

    return $snapshot;
}

sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    for my $entry ( @{ $snapshot->{resultsets} || [] } ) {
        _restore_row_set($entry);
    }

    return;
}

# A resultset can only ask about the aborted transaction if it can reach the
# schema, and the tests build the resultsets before the schema that holds
# them. Wire the backlink the first time one is handed out.
sub _adopt {
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

sub _row_sets {
    my ($resultset) = @_;

    if ( !ref $resultset ) {
        return ();
    }

    return map { _row_set_entry( $resultset, $_ ) } @ROW_SET_ACCESSOR;
}

sub _row_set_entry {
    my ( $resultset, $accessor ) = @_;

    if ( !$resultset->can($accessor) ) {
        return ();
    }
    my $held = $resultset->$accessor;
    if ( !ref $held ) {
        return ();
    }

    return {
        accessor  => $accessor,
        held      => _copied($held),
        resultset => $resultset,
    };
}

sub _copied {
    my ($held) = @_;

    return [ @{$held} ] if ref $held eq 'ARRAY';

    return { %{$held} };
}

# Copy back into the live container rather than replacing it, so a test that
# already holds the arrayref or hashref sees the rollback too.
sub _restore_row_set {
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
