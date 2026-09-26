# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PageWindow;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use GPForum::Infrastructure::Id;
use MIME::Base64 qw(decode_base64url encode_base64url);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 25;
const my $MAX_LIMIT     => 100;
const my $MIN_LIMIT     => 1;
const my $CURSOR_PARTS  => 2;

# A position, or a timestamp as PostgreSQL or ISO 8601 writes it.
const my $POSITION => qr{\d{1,18}}msx;
const my $DAY      => qr{\d{4} - \d\d - \d\d}msx;
const my $TIME     => qr{\d\d : \d\d : \d\d (?: [.] \d{1,6} )?}msx;
const my $ZONE     => qr{Z | [+-] \d\d (?: :? \d\d )?}msx;
const my $SORT_VALUE =>
  qr{\A (?: $POSITION | $DAY [T ] $TIME (?: $ZONE )? ) \z}msx;

sub plan ( $self, $input ) {
    my $limit = _bounded_limit( $input->{limit} );
    my $after = _decode_cursor( $input->{after} );

    return {
        limit      => $limit,
        fetch_rows => $limit + 1,
        after      => $after,
    };
}

sub page ( $self, $rows, $limit, $cursor_columns ) {
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

sub _bounded_limit ($requested) {
    return $DEFAULT_LIMIT if !defined $requested;
    return $DEFAULT_LIMIT if $requested !~ /\A [[:digit:]]+ \z/msx;
    return $MIN_LIMIT     if $requested < $MIN_LIMIT;
    return $MAX_LIMIT     if $requested > $MAX_LIMIT;

    return int $requested;
}

sub _encode_cursor ( $row, $columns ) {
    my $undefined;
    return $undefined if !$row;

    return encode_base64url( join q{|},
        map { $row->get_column($_) } @{$columns} );
}

# A cursor comes from the URL: only a timestamp or a position, and a uuid,
# may reach SQL. Anything else shows the first page. It used to reach
# PostgreSQL -- `?after=anything` failed the request on an invalid
# timestamp, and anyone could fill the error log that way.
sub acceptable_cursor ( $class, $sort_value, $id ) {
    return 0 if !GPForum::Infrastructure::Id->is_uuid($id);
    return 0 if !defined $sort_value;

    return $sort_value =~ $SORT_VALUE ? 1 : 0;
}

sub _decode_cursor ($cursor) {
    my $undefined;
    return $undefined if !defined $cursor || !length $cursor;

    my $decoded = eval { decode_base64url($cursor) };
    return $undefined if $EVAL_ERROR || !defined $decoded;

    my @parts = split /[|]/msx, $decoded, $CURSOR_PARTS;
    return $undefined if @parts != $CURSOR_PARTS;
    return $undefined if !__PACKAGE__->acceptable_cursor(@parts);

    return {
        sort_value => $parts[0],
        id         => $parts[1],
    };
}

1;
