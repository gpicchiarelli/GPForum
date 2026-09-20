package GPForum::Test::EngineeringCorrectness::ResultSet;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

use GPForum::Test::EngineeringCorrectness::Row;

our $VERSION = '0.001';

has matches => undef;
has name    => undef;
has schema  => undef;

sub create {
    my ( $self, $row ) = @_;

    croak 'injected create failure for ' . $self->name . ': statement timeout'
      if ( $self->schema->fail_resultset || q{} ) eq $self->name;
    $self->_assert_unique_post_position($row);

    my $stored = { %{$row} };
    push @{ $self->schema->created_for( $self->name ) }, $stored;

    return GPForum::Test::EngineeringCorrectness::Row->new( data => $stored );
}

sub find {
    my ( $self, $query ) = @_;

    if ( !defined $query ) {
        return;
    }
    if ( !ref $query ) {
        return $self->_row_for_id($query);
    }

    return $self->_row_for_query($query);
}

sub search {
    my ( $self, $query ) = @_;

    my @matched =
      grep { $self->_row_matches( $_, $query || {} ) }
      @{ $self->schema->created_for( $self->name ) };

    return GPForum::Test::EngineeringCorrectness::ResultSet->new(
        matches => \@matched,
        name    => $self->name,
        schema  => $self->schema,
    );
}

sub single {
    my ($self) = @_;

    my $row = $self->_first_match;
    if ( !$row ) {
        return;
    }

    return GPForum::Test::EngineeringCorrectness::Row->new( data => $row );
}

sub all_rows {
    my ($self) = @_;

    my $matches = $self->matches;
    if ( !$matches ) {
        return;
    }

    return
      map { GPForum::Test::EngineeringCorrectness::Row->new( data => $_ ) }
      @{$matches};
}

BEGIN {
    *all = \&all_rows;
}

sub _row_for_id {
    my ( $self, $id ) = @_;

    return $self->_row_for_query( { _id_column( $self->name ) => $id } );
}

sub _row_for_query {
    my ( $self, $query ) = @_;

    for my $stored ( @{ $self->schema->created_for( $self->name ) } ) {
        if ( $self->_row_matches( $stored, $query ) ) {
            return GPForum::Test::EngineeringCorrectness::Row->new(
                data => $stored );
        }
    }

    return;
}

sub _first_match {
    my ($self) = @_;

    my $matches = $self->matches;
    if ( !$matches ) {
        return;
    }

    return $matches->[0];
}

sub _row_matches {
    my ( undef, $stored, $query ) = @_;

    for my $field ( keys %{$query} ) {
        if ( !_field_matches( $stored->{$field}, $query->{$field} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _field_matches {
    my ( $stored_value, $query_value ) = @_;

    if ( ref $query_value eq 'HASH' && exists $query_value->{'-in'} ) {
        return _in_list( $stored_value, $query_value->{'-in'} );
    }

    return _same_value( $stored_value, $query_value );
}

sub _in_list {
    my ( $stored_value, $list ) = @_;

    for my $item ( @{$list} ) {
        if ( _same_value( $stored_value, $item ) ) {
            return 1;
        }
    }

    return 0;
}

sub _id_column {
    my ($name) = @_;

    $name =~ s/([[:lower:]])([[:upper:]])/${1}_${2}/msxg;

    return lc $name . '_id';
}

sub _same_value {
    my ( $stored_value, $query_value ) = @_;

    return ( $stored_value // q{} ) eq ( $query_value // q{} ) ? 1 : 0;
}

sub _assert_unique_post_position {
    my ( $self, $row ) = @_;

    return if !$self->schema->unique_post_positions;
    return if $self->name ne 'Post';

    my $key = join q{:}, @{$row}{qw(thread_id position)};
    croak 'duplicate post position'
      if $self->schema->post_positions->{$key};

    $self->schema->post_positions->{$key} = 1;

    return;
}

1;
