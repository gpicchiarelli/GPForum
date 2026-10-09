# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::X::Usage;

use Mojo::Base 'GPForum::X', -signatures;
use v5.40;

our $VERSION = '0.001';

has failure_type => 'permanent';

1;

__END__

=head1 NAME

GPForum::X::Usage - A command was called the wrong way.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::X::Usage->throw( message => 'Usage: bin/gpforum-migrate [--apply]' );

=head1 DESCRIPTION

A command-line tool was called the wrong way: an unknown option, a missing
argument, two options that exclude each other. Its message starts with
C<Usage:>, as the option parsers' croaks did, for the operator who reads it.
L<GPForum::Command::Usage> recognises the class, not the prefix, to exit 2
rather than 1.

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
