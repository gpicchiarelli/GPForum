# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Dbh;

use strict;
use warnings;

our $VERSION = '0.001';

# A DBI handle is a blessed hash, so production code reaches both for
# $dbh->{AutoCommit} and for $dbh->selectrow_array. A plain hashref satisfies
# the first and dies on the second, so the double has to be blessed.
sub new {
    my ( $class, %attributes ) = @_;

    return bless { AutoCommit => 1, %attributes }, $class;
}

# Statement-level calls are no-ops: the in-memory schema, not SQL, holds the
# state. They exist so a code path that takes an advisory lock or issues a
# session setting runs unchanged under the doubles instead of being skipped,
# which is how the audit-chain lock used to go untested.
sub selectrow_array    { return }
sub selectall_arrayref { return [] }
sub do                 { return '0E0' }
sub quote_identifier   { return qq{"$_[1]"} }
sub driver_name        { return 'Pg' }

1;

__END__

=head1 NAME

GPForum::Test::Dbh - Database handle double.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $dbh = GPForum::Test::Dbh->new( AutoCommit => 0 );

=head1 DESCRIPTION

Blessed-hash stand-in for a L<DBI> handle, exposing the small surface the
application reads: the C<AutoCommit> attribute plus the statement helpers used
by advisory locking and session settings.

=head1 SUBROUTINES/METHODS

=head2 new

Builds a handle with C<AutoCommit> true unless overridden.

=head2 selectrow_array

Returns nothing.

=head2 selectall_arrayref

Returns an empty arrayref.

=head2 do

Returns DBI's C<0E0> zero-but-true.

=head2 quote_identifier

Quotes an identifier the way PostgreSQL does.

=head2 driver_name

Reports C<Pg>.

=head1 DIAGNOSTICS

This module does not throw its own exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Executes no SQL; the schema double holds the state.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
