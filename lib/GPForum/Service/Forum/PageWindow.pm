package GPForum::Service::Forum::PageWindow;

use strict;
use warnings;

use Const::Fast;
use MIME::Base64 qw(decode_base64url encode_base64url);
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 25;
const my $MAX_LIMIT     => 100;
const my $MIN_LIMIT     => 1;
const my $CURSOR_PARTS  => 2;

sub plan {
    my ( $self, $input ) = @_;

    my $limit = _bounded_limit( $input->{limit} );
    my $after = _decode_cursor( $input->{after} );

    return {
        limit      => $limit,
        fetch_rows => $limit + 1,
        after      => $after,
    };
}

sub page {
    my ( $self, $rows, $limit, $cursor_columns ) = @_;

    my @items    = @{$rows};
    my $has_next = @items > $limit ? 1 : 0;

    if ($has_next) {
        pop @items;
    }

    return {
        items       => \@items,
        has_next    => $has_next,
        next_cursor => $has_next
        ? _encode_cursor( $items[-1], $cursor_columns )
        : undef,
    };
}

sub _bounded_limit {
    my ($requested) = @_;

    return $DEFAULT_LIMIT if !defined $requested;
    return $MIN_LIMIT     if $requested < $MIN_LIMIT;
    return $MAX_LIMIT     if $requested > $MAX_LIMIT;

    return int $requested;
}

sub _encode_cursor {
    my ( $row, $columns ) = @_;

    return if !$row;

    return encode_base64url( join q{|},
        map { $row->get_column($_) } @{$columns} );
}

sub _decode_cursor {
    my ($cursor) = @_;

    return if !defined $cursor || !length $cursor;

    my @parts = split /[|]/msx, decode_base64url($cursor), $CURSOR_PARTS;

    return {
        sort_value => $parts[0],
        id         => $parts[1],
    };
}

1;
