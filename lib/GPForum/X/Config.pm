# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::X::Config;

use Mojo::Base 'GPForum::X', -signatures;
use v5.40;

our $VERSION = '0.001';

has failure_type => 'permanent';

# What GPForum::Config found wrong, one record per setting, for a reader that
# renders them itself -- in the operator's language, say. Empty for a problem
# raised with a message alone.
has problems => sub { return [] };

1;

__END__

=head1 NAME

GPForum::X::Config - The configuration is invalid.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::X::Config->throw( message => 'GPFORUM_DATABASE_DSN is required' );

=head1 DESCRIPTION

The configuration is invalid: an environment value that does not parse, a
DSN without a database, an antivirus or Minion setting that cannot work.
Permanent; a command exits 1.

It is a L<GPForum::X>: it stringifies to its message and is always true.

=head1 SUBROUTINES/METHODS

None beyond L<GPForum::X>'s. C<failure_type> is C<permanent>. C<problems> is
the array reference of problem records L<GPForum::Config/problems>
describes, empty unless the configuration raised it; the message is their
English report.

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
