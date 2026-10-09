# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::EngineeringCorrectness::ResultSet;

use Carp qw(carp croak);
use Mojo::Base -base;
use v5.40;

use Mojo::Loader qw(load_class);

use GPForum::Test::Query;
use GPForum::Test::UniqueKey;

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
    my ( $self, $query, @rest ) = @_;

    if ( !defined $query ) {
        return undef;
    }
    if ( !ref $query ) {
        return $self->_row_for_id($query);
    }
    return $self->_row_for_unique_key( $query, @rest ) if $self->_result_class;

    return $self->_row_for_query($query);
}

# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query, $attributes ) = @_;

    my @matched =
      grep { $self->_row_matches( $_, $query || {} ) }
      @{ $self->schema->created_for( $self->name ) };
    @matched = GPForum::Test::Query::ordered_rows( \@matched, $attributes );
    @matched = GPForum::Test::Query::windowed_rows( \@matched, $attributes );

    return GPForum::Test::EngineeringCorrectness::ResultSet->new(
        matches => \@matched,
        name    => $self->name,
        schema  => $self->schema,
    );
}

# One row or undef; several rows are DBIx::Class's warning and the first.
sub single {
    my ($self) = @_;

    my $row = $self->_first_match;
    if ( !$row ) {
        return undef;
    }
    if ( @{ $self->matches } > 1 ) {
        carp 'Query returned more than one row.  SQL that returns multiple '
          . 'rows is DEPRECATED for ->find and ->single';
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

# The source's real unique keys decide what a find by condition reads, as in
# DBIx::Class: the other columns of the condition are dropped. A find by value
# keeps the fixtures' <source>_id convention, which for User is not the real
# primary key (id).
sub _row_for_unique_key {
    my ( $self, @arguments ) = @_;

    my $alternatives =
      GPForum::Test::UniqueKey::find_conditions( $self->_result_class,
        @arguments );
    my @found =
      grep { GPForum::Test::UniqueKey::matches( $_, $alternatives ) }
      @{ $self->schema->created_for( $self->name ) };

    return GPForum::Test::EngineeringCorrectness::ResultSet->new(
        matches => \@found,
        name    => $self->name,
        schema  => $self->schema,
    )->single;
}

sub _result_class {
    my ($self) = @_;

    my $class = 'GPForum::Schema::Result::' . ( $self->name // q{} );

    return load_class($class) ? undef : $class;
}

sub _row_for_query {
    my ( $self, $query ) = @_;

    for my $stored ( @{ $self->schema->created_for( $self->name ) } ) {
        if ( $self->_row_matches( $stored, $query ) ) {
            return GPForum::Test::EngineeringCorrectness::Row->new(
                data => $stored );
        }
    }

    return undef;
}

sub count {
    my ($self) = @_;

    return scalar @{ $self->matches || [] };
}

sub _first_match {
    my ($self) = @_;

    my $matches = $self->matches;
    if ( !$matches ) {
        return undef;
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
