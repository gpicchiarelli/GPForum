# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PageWindow;

use Const::Fast;
use English qw(-no_match_vars);
use GPForum::Infrastructure::Id;
use MIME::Base64 qw(decode_base64url encode_base64url);
use Mojo::Base -base, -signatures;
use v5.40;

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

__END__

=head1 NAME

GPForum::Service::Forum::PageWindow - Page size, keyset cursor and next-page cursor for a listing.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $window = GPForum::Service::Forum::PageWindow->new;
    my $plan   = $window->plan( { limit => $limit, after => $after } );

    # Fetch $plan->{fetch_rows} rows past $plan->{after}, then:
    my $page = $window->page( \@rows, $plan->{limit},
        [qw(created_at item_id)] );
    # { items => [...], has_next => 1, next_cursor => '...' }

=head1 DESCRIPTION

The shared arithmetic of a keyset-paged list. C<plan> bounds the requested
page size and decodes the C<after> cursor from the URL; the reader then
fetches one row more than the page, and C<page> uses that extra row to tell
whether there is a next page and, if so, mints its cursor from the last row
kept.

A cursor is base64url of C<sort_value|id>. Because it comes from the URL,
only a position or a timestamp and a uuid may reach SQL; anything else is
treated as no cursor, so the first page is shown. A malformed C<?after=>
used to reach PostgreSQL and fail the request on an invalid timestamp.

=head1 SUBROUTINES/METHODS

=head2 plan

Takes a hash reference with optional C<limit> and C<after>. Returns
C<< { limit, fetch_rows, after } >>: C<limit> is 25 when missing or not a
whole number, at least 1 and at most 100; C<fetch_rows> is C<limit + 1>;
C<after> is C<< { sort_value, id } >> decoded from the cursor, or undef
when there is none or it is not acceptable.

=head2 page

Takes the fetched rows (an array reference), the page limit and the cursor
columns (an array reference of column names). Returns
C<< { items, has_next, next_cursor } >>: when there are more rows than the
limit, the extra row is dropped, C<has_next> is 1 and C<next_cursor> encodes
the cursor columns of the last item kept, read with C<get_column>;
otherwise C<has_next> is 0 and C<next_cursor> undef.

=head2 acceptable_cursor

Class method. Takes a sort value and an id. Returns 1 when the id is a uuid
and the sort value is a position (up to 18 digits) or a timestamp as
PostgreSQL or ISO 8601 writes it; 0 otherwise.

=head1 DIAGNOSTICS

None. An undecodable or unacceptable cursor is ignored rather than
reported; C<page> dies only if a row cannot C<get_column>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Id>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
