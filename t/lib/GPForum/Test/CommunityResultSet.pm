# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CommunityResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::CommunityRow;
use GPForum::Test::CommunitySearch;

our $VERSION = '0.001';

has created         => sub { return []; };
has deleted         => sub { return []; };
has find_misses     => 0;
has rows            => sub { return {}; };
has last_query      => sub { return {}; };
has last_attrs      => sub { return {}; };
has last_find_attrs => undef;
has schema          => undef;

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    $self->_assert_unique_constraints($row);
    my $object = GPForum::Test::CommunityRow->new( data => $row );
    push @{ $self->created }, $row;
    $self->_store_row( $row, $object );

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

    my $existing = $self->find($row);
    if ($existing) {
        return $existing->update($row);
    }

    return $self->create($row);
}

sub find {
    my ( $self, $query, $attributes ) = @_;

    $self->_assert_usable;
    $self->last_find_attrs($attributes);
    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    my $key = ref $query eq 'HASH' ? _composite_key($query) : $query;

    return $self->rows->{$key};
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
    $self->last_attrs( $attrs || {} );

    my %seen;
    my @rows = grep { !$seen{ 0 + $_ }++ } values %{ $self->rows };

    return GPForum::Test::CommunitySearch->new(
        query     => $query,
        resultset => $self,
        rows      => \@rows,
    );
}

sub delete_matching {
    my ( $self, $query ) = @_;

    $self->_assert_usable;
    return 0 if !_item_key($query);

    my @removed = _unique_matching_rows( $self->rows, $query );
    $self->rows( _rows_without( $self->rows, \@removed ) );
    push @{ $self->deleted }, @removed;

    return scalar @removed;
}

# A unique violation is what puts a real transaction into the aborted state.
# Marking it here is what makes this double able to fail a recovery path that
# would be unreachable against PostgreSQL.
sub _assert_unique_constraints {
    my ( $self, $row ) = @_;

    my $ok = eval {
        $self->_run_unique_constraints($row);
        1;
    };
    if ( !$ok ) {
        my $failure = $@;
        $self->_mark_aborted;
        die $failure;    ## no critic (ErrorHandling::RequireCarping)
    }

    return;
}

sub _run_unique_constraints {
    my ( $self, $row ) = @_;

    $self->_assert_bookmark_id_unique($row);
    $self->_assert_bookmark_unique($row);
    $self->_assert_reputation_id_unique($row);
    $self->_assert_reputation_unique($row);
    $self->_assert_snapshot_unique($row);
    $self->_assert_mention_id_unique($row);
    $self->_assert_mention_unique($row);
    $self->_assert_feed_unique($row);

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
        rows    => { %{ $self->rows } },
    };
}

sub restore_rows {
    my ( $self, $held ) = @_;

    @{ $self->created } = @{ $held->{created} || [] };
    @{ $self->deleted } = @{ $held->{deleted} || [] };
    $self->rows( { %{ $held->{rows} || {} } } );

    return;
}

sub _assert_bookmark_id_unique {
    my ( $self, $row ) = @_;

    if ( !$row->{bookmark_id} ) {
        return;
    }
    if ( $self->rows->{ $row->{bookmark_id} } ) {
        GPForum::Infrastructure::UniqueConflict->throw('bookmarks_pkey');
    }

    return;
}

sub _assert_bookmark_unique {
    my ( $self, $row ) = @_;

    if ( !$row->{bookmark_id} ) {
        return;
    }

    my $key = _composite_key($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'bookmarks_user_target_key');
    }

    return;
}

sub _assert_reputation_id_unique {
    my ( $self, $row ) = @_;

    if ( !_reputation_source($row) ) {
        return;
    }
    if ( $self->rows->{ $row->{reputation_event_id} } ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'reputation_events_pkey');
    }

    return;
}

sub _assert_reputation_unique {
    my ( $self, $row ) = @_;

    if ( !_reputation_source($row) ) {
        return;
    }

    my $key = _composite_key($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'idx_reputation_events_source_unique');
    }

    return;
}

sub _assert_snapshot_unique {
    my ( $self, $row ) = @_;

    if ( !_snapshot_row($row) ) {
        return;
    }
    if ( $self->rows->{ $row->{user_id} } ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'trust_score_snapshots_pkey');
    }

    return;
}

sub _assert_mention_id_unique {
    my ( $self, $row ) = @_;

    if ( !$row->{mention_id} ) {
        return;
    }
    if ( $self->rows->{ $row->{mention_id} } ) {
        GPForum::Infrastructure::UniqueConflict->throw('mentions_pkey');
    }

    return;
}

sub _assert_mention_unique {
    my ( $self, $row ) = @_;

    if ( !$row->{mention_id} ) {
        return;
    }

    my $key = _composite_key($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'mentions_source_user_key');
    }

    return;
}

sub _assert_feed_unique {
    my ( $self, $row ) = @_;

    if ( !_feed_item_row($row) ) {
        return;
    }

    my $key = _composite_key($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw('user_feed_items_pkey');
    }

    return;
}

sub _feed_item_row {
    my ($row) = @_;

    if ( !exists $row->{visibility_version} ) {
        return;
    }
    if ( !defined $row->{user_id} ) {
        return;
    }
    if ( !defined $row->{item_type} ) {
        return;
    }
    if ( !defined $row->{item_id} ) {
        return;
    }

    return 1;
}

sub _reputation_source {
    my ($row) = @_;

    if ( !$row->{reputation_event_id} ) {
        return;
    }

    return
         defined $row->{source_id}
      && defined $row->{source_type}
      && defined $row->{user_id} ? 1 : 0;
}

sub _snapshot_row {
    my ($row) = @_;

    if ( $row->{reputation_event_id} ) {
        return 0;
    }
    if ( !defined $row->{calculated_at} ) {
        return 0;
    }
    if ( !defined $row->{score} ) {
        return 0;
    }

    return _has_text( $row->{user_id} );
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub _store_row {
    my ( $self, $row, $object ) = @_;

    for my $key ( _row_keys($row) ) {
        $self->rows->{$key} = $object;
    }

    return;
}

sub _row_keys {
    my ($row) = @_;

    return grep { defined && length } (
        @{$row}{
            qw(
              bookmark_id
              mention_id
              id
              reputation_event_id
              user_id
              username
            )
        },
        _composite_key($row),
    );
}

sub _item_key {
    my ($query) = @_;

    return defined $query->{item_type}
      && defined $query->{item_id} ? 1 : 0;
}

sub _unique_matching_rows {
    my ( $rows, $query ) = @_;

    my ( %seen, @removed );
    for my $row ( values %{$rows} ) {
        if ( _seen_row( \%seen, $row ) ) {
            next;
        }
        if ( _row_matches_item( $row, $query ) ) {
            push @removed, $row;
        }
    }

    return @removed;
}

sub _seen_row {
    my ( $seen, $row ) = @_;

    if ( !$row ) {
        return 1;
    }
    if ( $seen->{ 0 + $row }++ ) {
        return 1;
    }

    return 0;
}

sub _rows_without {
    my ( $rows, $removed ) = @_;

    my %drop = map { 0 + $_ => 1 } @{$removed};
    my %keep;
    for my $key ( keys %{$rows} ) {
        my $row = $rows->{$key};
        if ( _kept_row( $row, \%drop ) ) {
            $keep{$key} = $row;
        }
    }

    return \%keep;
}

sub _kept_row {
    my ( $row, $drop ) = @_;

    if ( !$row ) {
        return 0;
    }
    if ( $drop->{ 0 + $row } ) {
        return 0;
    }

    return 1;
}

sub _row_matches_item {
    my ( $row, $query ) = @_;

    my $data = _row_data($row);
    if ( !_same_field( $data, $query, 'item_type' ) ) {
        return 0;
    }
    if ( !_same_field( $data, $query, 'item_id' ) ) {
        return 0;
    }

    return 1;
}

sub _row_data {
    my ($row) = @_;

    if ( $row->can('data') ) {
        return $row->data;
    }

    return $row;
}

sub _same_field {
    my ( $data, $query, $field ) = @_;

    if ( _text( $data->{$field} ) ne $query->{$field} ) {
        return 0;
    }

    return 1;
}

sub _text {
    my ($value) = @_;

    if ( defined $value ) {
        return $value;
    }

    return q{};
}

sub _composite_key {
    my ($row) = @_;

    return join q{:}, grep { defined } @{$row}{
        qw(
          user_id target_type target_id item_type item_id
          source_type source_id mentioned_user_id
        )
    };
}

1;
