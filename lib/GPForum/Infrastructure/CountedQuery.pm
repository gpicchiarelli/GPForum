# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::CountedQuery;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

# One row from hand-written SQL, reported to the storage's statistics like
# every DBIx::Class statement. A raw DBI call bypasses DBIx::Class's debug
# callbacks, so the per-request query count and the endpoint budgets never
# saw it: the viewer resolution under-counted every signed-in request by one.
sub select_row ( $class, $schema, $sql, @bind ) {
    my $storage = $schema->storage;
    my $stats   = $storage->can('debug')
      && $storage->debug ? $storage->debugobj : undef;
    if ($stats) {
        $stats->query_start( $sql, @bind );
    }

    my $row = $storage->dbh_do(
        sub ( $, $dbh ) {
            return $dbh->selectrow_hashref( $sql, undef, @bind );
        }
    );
    if ($stats) {
        $stats->query_end( $sql, @bind );
    }

    return $row;
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::CountedQuery - Hand-written SQL that the query statistics see.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $row = GPForum::Infrastructure::CountedQuery->select_row(
        $schema, $sql, @bind );

=head1 DESCRIPTION

Runs one statement through the schema's DBI handle and reports it to the
storage's debug object, so hand-written SQL counts against the per-request
query statistics and the endpoint budgets like any DBIx::Class statement.

=head1 SUBROUTINES/METHODS

=head2 select_row

Returns the first row as a hash, or undef.

=head1 DIAGNOSTICS

Dies when the database does.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

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
