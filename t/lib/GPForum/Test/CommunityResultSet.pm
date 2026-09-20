package GPForum::Test::CommunityResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::CommunityRow;
use GPForum::Test::CommunitySearch;

our $VERSION = '0.001';

has created     => sub { return []; };
has deleted     => sub { return []; };
has find_misses => 0;
has rows        => sub { return {}; };
has last_query  => sub { return {}; };
has last_attrs  => sub { return {}; };

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_bookmark_id_unique($row);
    $self->_assert_bookmark_unique($row);
    $self->_assert_reputation_id_unique($row);
    $self->_assert_reputation_unique($row);
    $self->_assert_snapshot_unique($row);
    $self->_assert_mention_id_unique($row);
    $self->_assert_mention_unique($row);
    $self->_assert_feed_unique($row);
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
    my ( $self, $query ) = @_;

    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    my $key = ref $query eq 'HASH' ? _composite_key($query) : $query;

    return $self->rows->{$key};
}

sub search {
    my ( $self, $query, $attrs ) = @_;

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

    return 0 if !_item_key($query);

    my @removed = _unique_matching_rows( $self->rows, $query );
    $self->rows( _rows_without( $self->rows, \@removed ) );
    push @{ $self->deleted }, @removed;

    return scalar @removed;
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
