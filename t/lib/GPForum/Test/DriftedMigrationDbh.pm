# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::DriftedMigrationDbh;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::MigrationDbh';

our $VERSION = '0.001';

# The database of a deploy whose migration files were edited after they ran:
# every applied version is recorded with a checksum no file in the tree has.
sub selectall_arrayref {
    my ($self) = @_;

    return [ map { { checksum => 'edited-since', version => $_ } }
          @{ $self->applied_versions } ];
}

1;

__END__

=head1 NAME

GPForum::Test::DriftedMigrationDbh - A migration handle whose checksums disagree with the files.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::Test::MigrationStorage->new(
        dbh => GPForum::Test::DriftedMigrationDbh->new(
            applied_versions => [ '001', '002' ] ) );

=head1 DESCRIPTION

Stands in for the database handle L<GPForum::Migration::Runner> reads, where
a test needs C<schema_versions> to hold checksums that no migration file
matches.

=head1 SUBROUTINES/METHODS

=head2 selectall_arrayref

Returns each applied version with a checksum that matches no file.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Test::MigrationDbh>.

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
