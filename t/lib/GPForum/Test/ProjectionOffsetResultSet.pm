# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ProjectionOffsetResultSet;

use Mojo::Base -base;
use v5.40;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::ProjectionOffsetRow;

our $VERSION = '0.001';

has rows        => sub { return {}; };
has writes      => sub { return []; };
has find_misses => 0;

# The index a second offset of one projection collides on; a test can name
# another.
has conflict_constraint => 'projection_offsets_pkey';

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_offset_unique($row);
    push @{ $self->writes }, $row;
    $self->rows->{ $row->{projection_name} } =
      GPForum::Test::ProjectionOffsetRow->new( data => { %{$row} } );

    return $self->rows->{ $row->{projection_name} };
}

sub update_or_create {
    my ( $self, $row ) = @_;

    push @{ $self->writes }, $row;
    $self->rows->{ $row->{projection_name} } =
      GPForum::Test::ProjectionOffsetRow->new( data => $row );

    return $self->rows->{ $row->{projection_name} };
}

sub find {
    my ( $self, $projection_name ) = @_;

    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    return $self->rows->{$projection_name};
}

sub _assert_offset_unique {
    my ( $self, $row ) = @_;

    if ( $self->rows->{ $row->{projection_name} } ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            $self->conflict_constraint );
    }

    return;
}

1;
