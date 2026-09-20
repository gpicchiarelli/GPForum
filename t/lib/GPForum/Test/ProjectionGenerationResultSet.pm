package GPForum::Test::ProjectionGenerationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::ProjectionGenerationRow;
use GPForum::Test::ProjectionGenerationSearch;

our $VERSION = '0.001';

has rows        => sub { return {}; };
has created     => sub { return []; };
has last_query  => sub { return {}; };
has skip_search => 0;

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_generation_id_unique($row);
    $self->_assert_source_unique($row);
    my $generation = GPForum::Test::ProjectionGenerationRow->new(
        data      => $row,
        resultset => $self,
    );
    $self->rows->{ $row->{generation_id} } = $generation;
    push @{ $self->created }, $row;

    return $generation;
}

sub find {
    my ( $self, $generation_id ) = @_;

    return $self->rows->{$generation_id};
}

sub search {
    my ( $self, $query ) = @_;

    $self->last_query($query);

    my $skipped = $self->_skipped_search;
    if ($skipped) {
        return $skipped;
    }

    my @matched =
      grep { _row_matches( $_, $query ) } values %{ $self->rows };

    return GPForum::Test::ProjectionGenerationSearch->new( rows => \@matched );
}

sub _skipped_search {
    my ($self) = @_;

    if ( !$self->skip_search ) {
        return;
    }

    $self->skip_search( $self->skip_search - 1 );

    return GPForum::Test::ProjectionGenerationSearch->new( rows => [] );
}

sub _assert_generation_id_unique {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{generation_id} ) ) {
        return;
    }
    if ( $self->rows->{ $row->{generation_id} } ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'projection_generations_pkey');
    }

    return;
}

sub _assert_source_unique {
    my ( $self, $row ) = @_;

    if ( !_source_row($row) ) {
        return;
    }

    for my $existing ( values %{ $self->rows } ) {
        if ( _same_source( $existing->data, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_projection_generations_source_unique');
        }
    }

    return;
}

sub _source_row {
    my ($row) = @_;

    if ( !_has_text( $row->{projection_name} ) ) {
        return 0;
    }

    return _has_text( $row->{built_from_event_id} );
}

sub _same_source {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{projection_name}, $row->{projection_name} ) )
    {
        return 0;
    }

    return _same_text( $existing->{built_from_event_id},
        $row->{built_from_event_id} );
}

sub _row_matches {
    my ( $row, $query ) = @_;

    for my $field ( keys %{$query} ) {
        if ( !_same_text( $row->get_column($field), $query->{$field} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _same_text {
    my ( $stored, $candidate ) = @_;

    return ( $stored || q{} ) eq ( $candidate || q{} ) ? 1 : 0;
}

sub assert_active_unique {
    my ( $self, $row, $changes ) = @_;

    if ( !_activating($changes) ) {
        return;
    }

    my $projection = $row->get_column('projection_name');
    for my $other ( values %{ $self->rows } ) {
        if ( _other_active( $other, $row, $projection ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_projection_generations_one_active');
        }
    }

    return;
}

sub _activating {
    my ($changes) = @_;

    return $changes->{is_active} ? 1 : 0;
}

sub _other_active {
    my ( $other, $row, $projection ) = @_;

    if ( !$other ) {
        return 0;
    }
    if ( $other == $row ) {
        return 0;
    }
    if ( _text( $other->get_column('projection_name') ) ne _text($projection) )
    {
        return 0;
    }

    return $other->get_column('is_active') ? 1 : 0;
}

sub _text {
    my ($value) = @_;

    if ( defined $value ) {
        return $value;
    }

    return q{};
}

1;
