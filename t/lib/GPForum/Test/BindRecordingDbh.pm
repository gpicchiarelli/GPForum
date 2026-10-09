# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::BindRecordingDbh;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A database handle that records each statement with its binds, and answers
# every selectrow_array with the row it was given.
has statements => sub { return []; };
has row        => sub { return []; };

sub do ( $self, $sql, $, @binds ) {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    push @{ $self->statements }, { sql => $sql, binds => \@binds };

    return 1;
}

sub selectrow_array ( $self, $sql, $, @binds ) {
    push @{ $self->statements }, { sql => $sql, binds => \@binds };

    return @{ $self->row };
}

# The binds of each recorded statement whose SQL matches the pattern.
sub binds_of ( $self, $pattern ) {
    return
      map { $_->{binds} } grep { $_->{sql} =~ $pattern } @{ $self->statements };
}

1;

__END__

=head1 NAME

GPForum::Test::BindRecordingDbh - A database handle that records statements.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $dbh = GPForum::Test::BindRecordingDbh->new( row => [42] );
    $dbh->do( 'INSERT INTO t VALUES (?)', undef, 1 );
    my @binds = $dbh->binds_of(qr/INSERT \s+ INTO \s+ t\b/msx);

=head1 DESCRIPTION

Stands in for a DBI handle where a test reads what a command would have sent:
each C<do> and C<selectrow_array> is recorded with its binds, and
C<selectrow_array> answers with the C<row> it was built with.

=head1 SUBROUTINES/METHODS

=head2 do

Records the statement and its binds; returns 1.

=head2 selectrow_array

Records the statement and its binds; returns the C<row>.

=head2 binds_of

The binds of each recorded statement whose SQL matches a pattern, in order.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only the calls the performance seed and the query plan evidence make.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
