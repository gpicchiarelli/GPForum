package GPForum::Test::OutboxCreateResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;

our $VERSION = '0.001';

has created     => sub { return []; };
has find_misses => 0;
has rows        => sub { return {}; };

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_letter_id_unique($row);
    $self->_assert_source_unique($row);
    $self->rows->{ _source_key($row) } = $row;
    push @{ $self->created }, $row;

    return $row;
}

sub find {
    my ( $self, $query ) = @_;

    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    return $self->rows->{ _source_key($query) };
}

sub _assert_letter_id_unique {
    my ( $self, $row ) = @_;

    my $letter_id = $row->{dead_letter_id};
    if ( !_has_text($letter_id) ) {
        return;
    }
    if ( _letter_id_taken( $self, $letter_id ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('dead_letters_pkey');
    }

    return;
}

sub _letter_id_taken {
    my ( $self, $letter_id ) = @_;

    for my $existing ( @{ $self->created } ) {
        if ( _same_text( $existing->{dead_letter_id}, $letter_id ) ) {
            return 1;
        }
    }

    return 0;
}

sub _assert_source_unique {
    my ( $self, $row ) = @_;

    my $key = _source_key($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'idx_dead_letters_source_unique');
    }

    return;
}

sub _source_key {
    my ($row) = @_;

    my $source_id    = $row->{source_id};
    my $source_table = $row->{source_table};
    if ( !defined $source_id || !defined $source_table ) {
        return q{};
    }

    return join q{:}, $source_table, $source_id;
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _same_text {
    my ( $expected, $actual ) = @_;

    return ( $expected || q{} ) eq ( $actual || q{} ) ? 1 : 0;
}

1;
