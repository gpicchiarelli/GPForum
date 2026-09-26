# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::Row;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

# One reader for "a row that may be a hashref or a DBIx::Class row".
#
# There were forty-one hand-copied versions of this in lib/, in thirteen
# distinct spellings, and they did not agree on what to return when the row
# answers neither shape. Six ended in a bare `return;`, which yields the empty
# LIST in list context -- and every one of those was called from inside a hash
# literal:
#
#     calculated_at => _column( $row, 'calculated_at' ),
#     score         => _column( $row, 'score' ),
#
# With a row that was not found, the pairs collapse and every subsequent key
# shifts by one: calculated_at takes the value 'score', trust_level takes
# 'user_id', and the user id becomes a key. Perl reports only "Odd number of
# elements in hash assignment".
#
# This returns undef, in scalar and list context alike, so a missing row
# produces a missing value rather than a corrupted hash.
sub column ( $, $row, $name ) {
    my $undefined;
    return $undefined    if !defined $row;
    return $row->{$name} if ref $row eq 'HASH';

    # UNIVERSAL::can by name: a row double is free to define its own can(),
    # and asking the object would then answer a different question.
    ## no critic (BuiltinFunctions::ProhibitUniversalCan)
    return $row->get_column($name)
      if UNIVERSAL::can( $row, 'get_column' );
    ## use critic

    return $undefined;
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::Row - Single reader for hashref or resultset rows.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $score = GPForum::Infrastructure::Row->column( $row, 'score' );

=head1 DESCRIPTION

Reads one column from a row that may be a plain hashref or a DBIx::Class row,
and returns undef when it is neither or when the row is missing. Never returns
the empty list, so the result is safe inside a hash literal.

=head1 SUBROUTINES/METHODS

=head2 column

Returns the named column, or undef.

=head1 DIAGNOSTICS

This module does not throw its own exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Callers that need a column accessor rather than C<get_column>, or that want a
missing row to be fatal, keep their own reader.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
