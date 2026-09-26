package GPForum::Test::ThreadKeysetResultSet;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::ForumReadResultSet';

use GPForum::Test::ForumReadSearch;

our $VERSION = '0.001';

# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query, $attributes ) = @_;

    my $matched = $self->SUPER::search( $query, $attributes );

    return GPForum::Test::ForumReadSearch->new(
        rows => _limited( _ordered( $matched->rows ), $attributes ), );
}

sub _ordered {
    my ($rows) = @_;

    return [ sort { _compare( $a, $b ) } @{$rows} ];
}

sub _compare {
    my ( $row_a, $row_b ) = @_;

    return _pinned($row_b) <=> _pinned($row_a)
      || _value( $row_b, 'last_activity_at' )
      cmp _value( $row_a, 'last_activity_at' )
      || _value( $row_b, 'thread_id' ) cmp _value( $row_a, 'thread_id' );
}

sub _limited {
    my ( $rows, $attributes ) = @_;

    my $limit = ref $attributes eq 'HASH' ? $attributes->{rows} : undef;
    if ( !$limit || @{$rows} <= $limit ) {
        return $rows;
    }

    return [ @{$rows}[ 0 .. $limit - 1 ] ];
}

sub _pinned {
    my ($row) = @_;

    return $row->get_column('pinned') ? 1 : 0;
}

sub _value {
    my ( $row, $column ) = @_;

    my $value = $row->get_column($column);

    return defined $value ? $value : q{};
}

1;
