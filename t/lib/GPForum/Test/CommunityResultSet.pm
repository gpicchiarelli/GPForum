package GPForum::Test::CommunityResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::CommunityRow;
use GPForum::Test::CommunitySearch;

our $VERSION = '0.001';

has created     => sub { return []; };
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

    return GPForum::Test::CommunitySearch->new( rows => \@rows );
}

sub _assert_bookmark_unique {
    my ( $self, $row ) = @_;

    if ( !$row->{bookmark_id} ) {
        return;
    }

    my $key = _composite_key($row);
    if ( !$key || !$self->rows->{$key} ) {
        return;
    }

    GPForum::Infrastructure::UniqueConflict->throw('bookmarks_user_target_key');
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
