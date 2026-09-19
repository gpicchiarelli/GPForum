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

    $self->_assert_bookmark_unique($row);
    my $object = GPForum::Test::CommunityRow->new( data => $row );
    push @{ $self->created }, $row;
    $self->_store_row( $row, $object );

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

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
        next if !$row || $seen{ 0 + $row }++;
        push @removed, $row if _row_matches_item( $row, $query );
    }

    return @removed;
}

sub _rows_without {
    my ( $rows, $removed ) = @_;

    my %drop = map { 0 + $_ => 1 } @{$removed};
    my %keep;
    for my $key ( keys %{$rows} ) {
        my $row = $rows->{$key};
        $keep{$key} = $row if $row && !$drop{ 0 + $row };
    }

    return \%keep;
}

sub _row_matches_item {
    my ( $row, $query ) = @_;

    my $data = $row->can('data') ? $row->data : $row;

    return 0 if ( $data->{item_type} || q{} ) ne $query->{item_type};
    return 0 if ( $data->{item_id}   || q{} ) ne $query->{item_id};

    return 1;
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
