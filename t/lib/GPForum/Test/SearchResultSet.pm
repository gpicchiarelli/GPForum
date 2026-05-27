package GPForum::Test::SearchResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::SearchSearch;

our $VERSION = '0.001';

has created    => sub { return []; };
has deleted    => sub { return []; };
has last_attrs => undef;
has last_query => undef;
has rows       => sub { return []; };

sub find {
    my ( $self, $id ) = @_;

    for my $row ( @{ $self->rows } ) {
        return $row if _matches_id( $row, $id );
    }

    return;
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs($attrs);
    my @rows = grep { _matches_query( $_, $query ) } @{ $self->rows };

    return GPForum::Test::SearchSearch->new(
        resultset => $self,
        rows      => \@rows,
    );
}

sub update_or_create {
    my ( $self, $row ) = @_;

    my $existing = $self->_find_existing_document($row);
    if ($existing) {
        $existing->update($row);
        return $existing;
    }

    push @{ $self->rows },    GPForum::Test::SearchRow->new( data => $row );
    push @{ $self->created }, $row;

    return $row;
}

sub _find_existing_document {
    my ( $self, $row ) = @_;

    for my $candidate ( @{ $self->rows } ) {
        return $candidate
          if _same_document( $candidate, $row );
    }

    return;
}

sub _matches_id {
    my ( $row, $id ) = @_;

    return $row->get_column('thread_id') eq $id
      if defined $row->get_column('thread_id');
    return $row->get_column('post_id') eq $id
      if defined $row->get_column('post_id');

    return;
}

sub _same_document {
    my ( $candidate, $row ) = @_;

    return 1
      if defined $row->{search_document_id}
      && defined $candidate->get_column('search_document_id')
      && $candidate->get_column('search_document_id') eq
      $row->{search_document_id};

    return 1
      if defined $row->{entity_type}
      && defined $row->{entity_id}
      && ( $candidate->get_column('entity_type') || q{} ) eq $row->{entity_type}
      && ( $candidate->get_column('entity_id')   || q{} ) eq $row->{entity_id};

    return;
}

sub _matches_query {
    my ( $row, $query ) = @_;

    return 1 if !$query || !%{$query};

    if ( exists $query->{-and} ) {
        for my $part ( @{ $query->{-and} } ) {
            return if !_matches_query( $row, $part );
        }
        return 1;
    }

    if ( exists $query->{-or} ) {
        return 1 if grep { ref $_ ne 'HASH' } @{ $query->{-or} };
        return 1 if grep { _matches_query( $row, $_ ) } @{ $query->{-or} };
        return;
    }

    for my $field ( keys %{$query} ) {
        next   if $field =~ /\A [-]/msx;
        return if !_matches_field( $row, $field, $query->{$field} );
    }

    return 1;
}

sub _matches_field {
    my ( $row, $field, $expected ) = @_;

    my $actual = $row->get_column($field);

    return !defined $actual if !defined $expected;
    if ( ref $expected eq 'HASH' ) {
        return _matches_hash_operator( $actual, $expected );
    }

    return defined $actual && $actual eq $expected;
}

sub _matches_hash_operator {
    my ( $actual, $expected ) = @_;

    if ( exists $expected->{-in} ) {
        return grep { defined $actual && $actual eq $_ } @{ $expected->{-in} };
    }

    if ( exists $expected->{-like} ) {
        my $pattern = $expected->{-like};
        $pattern =~ s/%/.*/gmsx;
        return defined $actual && $actual =~ /\A $pattern \z/imsx ? 1 : 0;
    }

    if ( exists $expected->{'>='} ) {
        return defined $actual && $actual ge $expected->{'>='};
    }

    if ( exists $expected->{'<='} ) {
        return defined $actual && $actual le $expected->{'<='};
    }

    return 1;
}

1;
