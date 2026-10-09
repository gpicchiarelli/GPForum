# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::X::Check;

use Mojo::Base 'GPForum::X', -signatures;
use v5.40;

our $VERSION = '0.001';

has failure_type => 'permanent';

1;

__END__

=head1 NAME

GPForum::X::Check - A drill or verification found a mismatch.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::X::Check->throw( message => 'restored object content mismatch' );

=head1 DESCRIPTION

A drill or an evidence verification found what it checks to be wrong: a
restored object whose content differs, a schema_versions count that does not
match. The command exits 1 with failing evidence.

It is a L<GPForum::X>: it stringifies to its message and is always true.

=head1 SUBROUTINES/METHODS

None beyond L<GPForum::X>'s. C<failure_type> is C<permanent>.

=head1 DIAGNOSTICS

None of its own.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::X>.

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
