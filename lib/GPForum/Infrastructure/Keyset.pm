# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::Keyset;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my %STRICT  => ( asc => q{>},  desc => q{<} );
const my %BOUNDED => ( asc => q{>=}, desc => q{<=} );

# Adds to $query the rows past a keyset cursor, for a list ordered by
# (sort, id), both ascending or both descending.
#
# The lexicographic comparison is written the way SQL::Abstract can: sort
# past the cursor, or equal to it with the id past. PostgreSQL cannot use an
# index for that OR, so it is joined by the bound it implies on the sort
# column alone, which the index answers. Without the bound, a deep page read
# every row before it: page 800 of a 50,000-post thread filtered 39,008 rows
# and took 5.7 ms; with it, it reads five, in 0.03 ms.
sub after ( $class, $query, $cursor ) {
    my $direction = $cursor->{direction} // 'asc';
    croak "unknown keyset direction $direction"
      if !exists $STRICT{$direction};

    my ( $sort, $sort_value ) = @{ $cursor->{sort} };
    my ( $id,   $id_value )   = @{ $cursor->{id} };
    croak "the query already constrains $sort" if exists $query->{$sort};
    croak 'the query already has an -or'       if exists $query->{-or};

    $query->{$sort} = { $BOUNDED{$direction} => $sort_value };
    $query->{-or} = [
        { $sort => { $STRICT{$direction} => $sort_value } },
        {
            -and => [
                { $sort => $sort_value },
                { $id   => { $STRICT{$direction} => $id_value } },
            ],
        },
    ];

    return $query;
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::Keyset - The predicate for the rows after a keyset cursor.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::Infrastructure::Keyset->after(
        $query,
        {
            direction => 'desc',
            id        => [ 'me.thread_id',        $after->{id} ],
            sort      => [ 'me.last_activity_at', $after->{sort_value} ],
        }
    );

=head1 DESCRIPTION

Every paged list orders by a sort column and an id, and resumes after the
last row shown. This writes that condition once: the lexicographic
comparison, and the bound on the sort column that lets PostgreSQL start the
index scan at the cursor instead of at the first row.

=head1 SUBROUTINES/METHODS

=head2 after

Adds the condition to C<$query> (a L<SQL::Abstract> hash) and returns it.
C<direction> is C<asc> (the default) or C<desc>.

=head1 DIAGNOSTICS

Croaks on an unknown direction, and when the query already constrains the
sort column or already has an C<-or>: the condition would replace it.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Two columns, in one direction. The category listing leads with C<pinned>
and writes its three-column condition itself.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
