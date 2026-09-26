# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchResultSet;

use strict;
use warnings;

use Mojo::Base -base;
use Scalar::Util qw(looks_like_number);

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::SearchRow;
use GPForum::Test::SearchSearch;

our $VERSION = '0.001';

has created     => sub { return []; };
has deleted     => sub { return []; };
has last_attrs  => undef;
has last_query  => undef;
has rows        => sub { return []; };
has schema      => undef;
has skip_search => 0;

sub find {
    my ( $self, $id ) = @_;

    $self->_assert_usable;
    for my $row ( @{ $self->rows } ) {
        return $row if _matches_id( $row, $id );
    }

    return;
}

# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->_assert_usable;
    $self->last_query($query);
    $self->last_attrs($attrs);

    my $skipped = $self->_skipped_search;
    if ($skipped) {
        return $skipped;
    }

    my @rows = _ordered_page( $attrs,
        grep { _matches_query( $_, $query ) } @{ $self->rows } );

    return GPForum::Test::SearchSearch->new(
        resultset => $self,
        rows      => \@rows,
    );
}

sub update_or_create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    my $existing = $self->_find_existing_document($row);
    if ($existing) {
        $existing->update($row);
        return $existing;
    }

    return $self->create($row);
}

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    $self->_assert_document_unique($row);
    push @{ $self->rows },    GPForum::Test::SearchRow->new( data => $row );
    push @{ $self->created }, $row;

    return $row;
}

sub _skipped_search {
    my ($self) = @_;

    if ( !$self->skip_search ) {
        return;
    }

    $self->skip_search( $self->skip_search - 1 );

    return GPForum::Test::SearchSearch->new( rows => [] );
}

# A unique violation is what puts a real transaction into the aborted state.
# Marking it here is what makes this double able to fail a recovery path that
# would be unreachable against PostgreSQL.
sub _assert_document_unique {
    my ( $self, $row ) = @_;

    my $ok = eval {
        $self->_run_document_constraints($row);
        1;
    };
    if ( !$ok ) {
        my $failure = $@;
        $self->_mark_aborted;
        die $failure;    ## no critic (ErrorHandling::RequireCarping)
    }

    return;
}

sub _run_document_constraints {
    my ( $self, $row ) = @_;

    if ( !$self->_find_existing_document($row) ) {
        return;
    }

    GPForum::Infrastructure::UniqueConflict->throw(
        'search_documents_entity_key');

    return;
}

sub _assert_usable {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('assert_transaction_usable') ) {
        $schema->assert_transaction_usable;
    }

    return;
}

sub _mark_aborted {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('mark_transaction_aborted') ) {
        $schema->mark_transaction_aborted;
    }

    return;
}

# The rows this double holds live here, not on the schema, so a savepoint
# rollback restores them through these two.
sub snapshot_rows {
    my ($self) = @_;

    return {
        created => [ @{ $self->created } ],
        deleted => [ @{ $self->deleted } ],
        rows    => [ @{ $self->rows } ],
    };
}

sub restore_rows {
    my ( $self, $held ) = @_;

    @{ $self->created } = @{ $held->{created} || [] };
    @{ $self->deleted } = @{ $held->{deleted} || [] };
    @{ $self->rows }    = @{ $held->{rows}    || [] };

    return;
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

    if ( _id_column_matches( $row, 'thread_id', $id ) ) {
        return 1;
    }
    if ( _id_column_matches( $row, 'post_id', $id ) ) {
        return 1;
    }

    return;
}

sub _id_column_matches {
    my ( $row, $name, $id ) = @_;

    my $value = $row->get_column($name);
    if ( !defined $value ) {
        return;
    }

    return $value eq $id ? 1 : 0;
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

    # A joined table's column, such as thread.moderation_state for a post,
    # is read from the related row when the double carries one.
    if ( $field =~ /\A (\w+) [.] (\w+) \z/msx && $1 ne 'me' ) {
        my ( $relation, $column ) = ( $1, $2 );
        my $related = $row->can($relation) ? $row->$relation : undef;
        return _matches_field( $related, $column, $expected ) if $related;
    }

    my $actual = $row->get_column( _base_column($field) );

    return !defined $actual if !defined $expected;
    if ( ref $expected eq 'HASH' ) {
        return _matches_hash_operator( $actual, $expected );
    }
    if ( ref $expected eq 'REF' ) {
        return _matches_any( $actual, ${$expected} );
    }

    return defined $actual && $actual eq $expected;
}

# column = ANY(?), with the array bound as DBIx::Class takes it:
# \[ '= ANY(?)', [ {} => \@values ] ].
sub _matches_any {
    my ( $actual, $literal ) = @_;

    my ( $sql, $bind ) = @{$literal};
    return 0 if $sql !~ /\A = [ ] ANY [(]/msx;

    return grep { defined $actual && $actual eq $_ } @{ $bind->[1] };
}

sub _matches_hash_operator {
    my ( $actual, $expected ) = @_;

    if ( exists $expected->{-in} ) {
        return grep { defined $actual && $actual eq $_ } @{ $expected->{-in} };
    }

    if ( exists $expected->{q{>}} ) {
        return defined $actual && _compare( $actual, $expected->{q{>}} ) > 0;
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

# order_by => { -asc => column } and rows, the keyset page a batch reads.
# Any other ordering is left as the rows were given.
sub _ordered_page {
    my ( $attrs, @rows ) = @_;

    my $order = ref $attrs eq 'HASH' ? $attrs->{order_by} : undef;
    if ( ref $order eq 'HASH' && defined $order->{-asc} && !ref $order->{-asc} )
    {
        my $column = _base_column( $order->{-asc} );
        @rows =
          sort { _compare( $a->get_column($column), $b->get_column($column) ) }
          @rows;
    }
    my $limit = ref $attrs eq 'HASH' ? $attrs->{rows} : undef;
    if ( $limit && @rows > $limit ) {
        splice @rows, $limit;
    }

    return @rows;
}

sub _compare {
    my ( $one, $other ) = @_;

    return $one <=> $other
      if looks_like_number($one) && looks_like_number($other);

    return $one cmp $other;
}

sub _base_column {
    my ($field) = @_;

    ( my $column = $field ) =~ s/\A me [.]//msx;

    return $column;
}

1;
